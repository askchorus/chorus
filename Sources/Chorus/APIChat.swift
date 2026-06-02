import Foundation
import Combine

/// One turn in an API conversation. `text` grows live while `isStreaming`.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var imageBase64: String? = nil   // PNG base64 on a user turn (vision); sent as an image_url
    var isStreaming: Bool = false
    var error: String? = nil
}

/// Owns the conversation + streaming state for every configured API provider, and drives the
/// OpenAI-compatible streaming requests. One shared instance, mirroring `WebViewStore` so both
/// the main window and the quick-input broadcaster reach the same conversations.
@MainActor
final class APIChatStore: ObservableObject {
    static let shared = APIChatStore()

    /// providerId → its messages (oldest first). The last message is the streaming reply.
    @Published private(set) var conversations: [String: [ChatMessage]] = [:]
    /// providerIds whose reply is currently streaming — drives the per-panel "thinking" dot.
    @Published private(set) var streaming: Set<String> = []

    private var tasks: [String: Task<Void, Never>] = [:]

    func messages(for id: String) -> [ChatMessage] { conversations[id] ?? [] }
    func isStreaming(_ id: String) -> Bool { streaming.contains(id) }

    /// Append the user's prompt (optionally with an image, for vision models) and stream the
    /// assistant's reply. Full conversation history is sent each time so the model keeps context.
    func send(to provider: APIProvider, prompt: String, imageBase64: String? = nil) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty || imageBase64 != nil else { return }

        tasks[provider.id]?.cancel()

        var msgs = conversations[provider.id] ?? []
        msgs.append(ChatMessage(role: .user, text: p, imageBase64: imageBase64))
        let reply = ChatMessage(role: .assistant, text: "", isStreaming: true)
        msgs.append(reply)
        conversations[provider.id] = msgs
        streaming.insert(provider.id)

        let replyId = reply.id
        let history = Array(msgs.dropLast())   // everything up to & including the new user turn

        tasks[provider.id] = Task { [weak self] in
            do {
                try await APIClient.stream(provider: provider, messages: history) { [weak self] delta in
                    Task { @MainActor in self?.append(provider.id, replyId, delta) }
                }
                self?.finish(provider.id, replyId, error: nil)
            } catch is CancellationError {
                self?.finish(provider.id, replyId, error: nil)
            } catch {
                self?.finish(provider.id, replyId, error: APIClient.friendly(error))
            }
        }
    }

    /// Stop an in-flight reply (the panel's stop button).
    func stop(_ providerId: String) {
        tasks[providerId]?.cancel()
        tasks[providerId] = nil
        finish(providerId, nil, error: nil)
    }

    /// Clear a panel's conversation (its "new chat").
    func newChat(_ providerId: String) {
        tasks[providerId]?.cancel()
        tasks[providerId] = nil
        conversations[providerId] = []
        streaming.remove(providerId)
    }

    // MARK: - Streaming callbacks (main actor)

    private func append(_ providerId: String, _ messageId: UUID, _ delta: String) {
        guard var msgs = conversations[providerId],
              let idx = msgs.firstIndex(where: { $0.id == messageId }) else { return }
        msgs[idx].text += delta
        conversations[providerId] = msgs
    }

    /// Mark the reply finished (success, stop, or error). `messageId == nil` → stop button: just
    /// clear the streaming flag on whatever reply is open.
    private func finish(_ providerId: String, _ messageId: UUID?, error: String?) {
        streaming.remove(providerId)
        tasks[providerId] = nil
        guard var msgs = conversations[providerId] else { return }
        let idx = messageId.flatMap { id in msgs.firstIndex(where: { $0.id == id }) }
            ?? msgs.lastIndex(where: { $0.role == .assistant })
        guard let i = idx else { return }
        msgs[i].isStreaming = false
        if let error { msgs[i].error = error }
        conversations[providerId] = msgs
    }
}

/// Stateless OpenAI-compatible streaming client. Works against OpenAI, DeepSeek, Groq,
/// OpenRouter, SiliconFlow, and local Ollama / LM Studio — they all speak the same
/// `/chat/completions` SSE protocol.
enum APIClient {
    /// POST a streaming chat-completions request; `onDelta` is called (off the main actor) for
    /// each content token. Throws on transport / HTTP errors and on cancellation.
    static func stream(provider: APIProvider,
                       messages: [ChatMessage],
                       onDelta: @Sendable @escaping (String) -> Void) async throws {
        var endpoint = provider.baseURL.trimmingCharacters(in: .whitespaces)
        if endpoint.hasSuffix("/") { endpoint.removeLast() }
        if !endpoint.hasSuffix("/chat/completions") { endpoint += "/chat/completions" }
        guard let url = URL(string: endpoint) else { throw Err.message("Bad base URL") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = provider.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        // Build messages. A user turn with an image uses the multimodal content-array form
        // ({type:text} + {type:image_url, data URL}); everything else is a plain string content.
        let apiMessages: [[String: Any]] = messages.map { m in
            let role = m.role == .user ? "user" : "assistant"
            if m.role == .user, let b64 = m.imageBase64, !b64.isEmpty {
                var content: [[String: Any]] = []
                if !m.text.isEmpty { content.append(["type": "text", "text": m.text]) }
                content.append(["type": "image_url",
                                "image_url": ["url": "data:image/png;base64,\(b64)"]])
                return ["role": role, "content": content]
            }
            return ["role": role, "content": m.text]
        }
        let body: [String: Any] = [
            "model": provider.model,
            "messages": apiMessages,
            "stream": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw Err.message("No response") }
        guard http.statusCode == 200 else {
            // Drain the (non-SSE) error body so we can show a useful message.
            var raw = ""
            for try await line in bytes.lines { raw += line + "\n"; if raw.count > 4000 { break } }
            throw Err.http(http.statusCode, extractErrorMessage(raw))
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String, !content.isEmpty else { continue }
            onDelta(content)
        }
    }

    enum Err: Error { case message(String); case http(Int, String) }

    /// A short, human-readable message for the error bubble.
    static func friendly(_ error: Error) -> String {
        switch error {
        case Err.message(let m): return m
        case Err.http(let code, let m):
            let hint: String
            switch code {
            case 401, 403: hint = "密钥无效或无权限"
            case 404:      hint = "找不到接口/模型，检查 Base URL 和模型名"
            case 429:      hint = "请求过多/额度不足"
            default:       hint = "HTTP \(code)"
            }
            return m.isEmpty ? hint : "\(hint)：\(m)"
        case let urlErr as URLError where urlErr.code == .cannotConnectToHost:
            return "连不上服务器（本地模型没启动？）"
        default:
            return (error as NSError).localizedDescription
        }
    }

    /// Pull `error.message` out of a JSON error body if present, else return a trimmed snippet.
    private static func extractErrorMessage(_ raw: String) -> String {
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).description
    }
}
