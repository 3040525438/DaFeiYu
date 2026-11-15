import Foundation
#if !canImport(Darwin)
// Linux 上 URLRequest / HTTPURLResponse 在 FoundationNetworking 里
import FoundationNetworking
#endif
import DFCore

// MARK: - 云端语音识别（D16）
//
// 只做"请求怎么拼、响应怎么解读"的纯数据逻辑：不发网络请求，
// 因此 Linux CI 也能覆盖全部分支；真正的上传在 `CloudSpeechTranscriber`（仅 Apple 平台）。
//
// 协议：OpenAI 兼容的 `POST {baseURL}/audio/transcriptions`，multipart/form-data，
// 字段 `file`（音频）+ `model`（模型名），响应 `{ "text": "..." }`。

/// 一次云端转写请求的构造与解析
public enum SpeechTranscriptionWire {
    /// 未配置专用转写模型时使用的默认值
    public static let defaultModel = "whisper-1"

    /// 转写接口路径
    public static let endpoint = "audio/transcriptions"

    public struct MultipartBody: Sendable, Equatable {
        public var body: Data
        /// 含 boundary 的 Content-Type
        public var contentType: String

        public init(body: Data, contentType: String) {
            self.body = body
            self.contentType = contentType
        }
    }

    public static func makeBoundary() -> String {
        "DFBoundary-\(UUID().uuidString)"
    }

    /// 组装 multipart/form-data。
    ///
    /// - `fileName` 只保留安全字符：文件名里若含引号/换行，足以伪造额外的表单字段，
    ///   这里一律剔除，而不是简单转义。
    public static func makeMultipartBody(
        audio: Data,
        fileName: String,
        model: String,
        boundary: String = makeBoundary()
    ) -> MultipartBody {
        let safeFileName = sanitizedFileName(fileName)
        var data = Data()

        func append(_ text: String) {
            data.append(Data(text.utf8))
        }

        // file 字段
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFileName)\"\r\n")
        append("Content-Type: \(mimeType(forExtension: safeFileName))\r\n\r\n")
        data.append(audio)
        append("\r\n")

        // model 字段
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append(sanitizedModel(model))
        append("\r\n")

        append("--\(boundary)--\r\n")

        return MultipartBody(
            body: data,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    /// 构造上传请求；`baseURL` 已是带版本的根（例如 `https://api.openai.com/v1`）。
    public static func makeRequest(
        baseURL: URL,
        apiKey: String,
        multipart: MultipartBody,
        timeout: TimeInterval = 120
    ) -> URLRequest {
        let url = baseURL.appendingPathComponent(endpoint, isDirectory: false)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = multipart.body
        return request
    }

    /// 解析响应：非 2xx 视为失败，2xx 取 `text` 字段。
    public static func transcript(from data: Data, statusCode: Int) throws -> String {
        guard (200..<300).contains(statusCode) else {
            throw DFError.http(status: statusCode, message: failureMessage(from: data))
        }
        guard let payload = try? JSONDecoder().decode(TranscriptPayload.self, from: data) else {
            throw DFError.decoding("云端转写响应格式异常：\(sanitize(String(data: data, encoding: .utf8) ?? ""))")
        }
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw DFError.decoding("云端没有返回转写文本")
        }
        return text
    }

    /// 从错误响应里取尽量有用的说明（服务商通常返回 `{"error":{"message":"..."}}`）。
    public static func failureMessage(from data: Data) -> String {
        if let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data),
           let message = payload.error?.message,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sanitize(message)
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return sanitize(raw)
    }

    // MARK: - 内部

    private struct TranscriptPayload: Decodable {
        let text: String
    }

    private struct ErrorPayload: Decodable {
        struct PayloadError: Decodable {
            let message: String?
        }
        let error: PayloadError?
    }

    /// 文件名只保留字母数字、常见安全符号与扩展名分隔符
    static func sanitizedFileName(_ raw: String) -> String {
        let fallback = "audio.m4a"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        let scalars = trimmed.unicodeScalars.filter { allowed.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// 模型名同样只保留安全字符，避免把换行写进表单
    static func sanitizedModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultModel }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        let cleaned = String(String.UnicodeScalarView(trimmed.unicodeScalars.filter { allowed.contains($0) }))
        return cleaned.isEmpty ? defaultModel : cleaned
    }

    private static func mimeType(forExtension fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "m4a": return "audio/mp4"
        case "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        default: return "application/octet-stream"
        }
    }

    /// 错误信息脱敏：不把密钥写进界面或日志，并限制长度
    static func sanitize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = result.range(of: "sk-") {
            let tail = result[range.lowerBound...].prefix(16)
            result = result.replacingOccurrences(of: String(tail), with: "sk-***")
        }
        return String(result.prefix(300))
    }
}

#if canImport(Darwin)

/// 云端语音转写（D16）。仅在 Apple 平台编译，与 `OpenAICompatibleProvider` 同样的边界。
public struct CloudSpeechTranscriber: Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        baseURL: URL,
        apiKey: String,
        model: String = SpeechTranscriptionWire.defaultModel,
        timeout: TimeInterval = 120,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    /// 上传音频并取回转写文本；失败一律抛 `DFError`，不吞错。
    public func transcribe(audio: Data, fileName: String) async throws -> String {
        guard !audio.isEmpty else {
            throw DFError.decoding("音频为空，无法转写")
        }
        let multipart = SpeechTranscriptionWire.makeMultipartBody(
            audio: audio,
            fileName: fileName,
            model: model
        )
        let request = SpeechTranscriptionWire.makeRequest(
            baseURL: baseURL,
            apiKey: apiKey,
            multipart: multipart,
            timeout: timeout
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw DFError.cancelled
        } catch {
            throw DFError.network("云端转写请求失败：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw DFError.network("云端转写响应格式异常")
        }
        return try SpeechTranscriptionWire.transcript(from: data, statusCode: http.statusCode)
    }
}

#endif
