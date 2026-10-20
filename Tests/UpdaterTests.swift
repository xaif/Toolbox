import XCTest
import CryptoKit
@testable import Toolbox

@MainActor
final class UpdaterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdaterTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Versions and the feed

    func testVersionsCompareNumberByNumber() throws {
        let v = { (text: String) in AppVersion(text)! }
        XCTAssertLessThan(v("0.9.3"), v("0.10.0"))
        XCTAssertLessThan(v("v0.1.0"), v("0.2"))
        XCTAssertEqual(v("1.0"), v("1.0.0"))
        XCTAssertEqual(Set([v("1.0"), v("1.0.0")]).count, 1)
        XCTAssertEqual(v("v2.1.0-beta").description, "2.1.0")
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNotNil(AppVersion.current)
    }

    func testFeedPicksTheNewestInstallableReleaseWithEveryChangeSince() throws {
        let releases = try UpdateFeed.decode(Data(Self.feed.utf8))
        let update = try XCTUnwrap(UpdateFeed.update(from: releases, current: AppVersion("0.1.0")!))
        // 0.4.0 is a draft and 0.3.1 a prerelease; 0.3.0 is newest with a DMG.
        XCTAssertEqual(update.version, AppVersion("0.3.0"))
        XCTAssertEqual(update.downloadURL.absoluteString, "https://example.com/Toolbox-0.3.0.dmg")
        XCTAssertEqual(update.downloadSize, 1234)
        XCTAssertEqual(update.digest, "sha256:abc")
        XCTAssertEqual(update.notes.map(\.version.description), ["0.3.0", "0.2.0"])
        XCTAssertEqual(update.notes.first?.markdown, "### New\n- **Teleprompter** under the notch\n- Updates")
        XCTAssertEqual(update.pageURL.absoluteString, "https://github.com/xaif/Toolbox/releases/tag/v0.3.0")

        XCTAssertNil(UpdateFeed.update(from: releases, current: AppVersion("0.3.0")!))
        XCTAssertEqual(UpdateFeed.notes(for: AppVersion("0.2.0")!, in: releases)?.markdown, "- Faster PDFs")
        XCTAssertEqual(UpdateFeed.changelog(fromBody: "- One\r\n- Two\r\n\r\n<!-- install -->\n---\nOpen the DMG"), "- One\n- Two")
        XCTAssertThrowsError(try UpdateFeed.decode(Data("{\"message\":\"rate limited\"}".utf8)))
    }

    func testReleaseNotesBecomeHeadingsBulletsAndParagraphs() {
        let blocks = ReleaseNotesBlock.blocks("""
        ### New
        - **Teleprompter** under the notch
          that follows your voice
        * Updates

        Thanks for using
        Toolbox.
        ---
        """)
        XCTAssertEqual(blocks, [
            .heading("New"),
            .bullet("**Teleprompter** under the notch that follows your voice"),
            .bullet("Updates"),
            .paragraph("Thanks for using Toolbox."),
        ])
        XCTAssertEqual(String(ReleaseNotesBlock.inline("**Bold** and `code`").characters), "Bold and code")
    }

    // MARK: Installing

    func testUpdateDownloadsChecksAndReplacesTheApp() async throws {
        let bundleID = "com.fiaxe.toolbox.updatertest"
        let installed = root.appendingPathComponent("Applications/Toolbox.app")
        try await makeApp(at: installed, version: "1.0.0", bundleID: bundleID)
        let dmg = try await makeDMG(version: "1.1.0", bundleID: bundleID)
        let size = Int64(try XCTUnwrap(try dmg.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        let digest = "sha256:" + SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()

        // Download it over HTTP, as from GitHub.
        let server = LocalHTTPServer { request in request.path == "/Toolbox-1.1.0.dmg" ? .file(dmg) : .notFound }
        try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/\(server.token)/Toolbox-1.1.0.dmg")!
        let progress = ProgressLog()
        let downloaded = try await UpdateInstaller.download(url, into: root.appendingPathComponent("download")) { progress.add($0) }
        XCTAssertEqual(try Data(contentsOf: downloaded), try Data(contentsOf: dmg))
        XCTAssertEqual(progress.values.last, 1)
        try UpdateInstaller.verify(downloaded, size: size, digest: digest)
        XCTAssertThrowsError(try UpdateInstaller.verify(downloaded, size: size, digest: "sha256:" + String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try UpdateInstaller.verify(downloaded, size: size + 1, digest: nil))

        // Only the expected version is staged, next to the installed app.
        do {
            _ = try await UpdateInstaller.stage(dmg: downloaded, version: AppVersion("1.2.0")!, bundleID: bundleID, nextTo: installed)
            XCTFail("Staged the wrong version")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("1.1.0"), error.localizedDescription)
        }
        let staged = try await UpdateInstaller.stage(dmg: downloaded, version: AppVersion("1.1.0")!, bundleID: bundleID, nextTo: installed)
        XCTAssertEqual(staged.deletingLastPathComponent(), installed.deletingLastPathComponent())
        XCTAssertEqual(Self.version(of: staged), "1.1.0")
        let mounts = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["info"])
        for path in [root.path, root.resolvingSymlinksInPath().path] {
            XCTAssertFalse(mounts.stdout.contains(path), "The DMG is still mounted")
        }

        // The swap waits for the app to quit, then puts the new version in its place.
        let quitter = Process()
        quitter.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try quitter.run()
        quitter.waitUntilExit()
        let swap = try UpdateInstaller.startSwap(replacing: installed, with: staged, after: quitter.processIdentifier,
                                                 relaunch: false, scriptFolder: root.appendingPathComponent("script"))
        swap.waitUntilExit()
        XCTAssertEqual(swap.terminationStatus, 0)
        XCTAssertEqual(Self.version(of: installed), "1.1.0")
        let left = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        XCTAssertEqual(left, ["Toolbox.app"])
        let verify = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--deep", "--strict", installed.path])
        XCTAssertEqual(verify.status, 0, verify.stderr)
    }

    func testTranslocatedOrReadOnlyCopiesDontUpdateThemselves() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Toolbox.app")
        XCTAssertNotNil(UpdateInstaller.problem(installingAt: translocated))
        XCTAssertNotNil(UpdateInstaller.problem(installingAt: URL(fileURLWithPath: "/System/Applications/Toolbox.app")))
        XCTAssertNil(UpdateInstaller.problem(installingAt: root.appendingPathComponent("Toolbox.app")))
    }

    // MARK: Helpers

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Double] = []
        func add(_ value: Double) { lock.withLock { list.append(value) } }
        var values: [Double] { lock.withLock { list } }
    }

    /// A tiny signed app bundle that looks like Toolbox to the installer.
    private func makeApp(at url: URL, version: String, bundleID: String) async throws {
        let executable = url.appendingPathComponent("Contents/MacOS/Toolbox")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": "1",
            "CFBundleExecutable": "Toolbox", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "13.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", url.path])
    }

    /// A DMG laid out like the release one: the app next to an Applications shortcut.
    private func makeDMG(version: String, bundleID: String) async throws -> URL {
        let staging = root.appendingPathComponent("dmg-\(version)", isDirectory: true)
        try await makeApp(at: staging.appendingPathComponent("Toolbox.app"), version: version, bundleID: bundleID)
        try FileManager.default.createSymbolicLink(at: staging.appendingPathComponent("Applications"),
                                                   withDestinationURL: URL(fileURLWithPath: "/Applications"))
        let dmg = root.appendingPathComponent("Toolbox-\(version).dmg")
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: [
            "create", "-volname", "Toolbox \(version)", "-srcfolder", staging.path, "-fs", "HFS+", "-format", "UDZO", "-quiet", dmg.path,
        ])
        return dmg
    }

    private static func version(of app: URL) -> String? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleShortVersionString"] as? String
    }

    private static let feed = #"""
    [
      {"tag_name": "v0.4.0", "name": "Toolbox 0.4.0", "body": "- Draft", "draft": true, "prerelease": false,
       "published_at": null, "html_url": "https://github.com/xaif/Toolbox/releases/tag/v0.4.0",
       "assets": [{"name": "Toolbox-0.4.0.dmg", "size": 1, "browser_download_url": "https://example.com/Toolbox-0.4.0.dmg"}]},
      {"tag_name": "v0.3.1", "name": "Toolbox 0.3.1", "body": "- Beta", "draft": false, "prerelease": true,
       "published_at": "2026-10-22T10:00:00Z", "html_url": "https://github.com/xaif/Toolbox/releases/tag/v0.3.1",
       "assets": [{"name": "Toolbox-0.3.1.dmg", "size": 1, "browser_download_url": "https://example.com/Toolbox-0.3.1.dmg"}]},
      {"tag_name": "v0.3.0", "name": "Toolbox 0.3.0",
       "body": "### New\r\n- **Teleprompter** under the notch\r\n- Updates\r\n\r\n<!-- install -->\r\n---\r\nOpen the DMG and drag Toolbox to Applications.",
       "draft": false, "prerelease": false, "published_at": "2026-10-21T10:00:00Z",
       "html_url": "https://github.com/xaif/Toolbox/releases/tag/v0.3.0",
       "assets": [{"name": "notes.txt", "size": 5, "browser_download_url": "https://example.com/notes.txt"},
                  {"name": "Toolbox-0.3.0.dmg", "size": 1234, "digest": "sha256:abc", "browser_download_url": "https://example.com/Toolbox-0.3.0.dmg"}]},
      {"tag_name": "v0.2.0", "name": "Toolbox 0.2.0", "body": "- Faster PDFs\n\n<!-- install -->\nOpen the DMG", "draft": false, "prerelease": false,
       "published_at": "2026-10-20T10:00:00Z", "html_url": "https://github.com/xaif/Toolbox/releases/tag/v0.2.0",
       "assets": [{"name": "Toolbox-0.2.0.dmg", "size": 1, "browser_download_url": "https://example.com/Toolbox-0.2.0.dmg"}]},
      {"tag_name": "v0.1.0", "name": "Toolbox 0.1.0", "body": "Open the DMG", "draft": false, "prerelease": false,
       "published_at": "2026-10-19T10:00:00Z", "html_url": "https://github.com/xaif/Toolbox/releases/tag/v0.1.0", "assets": []}
    ]
    """#
}
