import Foundation

public enum JSONFormattingError: Error, Equatable, LocalizedError, Sendable {
    case emptyInput
    case inputTooLarge(maximumBytes: Int)
    case outputTooLarge(maximumBytes: Int)
    case invalidJSON(message: String, line: Int, column: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "请输入 JSON 内容"
        case let .inputTooLarge(maximumBytes):
            return "JSON 内容不能超过 \(Self.byteCountDescription(maximumBytes))"
        case let .outputTooLarge(maximumBytes):
            return "格式化结果不能超过 \(Self.byteCountDescription(maximumBytes))"
        case let .invalidJSON(message, line, column):
            return "JSON 格式错误（第 \(line) 行，第 \(column) 列）：\(message)"
        }
    }

    private static func byteCountDescription(_ byteCount: Int) -> String {
        guard byteCount.isMultiple(of: 1_048_576) else {
            return "\(byteCount) 字节"
        }
        return "\(byteCount / 1_048_576) MB"
    }
}

/// Strictly validates and formats JSON while preserving the source tokens that
/// carry data. Object order, duplicate keys, number spellings, and string
/// escape spellings are not rewritten.
public enum JSONTextFormatter {
    public static let maximumInputBytes = 1_048_576
    public static let maximumOutputBytes = 8_388_608
    public static let maximumNestingDepth = 256

    public static func format(_ input: String) throws -> String {
        guard input.utf8.count <= maximumInputBytes else {
            throw JSONFormattingError.inputTooLarge(maximumBytes: maximumInputBytes)
        }
        let bytes = Array(input.utf8)

        var parser = JSONTokenPreservingParser(
            bytes: bytes,
            maximumNestingDepth: maximumNestingDepth,
            maximumOutputBytes: maximumOutputBytes
        )
        return try parser.format()
    }
}

public enum Base64TextEncoder {
    /// Encodes the exact UTF-8 representation of `input` with standard Base64.
    public static func encode(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
    }
}

public enum UUIDTextFormat: String, CaseIterable, Sendable {
    case lowercase
    case uppercase

    fileprivate func apply(to value: String) -> String {
        switch self {
        case .lowercase:
            return value.lowercased()
        case .uppercase:
            return value.uppercased()
        }
    }
}

public enum UUIDGenerationError: Error, Equatable, LocalizedError, Sendable {
    case invalidCount(minimum: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidCount(minimum, maximum):
            return "UUID 生成数量必须在 \(minimum) 到 \(maximum) 之间"
        }
    }
}

public enum UUIDTextGenerator {
    public static let minimumCount = 1
    public static let maximumCount = 100

    /// Generates one UUID per line using the requested letter casing.
    public static func generate(
        count: Int,
        format: UUIDTextFormat = .lowercase
    ) throws -> String {
        guard (minimumCount...maximumCount).contains(count) else {
            throw UUIDGenerationError.invalidCount(
                minimum: minimumCount,
                maximum: maximumCount
            )
        }

        return (0..<count)
            .map { _ in format.apply(to: UUID().uuidString) }
            .joined(separator: "\n")
    }
}

private struct JSONTokenPreservingParser {
    private let bytes: [UInt8]
    private let maximumNestingDepth: Int
    private let maximumOutputBytes: Int
    private var index = 0
    private var output: [UInt8] = []

    init(bytes: [UInt8], maximumNestingDepth: Int, maximumOutputBytes: Int) {
        self.bytes = bytes
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumOutputBytes = maximumOutputBytes
        output.reserveCapacity(min(
            bytes.count + min(bytes.count / 4, 262_144),
            maximumOutputBytes
        ))
    }

    mutating func format() throws -> String {
        skipWhitespace()
        guard !isAtEnd else {
            throw JSONFormattingError.emptyInput
        }

        try parseValue(openContainerCount: 0)
        skipWhitespace()
        guard isAtEnd else {
            throw error("顶层值之后还有多余内容")
        }
        return String(decoding: output, as: UTF8.self)
    }

    private mutating func parseValue(openContainerCount: Int) throws {
        skipWhitespace()
        guard let byte = currentByte else {
            throw error("此处需要一个 JSON 值")
        }

        switch byte {
        case ASCII.leftBrace:
            try checkCanOpenContainer(openContainerCount: openContainerCount)
            try parseObject(level: openContainerCount + 1)
        case ASCII.leftBracket:
            try checkCanOpenContainer(openContainerCount: openContainerCount)
            try parseArray(level: openContainerCount + 1)
        case ASCII.quote:
            try append(try parseStringToken())
        case ASCII.minus, ASCII.zero...ASCII.nine:
            try append(try parseNumberToken())
        case ASCII.t:
            try parseLiteral("true")
        case ASCII.f:
            try parseLiteral("false")
        case ASCII.n:
            try parseLiteral("null")
        default:
            throw error("此处需要一个 JSON 值")
        }
    }

    private mutating func parseObject(level: Int) throws {
        advance()
        try append("{")
        skipWhitespace()

        if consume(ASCII.rightBrace) {
            try append("}")
            return
        }

        try append("\n")
        while true {
            skipWhitespace()
            guard currentByte == ASCII.quote else {
                throw error("对象的键必须是字符串")
            }

            try appendIndent(level)
            try append(try parseStringToken())
            skipWhitespace()
            guard consume(ASCII.colon) else {
                throw error("对象的键后面需要冒号")
            }
            try append(": ")
            try parseValue(openContainerCount: level)
            skipWhitespace()

            if consume(ASCII.comma) {
                skipWhitespace()
                if currentByte == ASCII.rightBrace {
                    throw error("对象末尾不能有逗号")
                }
                try append(",\n")
                continue
            }

            guard consume(ASCII.rightBrace) else {
                throw error("对象成员之间需要逗号，或使用 } 结束对象")
            }
            try append("\n")
            try appendIndent(level - 1)
            try append("}")
            return
        }
    }

    private mutating func parseArray(level: Int) throws {
        advance()
        try append("[")
        skipWhitespace()

        if consume(ASCII.rightBracket) {
            try append("]")
            return
        }

        try append("\n")
        while true {
            try appendIndent(level)
            try parseValue(openContainerCount: level)
            skipWhitespace()

            if consume(ASCII.comma) {
                skipWhitespace()
                if currentByte == ASCII.rightBracket {
                    throw error("数组末尾不能有逗号")
                }
                try append(",\n")
                continue
            }

            guard consume(ASCII.rightBracket) else {
                throw error("数组元素之间需要逗号，或使用 ] 结束数组")
            }
            try append("\n")
            try appendIndent(level - 1)
            try append("]")
            return
        }
    }

    private mutating func parseStringToken() throws -> String {
        let start = index
        advance()

        while let byte = currentByte {
            switch byte {
            case ASCII.quote:
                advance()
                return String(decoding: bytes[start..<index], as: UTF8.self)
            case ASCII.backslash:
                advance()
                guard let escapedByte = currentByte else {
                    throw error("字符串转义不完整")
                }
                switch escapedByte {
                case ASCII.quote, ASCII.backslash, ASCII.slash,
                     ASCII.b, ASCII.f, ASCII.n, ASCII.r, ASCII.t:
                    advance()
                case ASCII.u:
                    let escapePosition = index
                    advance()
                    for _ in 0..<4 {
                        guard let hexByte = currentByte, isHexDigit(hexByte) else {
                            throw error("\\u 后必须紧跟 4 位十六进制数字", at: escapePosition)
                        }
                        advance()
                    }
                default:
                    throw error("不支持的字符串转义")
                }
            case 0x00...0x1F:
                throw error("字符串中不能包含未转义的控制字符")
            default:
                advance()
            }
        }

        throw error("字符串缺少结束引号")
    }

    private mutating func parseNumberToken() throws -> String {
        let start = index

        if consume(ASCII.minus), isAtEnd {
            throw error("负号后需要数字")
        }

        guard let leadingDigit = currentByte else {
            throw error("此处需要数字")
        }
        switch leadingDigit {
        case ASCII.zero:
            advance()
            if let byte = currentByte, isDigit(byte) {
                throw error("数字不能以 0 开头")
            }
        case ASCII.one...ASCII.nine:
            advance()
            consumeDigits()
        default:
            throw error("此处需要数字")
        }

        if consume(ASCII.period) {
            guard let byte = currentByte, isDigit(byte) else {
                throw error("小数点后需要数字")
            }
            consumeDigits()
        }

        if currentByte == ASCII.e || currentByte == ASCII.capitalE {
            advance()
            if currentByte == ASCII.plus || currentByte == ASCII.minus {
                advance()
            }
            guard let byte = currentByte, isDigit(byte) else {
                throw error("指数部分需要数字")
            }
            consumeDigits()
        }

        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func parseLiteral(_ literal: StaticString) throws {
        let literalBytes = Array("\(literal)".utf8)
        let start = index
        guard index + literalBytes.count <= bytes.count,
              bytes[index..<(index + literalBytes.count)].elementsEqual(literalBytes) else {
            throw error("无法识别的 JSON 字面量")
        }
        index += literalBytes.count
        try append(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    private func checkCanOpenContainer(openContainerCount: Int) throws {
        guard openContainerCount < maximumNestingDepth else {
            throw error("嵌套层级不能超过 \(maximumNestingDepth) 层")
        }
    }

    private mutating func consumeDigits() {
        while let byte = currentByte, isDigit(byte) {
            advance()
        }
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte, isWhitespace(byte) {
            advance()
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard currentByte == byte else {
            return false
        }
        advance()
        return true
    }

    private mutating func advance() {
        index += 1
    }

    private mutating func appendIndent(_ level: Int) throws {
        try append(String(repeating: "  ", count: level))
    }

    private mutating func append(_ value: String) throws {
        let addedByteCount = value.utf8.count
        guard addedByteCount <= maximumOutputBytes - output.count else {
            throw JSONFormattingError.outputTooLarge(maximumBytes: maximumOutputBytes)
        }
        output.append(contentsOf: value.utf8)
    }

    private var currentByte: UInt8? {
        guard index < bytes.count else {
            return nil
        }
        return bytes[index]
    }

    private var isAtEnd: Bool {
        index >= bytes.count
    }

    private func error(_ message: String, at offset: Int? = nil) -> JSONFormattingError {
        let location = sourceLocation(at: offset ?? index)
        return .invalidJSON(
            message: message,
            line: location.line,
            column: location.column
        )
    }

    private func sourceLocation(at requestedOffset: Int) -> (line: Int, column: Int) {
        let offset = min(max(requestedOffset, 0), bytes.count)
        var line = 1
        var lineStart = 0
        var cursor = 0

        while cursor < offset {
            switch bytes[cursor] {
            case ASCII.carriageReturn:
                cursor += 1
                if cursor < offset, bytes[cursor] == ASCII.lineFeed {
                    cursor += 1
                }
                line += 1
                lineStart = cursor
            case ASCII.lineFeed:
                cursor += 1
                line += 1
                lineStart = cursor
            default:
                cursor += 1
            }
        }

        let columnText = String(decoding: bytes[lineStart..<offset], as: UTF8.self)
        return (line, columnText.count + 1)
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == ASCII.space
            || byte == ASCII.horizontalTab
            || byte == ASCII.lineFeed
            || byte == ASCII.carriageReturn
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (ASCII.zero...ASCII.nine).contains(byte)
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte)
            || (ASCII.lowercaseA...ASCII.lowercaseF).contains(byte)
            || (ASCII.capitalA...ASCII.capitalF).contains(byte)
    }

    private enum ASCII {
        static let horizontalTab: UInt8 = 0x09
        static let lineFeed: UInt8 = 0x0A
        static let carriageReturn: UInt8 = 0x0D
        static let space: UInt8 = 0x20
        static let quote: UInt8 = 0x22
        static let plus: UInt8 = 0x2B
        static let comma: UInt8 = 0x2C
        static let minus: UInt8 = 0x2D
        static let period: UInt8 = 0x2E
        static let slash: UInt8 = 0x2F
        static let zero: UInt8 = 0x30
        static let one: UInt8 = 0x31
        static let nine: UInt8 = 0x39
        static let colon: UInt8 = 0x3A
        static let capitalA: UInt8 = 0x41
        static let capitalE: UInt8 = 0x45
        static let capitalF: UInt8 = 0x46
        static let leftBracket: UInt8 = 0x5B
        static let backslash: UInt8 = 0x5C
        static let rightBracket: UInt8 = 0x5D
        static let lowercaseA: UInt8 = 0x61
        static let b: UInt8 = 0x62
        static let e: UInt8 = 0x65
        static let f: UInt8 = 0x66
        static let lowercaseF: UInt8 = 0x66
        static let n: UInt8 = 0x6E
        static let r: UInt8 = 0x72
        static let t: UInt8 = 0x74
        static let u: UInt8 = 0x75
        static let leftBrace: UInt8 = 0x7B
        static let rightBrace: UInt8 = 0x7D
    }
}
