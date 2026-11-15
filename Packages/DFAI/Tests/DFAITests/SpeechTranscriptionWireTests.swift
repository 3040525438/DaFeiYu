import XCTest
@testable import DFAI
import DFCore

/// 云端语音识别请求构造与响应解析（D16）。全部为纯数据逻辑，CI 可覆盖。
final class SpeechTranscriptionWireTests: XCTestCase {

    /// 用可打印字节：测试里要把整个 multipart 当 UTF-8 文本检查
    private let audio = Data([0x41, 0x42, 0x43, 0x44, 0x45])

    // MARK: - multipart 组装

    func testMultipartContainsFileAndModelFields() throws {
        let boundary = "TEST-BOUNDARY"
        let multipart = SpeechTranscriptionWire.makeMultipartBody(
            audio: audio,
            fileName: "voice-1.m4a",
            model: "whisper-1",
            boundary: boundary
        )
        let text = try XCTUnwrap(String(data: multipart.body, encoding: .utf8))

        XCTAssertEqual(multipart.contentType, "multipart/form-data; boundary=\(boundary)")
        XCTAssertTrue(text.contains("--TEST-BOUNDARY\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"voice-1.m4a\""))
        XCTAssertTrue(text.contains("Content-Type: audio/mp4"))
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertTrue(text.hasSuffix("--TEST-BOUNDARY--\r\n"))
    }

    func testMultipartKeepsAudioBytesIntact() {
        let multipart = SpeechTranscriptionWire.makeMultipartBody(
            audio: audio,
            fileName: "a.wav",
            model: "whisper-1"
        )
        XCTAssertTrue(multipart.body.range(of: audio) != nil)
    }

    func testFileNameCannotInjectExtraHeaders() throws {
        let multipart = SpeechTranscriptionWire.makeMultipartBody(
            audio: audio,
            fileName: "evil\r\nContent-Type: text/html\".m4a",
            model: "whisper-1"
        )
        let text = try XCTUnwrap(String(data: multipart.body, encoding: .utf8))
        XCTAssertFalse(text.contains("\r\nContent-Type: text/html"))
        // 换行、引号、冒号、斜杠全部剔除，文件名退化为一串安全字符
        XCTAssertTrue(text.contains("filename=\"evilContent-Type texthtml.m4a\""))
    }

    func testEmptyFileNameFallsBack() throws {
        let multipart = SpeechTranscriptionWire.makeMultipartBody(
            audio: audio,
            fileName: "   ",
            model: "whisper-1"
        )
        let text = try XCTUnwrap(String(data: multipart.body, encoding: .utf8))
        XCTAssertTrue(text.contains("filename=\"audio.m4a\""))
    }

    func testEmptyModelFallsBackToDefault() throws {
        let multipart = SpeechTranscriptionWire.makeMultipartBody(
            audio: audio,
            fileName: "a.m4a",
            model: "  "
        )
        let text = try XCTUnwrap(String(data: multipart.body, encoding: .utf8))
        XCTAssertTrue(text.contains("\r\n\r\nwhisper-1\r\n"))
    }

    func testBoundaryIsUnique() {
        XCTAssertNotEqual(SpeechTranscriptionWire.makeBoundary(), SpeechTranscriptionWire.makeBoundary())
    }

    // MARK: - 请求

    func testMakeRequestSetsMethodHeadersAndURL() throws {
        let base = try XCTUnwrap(URL(string: "https://api.example.com/v1"))
        let multipart = SpeechTranscriptionWire.makeMultipartBody(
            audio: audio,
            fileName: "a.m4a",
            model: "whisper-1"
        )
        let request = SpeechTranscriptionWire.makeRequest(
            baseURL: base,
            apiKey: "sk-test",
            multipart: multipart,
            timeout: 30
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), multipart.contentType)
        XCTAssertEqual(request.httpBody, multipart.body)
    }

    // MARK: - 响应解析

    func testTranscriptTrimsWhitespace() throws {
        let data = Data(#"{"text":"  你好呀  "}"#.utf8)
        XCTAssertEqual(try SpeechTranscriptionWire.transcript(from: data, statusCode: 200), "你好呀")
    }

    func testTranscriptRejectsEmptyText() {
        let data = Data(#"{"text":"   "}"#.utf8)
        XCTAssertThrowsError(try SpeechTranscriptionWire.transcript(from: data, statusCode: 200)) { error in
            XCTAssertTrue("\(error)".contains("没有返回转写文本"))
        }
    }

    func testTranscriptRejectsMalformedBody() {
        let data = Data("not-json".utf8)
        XCTAssertThrowsError(try SpeechTranscriptionWire.transcript(from: data, statusCode: 200)) { error in
            guard case DFError.decoding = error else {
                return XCTFail("应当为 decoding，实际 \(error)")
            }
        }
    }

    func testNon2xxSurfacesProviderMessage() {
        let data = Data(#"{"error":{"message":"invalid audio format"}}"#.utf8)
        XCTAssertThrowsError(try SpeechTranscriptionWire.transcript(from: data, statusCode: 400)) { error in
            guard case let DFError.http(status, message) = error else {
                return XCTFail("应当为 http，实际 \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(message, "invalid audio format")
        }
    }

    func testFailureMessageMasksAPIKey() {
        let data = Data(#"{"error":{"message":"bad key sk-abcdefghijklmnopqrstuvwxyz"}}"#.utf8)
        let message = SpeechTranscriptionWire.failureMessage(from: data)
        XCTAssertFalse(message.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(message.contains("sk-***"))
    }

    func testFailureMessageTruncatesLongBody() {
        let long = String(repeating: "x", count: 2000)
        XCTAssertEqual(SpeechTranscriptionWire.failureMessage(from: Data(long.utf8)).count, 300)
    }

    func testEmptyBodyFailureIsEmptyString() {
        XCTAssertEqual(SpeechTranscriptionWire.failureMessage(from: Data()), "")
    }
}
