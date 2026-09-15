import CrossToolCore
import Foundation
import Testing
@testable import CrossToolApp

@Suite("Share access code preferences")
struct ShareAccessCodeSettingsTests {
    @Test("A missing preference starts in random mode")
    func missingPreference() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let loaded = ShareAccessCodePreferences.load(
            from: defaults,
            makeRandom: { "random2345" }
        )

        #expect(loaded == LoadedShareAccessCode(value: "random2345", usesCustomValue: false))
        #expect(defaults.string(forKey: ShareAccessCodePreferences.defaultsKey) == nil)
    }

    @Test("A custom access code is normalized, persisted, and restored")
    func customPreference() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let saved = try ShareAccessCodePreferences.saveCustom(
            " Class_2026 ",
            to: defaults
        )
        let loaded = ShareAccessCodePreferences.load(
            from: defaults,
            makeRandom: { "unused2345" }
        )

        #expect(saved == "Class_2026")
        #expect(loaded == LoadedShareAccessCode(value: "Class_2026", usesCustomValue: true))
        #expect(defaults.string(forKey: ShareAccessCodePreferences.defaultsKey) == "Class_2026")
    }

    @Test("An invalid persisted value fails closed to a random access code")
    func invalidPreference() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("bad?code", forKey: ShareAccessCodePreferences.defaultsKey)

        let loaded = ShareAccessCodePreferences.load(
            from: defaults,
            makeRandom: { "fallback23" }
        )

        #expect(loaded == LoadedShareAccessCode(value: "fallback23", usesCustomValue: false))
        #expect(defaults.string(forKey: ShareAccessCodePreferences.defaultsKey) == nil)
    }

    @Test("Restoring random mode removes the custom preference")
    func clearPreference() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try ShareAccessCodePreferences.saveCustom("class2026", to: defaults)

        ShareAccessCodePreferences.clearCustom(from: defaults)

        #expect(defaults.string(forKey: ShareAccessCodePreferences.defaultsKey) == nil)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "ShareAccessCodeSettingsTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
