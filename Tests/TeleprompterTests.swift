import XCTest
import SwiftUI
@testable import Toolbox

@MainActor
final class TeleprompterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TeleprompterTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Scripts

    func testHeadingsSplitTheScriptIntoCues() {
        let cues = TeleprompterParser.cues(in: """
        Hello there, everyone.

        # Intro
        This is the intro.
          ## Deep dive
        Line one
        Line two
        #
        Untitled after a bare hash.
        """)
        XCTAssertEqual(cues.map(\.title), [nil, "Intro", "Deep dive", nil])
        XCTAssertEqual(cues.map(\.text), ["Hello there, everyone.", "This is the intro.", "Line one\nLine two", "Untitled after a bare hash."])
        XCTAssertEqual(cues.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(cues.map(\.label), ["Opening", "Intro", "Deep dive", "Cue 4"])
        XCTAssertEqual(cues.map(\.words), [3, 4, 4, 5])
    }

    func testEmptyOpeningIsSkippedAndHeadingsWithoutTextStay() {
        let cues = TeleprompterParser.cues(in: "\n\n# One\n\n# Two\nWords here")
        XCTAssertEqual(cues.map(\.title), ["One", "Two"])
        XCTAssertEqual(cues.map(\.text), ["", "Words here"])
        XCTAssertTrue(TeleprompterParser.cues(in: "  \n ").isEmpty)
        XCTAssertEqual(TeleprompterParser.cues(in: "Just text").map(\.title), [nil])
    }

    func testNotesInBracketsAreNotCountedAndLookDifferent() {
        XCTAssertEqual(TeleprompterParser.wordCount("Hi [smile] there [long pause] friend"), 3)
        XCTAssertEqual(TeleprompterParser.wordCount("Nested [a [b] c] text"), 4)
        XCTAssertEqual(TeleprompterParser.wordCount("こんにちは世界"), 2)

        let styled = TeleprompterParser.styled("Hi [smile] there\n- point one\n* point two", noteColor: .red)
        XCTAssertEqual(String(styled.characters), "Hi [smile] there\n•  point one\n•  point two")
        let notes = styled.runs.filter { $0.inlinePresentationIntent == .emphasized }
            .map { String(styled[$0.range].characters) }
        XCTAssertEqual(notes, ["[smile]"])
        let stray = TeleprompterParser.styled("a ] b [c]", noteColor: .red)
        XCTAssertEqual(String(stray.characters), "a ] b [c]")
        XCTAssertEqual(stray.runs.filter { $0.inlinePresentationIntent == .emphasized }.map { String(stray[$0.range].characters) }, ["[c]"])
    }

    func testLibrarySavesAndReloadsScripts() throws {
        let folder = root.appendingPathComponent("Library", isDirectory: true)
        let library = TeleprompterLibrary(folder: folder)
        // A new library starts with the welcome script.
        XCTAssertEqual(library.scripts.map(\.title), [TeleprompterLibrary.welcome.title])
        let script = library.add(title: "Pitch", text: "# Hook\nHello")
        XCTAssertEqual(library.selectedID, script.id)
        library.update(script.id, text: "# Hook\nHello again")
        library.duplicate(script.id)
        XCTAssertEqual(library.scripts.map(\.title), ["Pitch", "Pitch copy", TeleprompterLibrary.welcome.title])
        library.delete(library.selectedID!)
        XCTAssertEqual(library.selectedID, library.scripts[1].id)
        library.saveNow()

        let reloaded = TeleprompterLibrary(folder: folder)
        XCTAssertEqual(reloaded.scripts.map(\.title), ["Pitch", TeleprompterLibrary.welcome.title])
        XCTAssertEqual(reloaded.script(script.id)?.text, "# Hook\nHello again")
        XCTAssertEqual(TeleprompterScript(title: "  ", text: "").displayTitle, "Untitled Script")
    }

    // MARK: Prompter

    func testSensitivityAndCalibrationAgree() {
        XCTAssertEqual(TeleprompterSettings.threshold(forSensitivity: 0), -20)
        XCTAssertEqual(TeleprompterSettings.threshold(forSensitivity: 1), -60)
        // Calibrating puts the threshold 9 dB over the noise.
        let sensitivity = TeleprompterSettings.sensitivity(forNoise: -50)
        XCTAssertEqual(TeleprompterSettings.threshold(forSensitivity: sensitivity), -41, accuracy: 0.001)
        XCTAssertEqual(TeleprompterSettings.sensitivity(forNoise: -10), 0.05)
        XCTAssertEqual(TeleprompterSettings.sensitivity(forNoise: -90), 1)
    }

    func testCueNavigationRemembersWhereYouWere() {
        let prompter = Teleprompter.shared
        XCTAssertFalse(prompter.isShowing)
        prompter.load(TeleprompterScript(title: "Talk", text: "# A\none two three\n# B\nfour five\n# C\nsix"))
        prompter.layoutChanged(TeleprompterLayout(height: 600, cueStarts: [0: 0, 1: 200, 2: 400]))
        XCTAssertEqual(prompter.cues.map(\.label), ["A", "B", "C"])
        XCTAssertEqual(prompter.words, 6)
        prompter.scroll(by: -50)
        XCTAssertEqual(prompter.offset, 0)

        prompter.scroll(by: 60)
        prompter.jump(toCue: 2)
        XCTAssertEqual(prompter.offset, 400)
        XCTAssertEqual(prompter.currentCue, 2)
        XCTAssertEqual(prompter.savedOffset, 60)
        prompter.returnToSavedPlace()
        XCTAssertEqual(prompter.offset, 60)
        XCTAssertNil(prompter.savedOffset)
        XCTAssertEqual(prompter.currentCue, 0)

        prompter.nextCue()
        XCTAssertEqual(prompter.offset, 200)
        XCTAssertEqual(prompter.currentCue, 1)
        prompter.previousCue()
        XCTAssertEqual(prompter.offset, 0)
        prompter.nextCue(); prompter.nextCue(); prompter.nextCue()
        XCTAssertEqual(prompter.offset, 400)

        // The text stops when its last line reaches the top.
        prompter.scroll(by: 10_000)
        XCTAssertEqual(prompter.offset, prompter.maxOffset)
        XCTAssertEqual(prompter.maxOffset, 600 - prompter.lineHeight, accuracy: 0.001)
        XCTAssertEqual(prompter.progress, 1)
        XCTAssertEqual(prompter.secondsLeft, 0)

        // Reflowed text keeps your place.
        prompter.scroll(by: -10_000)
        prompter.scroll(by: 150)
        prompter.layoutChanged(TeleprompterLayout(height: 1200, cueStarts: [0: 0, 1: 400, 2: 800]))
        XCTAssertEqual(prompter.offset, 300, accuracy: 0.001)

        // Edited text keeps you at the same spot in the cue you're reading instead.
        prompter.load(TeleprompterScript(title: "Talk", text: "# A\none two three more\n# B\nfour five\n# C\nsix seven"))
        prompter.layoutChanged(TeleprompterLayout(height: 1300, cueStarts: [0: 0, 1: 500, 2: 900]))
        XCTAssertEqual(prompter.offset, 300, accuracy: 0.001)
        prompter.jump(toCue: 1)
        prompter.scroll(by: 20)
        prompter.load(TeleprompterScript(title: "Talk", text: "# A\none two three more words\n# B\nfour five\n# C\nsix seven"))
        prompter.layoutChanged(TeleprompterLayout(height: 1400, cueStarts: [0: 0, 1: 600, 2: 1000]))
        XCTAssertEqual(prompter.offset, 620, accuracy: 0.001)
        XCTAssertEqual(prompter.currentCue, 1)
    }

    func testRemoteCommandsAndStateHaveTheShapeThePageUses() throws {
        let command = try JSONDecoder().decode(TeleprompterRemoteCommand.self, from: Data(#"{"action":"cue","index":2}"#.utf8))
        XCTAssertEqual(command, TeleprompterRemoteCommand(action: "cue", index: 2))
        let scroll = try JSONDecoder().decode(TeleprompterRemoteCommand.self, from: Data(#"{"action":"scroll","lines":-1.25}"#.utf8))
        XCTAssertEqual(scroll.lines, -1.25)

        let state = TeleprompterRemoteState(showing: true, playing: false, moving: false, title: "Talk", cues: ["A"], cue: 0,
                                            progress: 0.5, wpm: 140, canGoBack: true, countdown: nil, listening: true,
                                            speaking: false, secondsLeft: 75, finished: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        let page = TeleprompterRemotePage.html
        for key in json.keys {
            XCTAssertTrue(page.contains("s.\(key)"), "The remote page never reads \(key)")
        }
        for action in ["toggle", "show", "faster", "slower", "scroll", "cue", "next", "previous", "back", "restart", "hide"] {
            XCTAssertTrue(page.contains("\"\(action)\""), "The remote page never sends \(action)")
        }
    }
}
