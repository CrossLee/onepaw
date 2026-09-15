import Foundation

public enum ShareAccessCodeValidationError: Error, Equatable, LocalizedError, Sendable {
    case tooShort
    case tooLong
    case unsupportedCharacters

    public var errorDescription: String? {
        switch self {
        case .tooShort:
            return "访问码至少需要 \(ShareAccessCode.minimumLength) 位"
        case .tooLong:
            return "访问码最多只能有 \(ShareAccessCode.maximumLength) 位"
        case .unsupportedCharacters:
            return "访问码只能使用英文字母、数字、- 和 _"
        }
    }
}

public enum ShareAccessCode {
    public static let minimumLength = 6
    public static let maximumLength = 24
    public static let defaultRandomLength = 10

    private static let randomAlphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")

    public static func normalized(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= minimumLength else {
            throw ShareAccessCodeValidationError.tooShort
        }
        guard value.count <= maximumLength else {
            throw ShareAccessCodeValidationError.tooLong
        }
        guard value.unicodeScalars.allSatisfy(isAllowed) else {
            throw ShareAccessCodeValidationError.unsupportedCharacters
        }
        return value
    }

    public static func makeRandom(
        length: Int = defaultRandomLength
    ) -> String {
        precondition((minimumLength...maximumLength).contains(length))
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in
            randomAlphabet.randomElement(using: &generator)!
        })
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 48...57, 65...90, 95, 97...122:
            return true
        default:
            return false
        }
    }
}

public enum ShareLinkBuilder {
    public static func url(
        host: String,
        port: UInt16,
        accessCode: String
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "token", value: accessCode)]
        return components.url
    }

    public static func relativeURL(
        path: String,
        accessCode: String
    ) -> String? {
        var components = URLComponents()
        components.path = path
        components.queryItems = [URLQueryItem(name: "token", value: accessCode)]
        return components.string
    }
}
