import XCTest
@testable import Molo

final class AppleDockImportTests: XCTestCase {
    private let suite = "local.molo.tests.dock"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func tile(_ url: String, type: String) -> [String: Any] {
        ["tile-type": type, "tile-data": ["file-data": ["_CFURLString": url, "_CFURLStringType": 15]]]
    }

    func testImportsAppsAndFoldersButNotFilesOrLinks() throws {
        let dock = try XCTUnwrap(UserDefaults(suiteName: suite))
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("molo-test.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        dock.set([
            tile("file:///System/Applications/Mail.app/", type: "file-tile"),
            tile("file:///System/Applications/Calendar.app/", type: "file-tile"),
        ], forKey: "persistent-apps")
        dock.set([
            tile(downloads.absoluteString, type: "directory-tile"),
            tile(file.absoluteString, type: "file-tile"),
            ["tile-type": "url-tile", "tile-data": ["url": ["_CFURLString": "https://example.com"]]],
        ], forKey: "persistent-others")

        let imported = AppsModel.importAppleDock(from: dock)

        XCTAssertEqual(imported, [
            "/System/Applications/Mail.app",
            "/System/Applications/Calendar.app",
            downloads.path,
        ])
    }

    func testEmptyDockImportsNothing() throws {
        let dock = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(AppsModel.importAppleDock(from: dock), [])
    }
}
