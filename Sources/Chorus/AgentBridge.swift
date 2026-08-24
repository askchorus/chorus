import Foundation
import Network
import AppKit

/// A loopback-only bridge that lets a coding agent (Claude Code, Codex, …) ask the SAME logged-in
/// panels the user broadcasts to, and get every AI's answer back as JSON.
///
/// Why this shape:
/// - It talks to the RUNNING app rather than driving its own headless browser, so it reuses the
///   user's existing sessions, needs no second login, and — the part that matters — everything the
///   agent asks appears in the window where the user can see it and stop it.
/// - It is OFF by default and bound to 127.0.0.1 with a token. Chorus's whole value rests on the
///   user's consumer subscriptions; an endpoint that can drive them has to be opt-in.
/// - Requests are rate limited. A human types one question at a time; an agent in a loop does not,
///   and superhuman cadence against consumer web UIs is exactly what gets accounts flagged.
@MainActor
final class AgentBridge {
    static let shared = AgentBridge()

    private var listener: NWListener?
    private var lastAskAt: Date?
    private var pending: [(id: UUID, respond: (Result<[AnswerDTO], BridgeError>) -> Void)] = []

    /// Minimum gap between agent questions. Deliberately slow: this is the guardrail that keeps
    /// the bridge human-paced no matter what loop the agent is running.
    private let minInterval: TimeInterval = 30

    struct AnswerDTO: Codable { let key: String; let name: String; let text: String }
    enum BridgeError: Error { case rateLimited(retryAfter: Int), busy, noPanels, timeout, denied }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: "agentBridgeEnabled") }
    var port: UInt16 { UInt16(UserDefaults.standard.object(forKey: "agentBridgePort") as? Int ?? 8765) }

    /// Stable per-install secret; the agent passes it as a bearer token.
    var token: String {
        if let t = UserDefaults.standard.string(forKey: "agentBridgeToken"), !t.isEmpty { return t }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(t, forKey: "agentBridgeToken")
        return t
    }

    func syncWithSetting() { isEnabled ? start() : stop() }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback   // never reachable from the network
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            clog("[AgentBridge] could not listen on \(port)")
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            MainActor.assumeIsolated { self?.receive(on: conn, buffer: Data()) }
        }
        l.start(queue: .main)
        listener = l
        clog("[AgentBridge] listening on 127.0.0.1:\(port)")
    }

    func stop() {
        guard listener != nil else { return }   // syncWithSetting fires on every defaults change
        listener?.cancel()
        listener = nil
        clog("[AgentBridge] stopped")
    }

    // MARK: - Minimal HTTP

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let headerEnd = Self.range(of: "\r\n\r\n", in: buf) else {
                if done { conn.cancel() }
                else { MainActor.assumeIsolated { self.receive(on: conn, buffer: buf) } }
                return
            }
            let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
            let contentLength = Self.contentLength(in: head)
            let body = buf[headerEnd.upperBound...]
            guard body.count >= contentLength else {
                MainActor.assumeIsolated { self.receive(on: conn, buffer: buf) }
                return
            }
            MainActor.assumeIsolated {
                self.handle(head: head, body: Data(body.prefix(contentLength)), conn: conn)
            }
        }
    }

    private func handle(head: String, body: Data, conn: NWConnection) {
        let firstLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let authed = head.lowercased().contains("authorization: bearer \(token)")

        guard firstLine.hasPrefix("POST /ask") else {
            return send(status: "404 Not Found", json: ["error": "unknown endpoint"], on: conn)
        }
        guard authed else {
            return send(status: "401 Unauthorized", json: ["error": "bad or missing token"], on: conn)
        }
        guard let req = try? JSONDecoder().decode(AskRequest.self, from: body),
              !req.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return send(status: "400 Bad Request", json: ["error": "expected {\"prompt\": \"…\"}"], on: conn)
        }

        ask(prompt: req.prompt) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let answers):
                let payload = try? JSONEncoder().encode(["answers": answers])
                self.send(status: "200 OK", raw: payload ?? Data(), on: conn)
            case .failure(let err):
                switch err {
                case .rateLimited(let retry):
                    self.send(status: "429 Too Many Requests",
                              json: ["error": "rate limited — Chorus keeps agent questions human-paced",
                                     "retry_after_seconds": "\(retry)"], on: conn)
                case .busy:     self.send(status: "409 Conflict", json: ["error": "another question is still running"], on: conn)
                case .noPanels: self.send(status: "409 Conflict", json: ["error": "no AI panels are open in Chorus"], on: conn)
                case .timeout:  self.send(status: "504 Gateway Timeout", json: ["error": "the AIs did not finish in time"], on: conn)
                case .denied:   self.send(status: "403 Forbidden", json: ["error": "the user declined this question"], on: conn)
                }
            }
        }
    }

    private struct AskRequest: Codable { let prompt: String }

    // MARK: - The actual ask

    private var inFlight: UUID?

    func ask(prompt: String, completion: @escaping (Result<[AnswerDTO], BridgeError>) -> Void) {
        if let last = lastAskAt {
            let gap = Date().timeIntervalSince(last)
            if gap < minInterval {
                return completion(.failure(.rateLimited(retryAfter: Int((minInterval - gap).rounded(.up)))))
            }
        }
        guard inFlight == nil else { return completion(.failure(.busy)) }

        let store = WebViewStore.shared
        let targets = store.agentTargetKeys()
        guard !targets.isEmpty else { return completion(.failure(.noPanels)) }

        let id = UUID()
        inFlight = id
        lastAskAt = Date()
        AgentActivity.shared.note(prompt: prompt)
        store.broadcast(text: prompt, source: .agent)

        // Give the panels their usual completion window, then read whatever landed. Answers are
        // returned RAW, one per panel: the value of asking several AIs is where they disagree, and
        // pre-digesting that into a summary throws away exactly that signal.
        store.awaitAgentAnswers(timeout: 240) { [weak self] answers in
            guard let self, self.inFlight == id else { return }
            self.inFlight = nil
            AgentActivity.shared.finish()
            completion(answers.isEmpty ? .failure(.timeout)
                                       : .success(answers.map { AnswerDTO(key: $0.key, name: $0.name, text: $0.text) }))
        }
    }

    // MARK: - Response helpers

    private func send(status: String, json: [String: String], on conn: NWConnection) {
        send(status: status, raw: (try? JSONEncoder().encode(json)) ?? Data(), on: conn)
    }

    private func send(status: String, raw: Data, on conn: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(raw.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(raw)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func range(of needle: String, in data: Data) -> Range<Data.Index>? {
        data.range(of: Data(needle.utf8))
    }

    private static func contentLength(in head: String) -> Int {
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        }
        return 0
    }
}

/// What the agent is currently asking, so the main window can show it. The user must always be
/// able to see a question asked on their behalf.
@MainActor
final class AgentActivity: ObservableObject {
    static let shared = AgentActivity()
    @Published private(set) var currentPrompt: String?
    func note(prompt: String) { currentPrompt = prompt }
    func finish() { currentPrompt = nil }
}
