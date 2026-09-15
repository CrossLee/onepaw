import Foundation

public struct HTTPRequest: Sendable {
    public let method: String
    public let target: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data
    public let remoteAddress: String?

    public init(
        method: String,
        target: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data(),
        remoteAddress: String? = nil
    ) {
        self.method = method
        self.target = target
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public var headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public static func text(
        _ text: String,
        statusCode: Int = 200,
        contentType: String = "text/plain; charset=utf-8"
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": contentType],
            body: Data(text.utf8)
        )
    }

    public static func json<T: Encodable>(_ value: T, statusCode: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{\"error\":\"encode_failed\"}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    public func serializedHead() -> Data {
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        allHeaders["Cache-Control"] = allHeaders["Cache-Control"] ?? "no-store"
        allHeaders["X-Content-Type-Options"] = "nosniff"
        allHeaders["Referrer-Policy"] = "no-referrer"
        allHeaders["X-Frame-Options"] = "DENY"

        var lines = ["HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))"]
        for key in allHeaders.keys.sorted() {
            if let value = allHeaders[key],
               Self.isValidHeaderName(key),
               Self.isValidHeaderValue(value) {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let allowedPunctuation = "!#$%&'*+-.^_`|~"
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return true
            default:
                return scalar.isASCII && allowedPunctuation.unicodeScalars.contains(scalar)
            }
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 9 || scalar.value >= 32 && scalar.value != 127
        }
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        default: return "Response"
        }
    }
}

public enum HTTPParseError: LocalizedError {
    case incomplete
    case malformedRequest
    case invalidContentLength
    case unsupportedTransferEncoding

    public var errorDescription: String? {
        switch self {
        case .incomplete: return "HTTP 请求尚未接收完整"
        case .malformedRequest: return "HTTP 请求格式错误"
        case .invalidContentLength: return "Content-Length 无效"
        case .unsupportedTransferEncoding: return "暂不支持分块请求体"
        }
    }
}
