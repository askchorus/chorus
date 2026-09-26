import XCTest
@testable import Chorus

/// API panels named after a known service show that service's own spelling; anything else is
/// the user's own name and stays as typed.
final class APIProviderNameTests: XCTestCase {
    func testKnownServiceNamesGetTheirProperSpelling() {
        XCTAssertEqual(APIProviderRegistry.canonicalName("deepseek"), "DeepSeek")
        XCTAssertEqual(APIProviderRegistry.canonicalName("groq"), "Groq")
        XCTAssertEqual(APIProviderRegistry.canonicalName("GROQ"), "Groq")
        XCTAssertEqual(APIProviderRegistry.canonicalName("  openai "), "OpenAI")
        XCTAssertEqual(APIProviderRegistry.canonicalName("openrouter"), "OpenRouter")
        XCTAssertEqual(APIProviderRegistry.canonicalName("siliconflow"), "SiliconFlow")
        XCTAssertEqual(APIProviderRegistry.canonicalName("lm studio"), "LM Studio")
        XCTAssertEqual(APIProviderRegistry.canonicalName("lmstudio"), "LM Studio")
        XCTAssertEqual(APIProviderRegistry.canonicalName("xai"), "xAI")
    }

    func testOwnNamesStayAsTyped() {
        XCTAssertEqual(APIProviderRegistry.canonicalName("deepseek reasoner"), "deepseek reasoner")
        XCTAssertEqual(APIProviderRegistry.canonicalName("My Groq"), "My Groq")
        XCTAssertEqual(APIProviderRegistry.canonicalName("硅基流动"), "硅基流动")
        XCTAssertEqual(APIProviderRegistry.canonicalName(" work gpt "), "work gpt")
    }

    /// Stored panels read back with canonical names, without touching ids or endpoints.
    func testDecodeCanonicalizesStoredNames() {
        let raw = #"[{"id":"api_deepseek","name":"deepseek","baseURL":"https://api.deepseek.com/v1","model":"deepseek-chat"},"#
            + #"{"id":"api_groq","name":"groq","baseURL":"https://api.groq.com/openai/v1","model":"llama"},"#
            + #"{"id":"api_mine","name":"my local box","baseURL":"http://localhost:11434/v1","model":""}]"#
        let list = APIProviderRegistry.decode(raw)
        XCTAssertEqual(list.map(\.name), ["DeepSeek", "Groq", "my local box"])
        XCTAssertEqual(list.map(\.id), ["api_deepseek", "api_groq", "api_mine"])
        XCTAssertEqual(list[0].baseURL, "https://api.deepseek.com/v1")
    }
}
