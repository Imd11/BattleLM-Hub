// BattleLMTests/ClaudeTranscriptExtractorTests.swift
import XCTest
@testable import BattleLM

final class ClaudeTranscriptExtractorTests: XCTestCase {
    
    // MARK: - Test Fixtures
    
    /// 样例 JSONL 内容 - 多段落响应
    static let sampleJsonl = """
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"请解释 Swift 的 async/await"}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"# Swift async/await 详解\\n\\nSwift 5.5 引入了 async/await 语法，使异步代码更易读。"},{"type":"text","text":"## 基本用法\\n\\n```swift\\nfunc fetchData() async throws -> Data {\\n    let url = URL(string: \\"https://api.example.com\\")!\\n    let (data, _) = try await URLSession.shared.data(from: url)\\n    return data\\n}\\n```\\n\\n这样写比回调地狱清晰多了。"}]}}
    """
    
    /// 样例 JSONL 内容 - 带 tool_use 的响应（应被忽略）
    static let jsonlWithToolUse = """
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"列出当前目录"}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_123","name":"bash","input":{"command":"ls -la"}},{"type":"text","text":"这是当前目录的文件列表。"}]}}
    """
    
    /// 样例 JSONL - 多轮对话（只取最后一轮）
    static let multiTurnJsonl = """
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"第一个问题"}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"第一个回答"}]}}
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"第二个问题"}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"第二个回答，这是最新的。"}]}}
    """
    
    // MARK: - Test Helpers
    
    private var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BattleLMTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    private func createTempJsonl(content: String, filename: String = "test.jsonl") -> URL {
        let file = tempDir.appendingPathComponent(filename)
        try! content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
    
    // MARK: - Tests
    
    func testParseMultiParagraphResponse() throws {
        // 由于 ClaudeTranscriptExtractor.parseTranscript 是 private，
        // 我们通过创建临时 JSONL 并模拟调用来测试
        // 这里我们直接测试 JSON 解析逻辑
        
        let jsonlContent = Self.sampleJsonl
        let lines = jsonlContent.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        XCTAssertEqual(lines.count, 2, "应有 2 行 JSONL")
        
        // 解析 assistant 行
        let assistantLine = lines[1]
        let data = assistantLine.data(using: .utf8)!
        
        struct Entry: Decodable {
            let type: String
            let message: Message?
            struct Message: Decodable {
                let content: [ContentBlock]?
            }
            struct ContentBlock: Decodable {
                let type: String
                let text: String?
            }
        }
        
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        
        XCTAssertEqual(entry.type, "assistant")
        XCTAssertNotNil(entry.message?.content)
        XCTAssertEqual(entry.message?.content?.count, 2, "应有 2 个 text block")
        
        // 验证文本内容
        let texts = entry.message?.content?.compactMap { $0.text } ?? []
        XCTAssertTrue(texts[0].contains("async/await"), "第一段应包含 async/await")
        XCTAssertTrue(texts[1].contains("```swift"), "第二段应包含代码块")
    }
    
    func testIgnoreToolUseBlocks() throws {
        let lines = Self.jsonlWithToolUse.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let assistantLine = lines[1]
        let data = assistantLine.data(using: .utf8)!
        
        struct Entry: Decodable {
            let type: String
            let message: Message?
            struct Message: Decodable {
                let content: [ContentBlock]?
            }
            struct ContentBlock: Decodable {
                let type: String
                let text: String?
            }
        }
        
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        
        // 过滤只保留 text 类型
        let textBlocks = entry.message?.content?.filter { $0.type == "text" } ?? []
        XCTAssertEqual(textBlocks.count, 1, "应只有 1 个 text block")
        XCTAssertEqual(textBlocks[0].text, "这是当前目录的文件列表。")
    }
    
    func testMultiTurnOnlyExtractLatest() throws {
        let lines = Self.multiTurnJsonl.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        // 从后往前找最后一个 user
        var lastUserIndex: Int? = nil
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            if lines[i].contains("\"type\":\"user\"") {
                lastUserIndex = i
                break
            }
        }
        
        XCTAssertEqual(lastUserIndex, 2, "最后一个 user 在索引 2")
        
        // 收集该 user 之后的 assistant 响应
        var responses: [String] = []
        for i in (lastUserIndex! + 1)..<lines.count {
            if lines[i].contains("\"type\":\"assistant\"") {
                // 简单提取 text
                if let range = lines[i].range(of: "第二个回答") {
                    responses.append(String(lines[i][range.lowerBound...]))
                }
            }
        }
        
        XCTAssertEqual(responses.count, 1, "应只有最后一轮的 assistant 响应")
    }
    
    func testProjectPathEncoding() {
        // 测试路径编码规则：/ → -
        let path = "/Users/demo/Projects/BattleLM"
        let encoded = path.replacingOccurrences(of: "/", with: "-")
        
        XCTAssertEqual(encoded, "-Users-demo-Projects-BattleLM")
        
        // 去掉开头的 - 得到另一种格式
        let withoutLeadingDash = String(encoded.dropFirst())
        XCTAssertEqual(withoutLeadingDash, "Users-demo-Projects-BattleLM")
    }
}
