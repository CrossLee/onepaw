import Foundation
import Testing
@testable import CrossToolCore

@Test func globalShortcutCommandsKeepStablePersistenceAndRegistrationIdentifiers() throws {
    let expected: [GlobalShortcutCommand: (rawValue: String, registrationID: UInt32)] = [
        .screenshotRegion: ("screenshot.region", 1),
        .screenshotWindow: ("screenshot.window", 2),
        .screenshotScreen: ("screenshot.screen", 3),
        .screenshotDelayed: ("screenshot.delayed", 4),
        .screenshotFramed: ("screenshot.framed", 5),
        .screenshotMultiWindow: ("screenshot.multiWindow", 6),
        .screenshotScrolling: ("screenshot.scrolling", 7),
        .recordCurrentDisplay: ("recording.currentDisplay", 101),
        .recordRegion: ("recording.region", 102),
        .recordWindow: ("recording.window", 103),
        .stopRecording: ("recording.stop", 104),
        .pickColor: ("color.pick", 201),
        .translateText: ("translation.text", 301),
        .formatClipboardJSON: ("developer.jsonFormatClipboard", 401),
        .showMainWindow: ("application.showMainWindow", 501),
    ]

    #expect(expected.count == GlobalShortcutCommand.allCases.count)
    #expect(Set(GlobalShortcutCommand.allCases.map(\.registrationID)).count == expected.count)

    for command in GlobalShortcutCommand.allCases {
        let identifiers = try #require(expected[command])
        #expect(command.rawValue == identifiers.rawValue)
        #expect(command.registrationID == identifiers.registrationID)
        #expect(GlobalShortcutCommand(registrationID: identifiers.registrationID) == command)

        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(GlobalShortcutCommand.self, from: encoded)
        #expect(decoded == command)
    }

    #expect(GlobalShortcutCommand(registrationID: 0) == nil)
    #expect(GlobalShortcutCommand(registrationID: UInt32.max) == nil)
}

@Test func globalShortcutCommandsBridgeToStringKeyedPersistedBindings() {
    let region = GlobalShortcut(keyCode: 18, modifiers: [.control, .shift])
    let recording = GlobalShortcut(keyCode: 15, modifiers: [.command])
    let stopRecording = GlobalShortcut(keyCode: 1, modifiers: [.control, .option])
    let jsonFormatting = GlobalShortcut(keyCode: 40, modifiers: [.control, .option])
    let shortcuts: [GlobalShortcutCommand: GlobalShortcut] = [
        .screenshotRegion: region,
        .recordRegion: recording,
        .stopRecording: stopRecording,
        .formatClipboardJSON: jsonFormatting,
    ]

    let bindings = GlobalShortcutCommand.persistedBindings(from: shortcuts)
    #expect(bindings == [
        "screenshot.region": region,
        "recording.region": recording,
        "recording.stop": stopRecording,
        "developer.jsonFormatClipboard": jsonFormatting,
    ])

    var withFutureCommand = bindings
    withFutureCommand["future.command"] = GlobalShortcut(
        keyCode: 40,
        modifiers: [.control]
    )
    #expect(
        GlobalShortcutCommand.shortcuts(fromPersistedBindings: withFutureCommand)
            == shortcuts
    )
}

@Test func olderPersistedShortcutPayloadLeavesStopRecordingUnbound() {
    let region = GlobalShortcut(keyCode: 18, modifiers: [.control, .shift])
    let olderBindings = ["screenshot.region": region]

    let shortcuts = GlobalShortcutCommand.shortcuts(
        fromPersistedBindings: olderBindings
    )

    #expect(shortcuts[.screenshotRegion] == region)
    #expect(shortcuts[.stopRecording] == nil)
}

@Test func globalShortcutDefaultLabelsUseExplicitMacModifierOrder() {
    let region = GlobalShortcut(
        keyCode: 18,
        modifiers: [.control, .shift]
    )
    let commandOptionK = GlobalShortcut(
        keyCode: 40,
        modifiers: [.command, .option]
    )

    #expect(region.keyDisplay == "1")
    #expect(region.displayLabel == "Ctrl+Shift+1")
    #expect(commandOptionK.displayLabel == "Option+Command+K")
    #expect(region.isValid)
    #expect(commandOptionK.isValid)
    #expect(GlobalShortcut.defaultKeyDisplay(for: 36) == "↩")
    #expect(GlobalShortcut.defaultKeyDisplay(for: 64) == "F17")
    #expect(GlobalShortcut.defaultKeyDisplay(for: 90) == "F20")
    #expect(GlobalShortcut.defaultKeyDisplay(for: 102) == "英数")
}

@Test func globalShortcutControlLabelsAreUnambiguousForTwoAndThreeKeyCombinations() {
    let controlA = GlobalShortcut(keyCode: 0, modifiers: [.control])
    let controlShiftA = GlobalShortcut(
        keyCode: 0,
        modifiers: [.control, .shift]
    )
    let allModifiersA = GlobalShortcut(
        keyCode: 0,
        modifiers: [.command, .control, .option, .shift]
    )

    #expect(controlA.displayLabel == "Ctrl+A")
    #expect(controlShiftA.displayLabel == "Ctrl+Shift+A")
    #expect(
        allModifiersA.displayLabel
            == "Ctrl+Option+Shift+Command+A"
    )
    #expect(controlA.isValid)
    #expect(controlShiftA.isValid)
    #expect(allModifiersA.isValid)
}

@Test func globalShortcutRequiresCommandOrControlModifier() {
    let bareKey = GlobalShortcut(keyCode: 8, modifiers: [])
    let commandOnly = GlobalShortcut(keyCode: 8, modifiers: [.command])
    let controlOnly = GlobalShortcut(keyCode: 8, modifiers: [.control])
    let shiftOnly = GlobalShortcut(keyCode: 8, modifiers: [.shift])
    let optionOnly = GlobalShortcut(keyCode: 8, modifiers: [.option])
    let shiftOption = GlobalShortcut(keyCode: 8, modifiers: [.shift, .option])
    let controlShift = GlobalShortcut(keyCode: 8, modifiers: [.control, .shift])
    let commandControl = GlobalShortcut(keyCode: 8, modifiers: [.command, .control])

    #expect(bareKey.validationIssues.contains(.requiresCommandOrControlModifier))
    #expect(shiftOnly.validationIssues.contains(.requiresCommandOrControlModifier))
    #expect(optionOnly.validationIssues.contains(.requiresCommandOrControlModifier))
    #expect(shiftOption.validationIssues.contains(.requiresCommandOrControlModifier))
    #expect(
        commandOnly.validationIssues.contains(
            .commandOnlyShortcutWouldOverrideApplications
        )
    )
    #expect(controlOnly.isValid)
    #expect(controlShift.isValid)
    #expect(commandControl.isValid)
    #expect(
        GlobalShortcutValidationIssue.requiresCommandOrControlModifier
            .errorDescription?.contains("Ctrl") == true
    )
}

@Test func unsafeLegacyCommandOnlyBindingsMigrateWithoutDroppingSafeCustomizations() {
    let unsafeRequired = GlobalShortcut(keyCode: 1, modifiers: [.command])
    let safeWindow = GlobalShortcut(keyCode: 15, modifiers: [.control])
    let unsafeOptional = GlobalShortcut(keyCode: 3, modifiers: [.command])
    let safeRecording = GlobalShortcut(keyCode: 4, modifiers: [.control, .option])
    let fallback = GlobalShortcut(keyCode: 18, modifiers: [.control, .shift])

    let result = GlobalShortcutCommand.migratingUnsafeCommandOnlyBindings(
        [
            .screenshotRegion: unsafeRequired,
            .screenshotWindow: safeWindow,
            .screenshotScreen: GlobalShortcut(
                keyCode: 20,
                modifiers: [.control, .shift]
            ),
            .screenshotFramed: unsafeOptional,
            .recordCurrentDisplay: safeRecording,
        ],
        requiredCommands: [
            .screenshotRegion,
            .screenshotWindow,
            .screenshotScreen,
        ],
        fallbackCandidates: [fallback]
    )

    #expect(result?.shortcuts[.screenshotRegion] == fallback)
    #expect(result?.shortcuts[.screenshotWindow] == safeWindow)
    #expect(result?.shortcuts[.recordCurrentDisplay] == safeRecording)
    #expect(result?.shortcuts[.screenshotFramed] == nil)
    #expect(result?.resetCommands == [.screenshotRegion])
    #expect(result?.clearedCommands == [.screenshotFramed])
}

@Test func globalShortcutRejectsEscapeModifiersFnAndMediaKeys() {
    let invalidCodes: [UInt32] = [
        53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
        72, 73, 74, 127, UInt32.max,
    ]

    for keyCode in invalidCodes {
        let shortcut = GlobalShortcut(
            keyCode: keyCode,
            keyDisplay: "X",
            modifiers: [.control, .shift]
        )
        #expect(shortcut.validationIssues.contains(.unsupportedTriggerKey))
    }

    #expect(GlobalShortcut(keyCode: 0, modifiers: [.control, .shift]).isValid)
    #expect(GlobalShortcut(keyCode: 122, modifiers: [.control, .shift]).isValid)
}

@Test func globalShortcutConflictIgnoresDisplaySpelling() {
    let first = GlobalShortcut(
        keyCode: 18,
        keyDisplay: "1",
        modifiers: [.control, .shift]
    )
    let sameRegistration = GlobalShortcut(
        keyCode: 18,
        keyDisplay: "!",
        modifiers: [.control, .shift]
    )
    let differentModifiers = GlobalShortcut(
        keyCode: 18,
        keyDisplay: "1",
        modifiers: [.command, .shift]
    )

    #expect(first.conflicts(with: sameRegistration))
    #expect(!first.conflicts(with: differentModifiers))
}

@Test func globalShortcutCodableRoundTripPreservesKeyDisplayAndModifiers() throws {
    let original = GlobalShortcut(
        keyCode: 37,
        keyDisplay: "L",
        modifiers: [.command, .control, .shift]
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(GlobalShortcut.self, from: data)

    #expect(decoded == original)
    #expect(decoded.displayLabel == "Ctrl+Shift+Command+L")
}

@Test func globalShortcutReportsUnsupportedModifierAndBlankDisplay() {
    let shortcut = GlobalShortcut(
        keyCode: 18,
        keyDisplay: "  ",
        modifiers: GlobalShortcutModifiers(rawValue: 0b1_0011)
    )

    #expect(shortcut.validationIssues.contains(.unsupportedModifier))
    #expect(shortcut.validationIssues.contains(.missingKeyDisplay))
}
