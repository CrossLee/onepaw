import Foundation
import Testing
@testable import CrossToolCore

@Suite("Developer text tools")
struct DeveloperTextToolsTests {
    @Suite("JSON formatting")
    struct JSONFormattingTests {
        @Test("Nested objects and arrays use two-space indentation")
        func formatsNestedContainers() throws {
            let input = #"{"name":"一爪","items":[1,true,null,{"ok":false}],"empty":{}}"#
            let expected = """
            {
              "name": "一爪",
              "items": [
                1,
                true,
                null,
                {
                  "ok": false
                }
              ],
              "empty": {}
            }
            """

            #expect(try JSONTextFormatter.format(input) == expected)
        }

        @Test("Object order and duplicate keys are preserved")
        func preservesOrderAndDuplicateKeys() throws {
            let input = #"{"z":1,"a":2,"z":3}"#
            let formatted = try JSONTextFormatter.format(input)

            #expect(formatted == """
            {
              "z": 1,
              "a": 2,
              "z": 3
            }
            """)
        }

        @Test("Number and string token spellings are preserved")
        func preservesTokenSpellings() throws {
            let input = #"{"number":1.2300e+02,"escaped":"\/\u4e00\n","solidus":"\/"}"#
            let formatted = try JSONTextFormatter.format(input)

            #expect(formatted.contains("1.2300e+02"))
            #expect(formatted.contains(#""escaped": "\/\u4e00\n""#))
            #expect(formatted.contains(#""solidus": "\/""#))
        }

        @Test("Top-level scalar values and Unicode are supported")
        func supportsTopLevelScalars() throws {
            #expect(try JSONTextFormatter.format("  true\n") == "true")
            #expect(try JSONTextFormatter.format(#" "猫爪🐾" "#) == #""猫爪🐾""#)
            #expect(try JSONTextFormatter.format("-0.50E-2") == "-0.50E-2")
        }

        @Test("Only JSON whitespace is ignored")
        func rejectsNonJSONWhitespace() {
            expectInvalidJSON("{\"a\":\u{00A0}1}", line: 1, column: 6)
        }

        @Test("Empty input is reported separately")
        func rejectsEmptyInput() {
            #expect(throws: JSONFormattingError.emptyInput) {
                try JSONTextFormatter.format(" \t\r\n ")
            }
        }

        @Test("Input is limited to one MiB of UTF-8")
        func enforcesInputLimit() throws {
            let exactlyAtLimit = "\"" + String(
                repeating: "a",
                count: JSONTextFormatter.maximumInputBytes - 2
            ) + "\""
            #expect(try JSONTextFormatter.format(exactlyAtLimit) == exactlyAtLimit)

            let oversized = exactlyAtLimit + " "
            #expect(throws: JSONFormattingError.inputTooLarge(
                maximumBytes: JSONTextFormatter.maximumInputBytes
            )) {
                try JSONTextFormatter.format(oversized)
            }
        }

        @Test("Pathological indentation cannot create an unbounded result")
        func enforcesOutputLimit() {
            let deepestValues = Array(repeating: "0", count: 20_000)
                .joined(separator: ",")
            let input = String(repeating: "[", count: 256)
                + deepestValues
                + String(repeating: "]", count: 256)

            #expect(input.utf8.count < JSONTextFormatter.maximumInputBytes)
            #expect(throws: JSONFormattingError.outputTooLarge(
                maximumBytes: JSONTextFormatter.maximumOutputBytes
            )) {
                try JSONTextFormatter.format(input)
            }
        }

        @Test("Trailing commas are rejected with a source location")
        func rejectsTrailingCommas() {
            expectInvalidJSON("""
            {
              "a": 1,
            }
            """, line: 3, column: 1)
            expectInvalidJSON("[1,]", line: 1, column: 4)
        }

        @Test("Invalid number spellings are rejected")
        func rejectsInvalidNumbers() {
            expectInvalidJSON("01", line: 1, column: 2)
            expectInvalidJSON("+1", line: 1, column: 1)
            expectInvalidJSON("1.", line: 1, column: 3)
            expectInvalidJSON("1e+", line: 1, column: 4)
        }

        @Test("Invalid strings are rejected")
        func rejectsInvalidStrings() {
            expectInvalidJSON(#""bad\xescape""#, line: 1, column: 6)
            expectInvalidJSON(#""bad\u12x4""#, line: 1, column: 6)
            expectInvalidJSON("\"line\nbreak\"", line: 1, column: 6)
            expectInvalidJSON(#""unterminated"#, line: 1, column: 14)
        }

        @Test("Incomplete containers and extra top-level content are rejected")
        func rejectsIncompleteOrExtraContent() {
            expectInvalidJSON("{\"a\":1", line: 1, column: 7)
            expectInvalidJSON("[1 2]", line: 1, column: 4)
            expectInvalidJSON("true false", line: 1, column: 6)
        }

        @Test("Nesting is capped at 256 containers")
        func enforcesNestingDepth() throws {
            let accepted = String(repeating: "[", count: 256)
                + "0"
                + String(repeating: "]", count: 256)
            _ = try JSONTextFormatter.format(accepted)

            let rejected = String(repeating: "[", count: 257)
                + "0"
                + String(repeating: "]", count: 257)
            expectInvalidJSON(rejected, line: 1, column: 257)
        }

        private func expectInvalidJSON(
            _ input: String,
            line expectedLine: Int,
            column expectedColumn: Int
        ) {
            do {
                _ = try JSONTextFormatter.format(input)
                Issue.record("Expected invalid JSON to throw")
            } catch let error as JSONFormattingError {
                guard case let .invalidJSON(_, line, column) = error else {
                    Issue.record("Expected invalidJSON, received \(error)")
                    return
                }
                #expect(line == expectedLine)
                #expect(column == expectedColumn)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Suite("Base64 encoding")
    struct Base64EncodingTests {
        @Test("UTF-8 text uses standard Base64")
        func encodesUTF8Text() {
            #expect(Base64TextEncoder.encode("Hello") == "SGVsbG8=")
            #expect(Base64TextEncoder.encode("一爪") == "5LiA54iq")
            #expect(Base64TextEncoder.encode("🐾") == "8J+Qvg==")
            #expect(Base64TextEncoder.encode("a\nb") == "YQpi")
        }

        @Test("Empty text produces empty Base64")
        func encodesEmptyText() {
            #expect(Base64TextEncoder.encode("").isEmpty)
        }
    }

    @Suite("UUID generation")
    struct UUIDGenerationTests {
        @Test("Generated UUIDs are unique, parseable, and one per line")
        func generatesUUIDs() throws {
            let output = try UUIDTextGenerator.generate(count: 100)
            let values = output.split(separator: "\n").map(String.init)

            #expect(values.count == 100)
            #expect(Set(values).count == 100)
            #expect(values.allSatisfy { UUID(uuidString: $0) != nil })
            #expect(values.allSatisfy { $0 == $0.lowercased() })
        }

        @Test("Letter casing follows the requested format")
        func appliesRequestedCase() throws {
            let lowercase = try UUIDTextGenerator.generate(count: 1, format: .lowercase)
            let uppercase = try UUIDTextGenerator.generate(count: 1, format: .uppercase)

            #expect(lowercase == lowercase.lowercased())
            #expect(uppercase == uppercase.uppercased())
            #expect(UUID(uuidString: lowercase) != nil)
            #expect(UUID(uuidString: uppercase) != nil)
        }

        @Test("Count must be between one and one hundred")
        func validatesCount() {
            let expectedError = UUIDGenerationError.invalidCount(minimum: 1, maximum: 100)
            #expect(throws: expectedError) {
                try UUIDTextGenerator.generate(count: 0)
            }
            #expect(throws: expectedError) {
                try UUIDTextGenerator.generate(count: 101)
            }
        }
    }
}
