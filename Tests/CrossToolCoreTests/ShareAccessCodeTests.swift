import Foundation
import Testing
@testable import CrossToolCore

@Suite("Share access code")
struct ShareAccessCodeTests {
    @Test("Valid access codes are trimmed and preserve case")
    func validCodes() throws {
        #expect(try ShareAccessCode.normalized(" class2026 ") == "class2026")
        #expect(try ShareAccessCode.normalized("Class_2026") == "Class_2026")
        #expect(try ShareAccessCode.normalized("abc-12") == "abc-12")
        #expect(try ShareAccessCode.normalized(String(repeating: "a", count: 24)).count == 24)
    }

    @Test("Invalid lengths and URL-reserved characters are rejected")
    func invalidCodes() {
        #expect(throws: ShareAccessCodeValidationError.tooShort) {
            try ShareAccessCode.normalized("abc12")
        }
        #expect(throws: ShareAccessCodeValidationError.tooLong) {
            try ShareAccessCode.normalized(String(repeating: "a", count: 25))
        }

        for value in ["abc 123", "abc&123", "abc?123", "abc#123", "abc=123", "abc/123", "abc%123", "课堂2026"] {
            #expect(throws: ShareAccessCodeValidationError.unsupportedCharacters) {
                try ShareAccessCode.normalized(value)
            }
        }
    }

    @Test("Random access codes are short, readable, valid, and not constant")
    func randomCodes() throws {
        let values = Set((0..<32).map { _ in ShareAccessCode.makeRandom() })
        #expect(values.count == 32)
        for value in values {
            #expect(value.count == ShareAccessCode.defaultRandomLength)
            #expect(try ShareAccessCode.normalized(value) == value)
            #expect(!value.contains("0"))
            #expect(!value.contains("1"))
            #expect(!value.contains("i"))
            #expect(!value.contains("l"))
            #expect(!value.contains("o"))
        }
    }

    @Test("Share links use URL query items instead of string interpolation")
    func linkBuilding() throws {
        let url = try #require(ShareLinkBuilder.url(
            host: "192.168.1.25",
            port: 5421,
            accessCode: "Class_2026"
        ))
        #expect(url.absoluteString == "http://192.168.1.25:5421/?token=Class_2026")

        let defensiveURL = try #require(ShareLinkBuilder.url(
            host: "127.0.0.1",
            port: 5421,
            accessCode: "space and?question"
        ))
        #expect(defensiveURL.absoluteString.contains("token=space%20and?question"))
        let defensiveComponents = try #require(URLComponents(
            url: defensiveURL,
            resolvingAgainstBaseURL: false
        ))
        #expect(defensiveComponents.queryItems?.first?.value == "space and?question")

        #expect(
            ShareLinkBuilder.relativeURL(
                path: "/download/123",
                accessCode: "abc-12"
            ) == "/download/123?token=abc-12"
        )
    }
}
