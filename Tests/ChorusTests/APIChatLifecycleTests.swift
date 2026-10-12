import XCTest
@testable import Chorus

/// Hold requests open and deliver their callbacks in deliberately hostile orders. No real
/// endpoint, keys, preferences, or saved conversations are used by these tests.
@MainActor
final class APIChatLifecycleTests: XCTestCase {
    private let provider = APIProvider(id: "test_api_lifecycle", name: "Test",
                                       baseURL: "http://localhost/v1", model: "test")

    private final class Transport {
        struct Request {
            let messages: [ChatMessage]
            let delta: @Sendable (String) async -> Void
            let continuation: CheckedContinuation<Void, Error>
            let returned: XCTestExpectation
        }
        var requests: [Request] = []
        var cancelledOnReturn: [Int: Bool] = [:]

        func stream(_ provider: APIProvider, _ messages: [ChatMessage],
                    _ delta: @escaping @Sendable (String) async -> Void) async throws {
            let index = requests.count
            let returned = XCTestExpectation(description: "request \(index) returned")
            defer {
                cancelledOnReturn[index] = Task.isCancelled
                returned.fulfill()
            }
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(messages: messages, delta: delta,
                                        continuation: continuation, returned: returned))
            }
        }
    }

    private func store(_ transport: Transport, at url: URL? = nil) -> APIChatStore {
        APIChatStore(storageURL: url) { provider, messages, delta in
            try await transport.stream(provider, messages, delta)
        }
    }

    private func waitForRequests(_ count: Int, _ transport: Transport) async throws {
        let deadline = Date().addingTimeInterval(2)
        while transport.requests.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(transport.requests.count, count)
        guard transport.requests.count == count else { throw APIClient.Err.message("transport failed to start") }
    }

    private func complete(_ index: Int, _ transport: Transport, error: Error? = nil) async {
        let request = transport.requests[index]
        if let error { request.continuation.resume(throwing: error) }
        else { request.continuation.resume() }
        await fulfillment(of: [request.returned], timeout: 2)
        await Task.yield()
    }

    private func busy() -> Bool {
        var result = false
        WebViewStore.shared.anyBusy([provider.id]) { result = $0 }
        return result
    }

    func testReplacedRequestCannotFinishNewReplyOrLoseItsStopHandle() async throws {
        let transport = Transport(), store = store(transport)
        store.send(to: provider, prompt: "first")
        try await waitForRequests(1, transport)
        store.send(to: provider, prompt: "second")
        try await waitForRequests(2, transport)
        XCTAssertFalse(store.messages(for: provider.id)[1].isStreaming)

        await complete(0, transport, error: URLError(.cancelled))
        XCTAssertTrue(store.isStreaming(provider.id), "old completion must not finish the new request")
        XCTAssertTrue(busy(), "the all-done tracker must still wait for the new request")
        XCTAssertNil(store.messages(for: provider.id)[1].error, "replacement is not a network error")

        store.stop(provider.id)
        await complete(1, transport, error: URLError(.cancelled))
        XCTAssertEqual(transport.cancelledOnReturn[1], true, "Stop must still own the second task")
        XCTAssertFalse(store.isStreaming(provider.id))
        XCTAssertNil(store.messages(for: provider.id).last?.error)
    }

    func testQueuedTokensCannotExtendAStoppedAnswer() async throws {
        let transport = Transport(), store = store(transport)
        store.send(to: provider, prompt: "first")
        try await waitForRequests(1, transport)
        // A network callback has been queued just as the user presses Stop.
        let queued = Task { @MainActor in await transport.requests[0].delta("too late") }
        store.stop(provider.id)
        await queued.value
        await complete(0, transport, error: URLError(.cancelled))
        XCTAssertEqual(store.messages(for: provider.id).last?.text, "")
        XCTAssertNil(store.messages(for: provider.id).last?.error)
        XCTAssertFalse(busy())
    }

    func testReplacementKeepsPartialAnswerButRejectsLateOldTokens() async throws {
        let transport = Transport(), store = store(transport)
        store.send(to: provider, prompt: "first")
        try await waitForRequests(1, transport)
        await transport.requests[0].delta("partial")
        store.send(to: provider, prompt: "second")
        try await waitForRequests(2, transport)
        await transport.requests[0].delta(" obsolete")
        await transport.requests[1].delta("current")
        XCTAssertEqual(store.messages(for: provider.id).map(\.text), ["first", "partial", "second", "current"])
        XCTAssertFalse(store.messages(for: provider.id)[1].isStreaming)
        XCTAssertTrue(store.messages(for: provider.id)[3].isStreaming)
        // The older request may finish even after its replacement has already succeeded.
        await complete(1, transport)
        await complete(0, transport, error: APIClient.Err.message("obsolete error"))
        XCTAssertNil(store.messages(for: provider.id)[1].error)
        XCTAssertNil(store.messages(for: provider.id)[3].error)
    }

    func testNewChatImmediatelyClearsBusyStateAndRejectsOldCompletion() async throws {
        let transport = Transport(), store = store(transport)
        store.send(to: provider, prompt: "old chat")
        try await waitForRequests(1, transport)
        store.newChat(provider.id)
        XCTAssertFalse(busy(), "a cleared conversation must not wait on network cancellation")
        XCTAssertTrue(store.messages(for: provider.id).isEmpty)

        store.send(to: provider, prompt: "new chat")
        try await waitForRequests(2, transport)
        await complete(0, transport, error: APIClient.Err.message("late old failure"))
        XCTAssertTrue(store.isStreaming(provider.id))
        XCTAssertTrue(busy())
        XCTAssertNil(store.messages(for: provider.id).last?.error)
        XCTAssertEqual(transport.requests[1].messages.map(\.text), ["new chat"])
        await complete(1, transport)
    }

    func testStopWithoutAnActiveRequestDoesNotInventACompletedAnswer() {
        let transport = Transport(), store = store(transport)
        let unusedID = "test_api_never_started"
        store.stop(unusedID)
        XCTAssertFalse(WebViewStore.shared.answeredLastBroadcast.contains(unusedID))
    }

    func testSuccessfulReplyPersistsItsLastTokenAndRestores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversations.json")
        let transport = Transport(), store = store(transport, at: url)
        store.send(to: provider, prompt: "hello")
        try await waitForRequests(1, transport)
        await transport.requests[0].delta("last token")
        await complete(0, transport)
        XCTAssertFalse(store.isStreaming(provider.id))
        XCTAssertEqual(store.messages(for: provider.id).last?.text, "last token")
        let restored = self.store(Transport(), at: url)
        XCTAssertEqual(restored.messages(for: provider.id).map(\.text), ["hello", "last token"])
        store.newChat(provider.id)
        XCTAssertFalse(WebViewStore.shared.answeredLastBroadcast.contains(provider.id))
        XCTAssertTrue(self.store(Transport(), at: url).messages(for: provider.id).isEmpty)
    }

    func testFailureAndOtherProvidersStillCompleteIndependently() async throws {
        let transport = Transport(), store = store(transport)
        let other = APIProvider(id: "test_api_other", name: "Other", baseURL: "http://localhost/v1", model: "test")
        store.send(to: provider, prompt: "one")
        try await waitForRequests(1, transport)
        store.send(to: other, prompt: "two")
        try await waitForRequests(2, transport)
        await complete(0, transport, error: APIClient.Err.message("service unavailable"))
        XCTAssertEqual(store.messages(for: provider.id).last?.error, "service unavailable")
        XCTAssertFalse(store.isStreaming(provider.id))
        XCTAssertTrue(store.isStreaming(other.id))
        await complete(1, transport)
        XCTAssertFalse(store.isStreaming(other.id))
    }
}
