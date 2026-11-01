import XCTest
@testable import OpenPushSetupKit

/// Backups, rollback, and refusing to edit a file setup cannot read.
final class BackupTests: XCTestCase {
    private var workspaces: [FixtureWorkspace] = []
    private var folders: [URL] = []

    override func tearDown() {
        workspaces.forEach { $0.remove() }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func workspace(_ fixture: String) throws -> FixtureWorkspace {
        let workspace = try FixtureWorkspace(fixture)
        workspaces.append(workspace)
        return workspace
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openpush-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    func testEachRunGetsItsOwnBackupFolder() throws {
        let fixture = try workspace("TwoGroups")
        let pristine = try fixture.data("Duo-Info.plist")
        try fixture.apply(fixture.options { $0.timestamp = "same" })
        let report = try fixture.apply(fixture.options { $0.timestamp = "same"; $0.appID = "app-2" })

        XCTAssertEqual(report.backupFolder, ".openpush/backup/same-2")
        XCTAssertEqual(try fixture.data(".openpush/backup/same/Duo-Info.plist"), pristine,
                       "the first run's backup is never overwritten")
        XCTAssertEqual(try fixture.plist(".openpush/backup/same-2/Duo-Info.plist")["OpenPushAppID"] as? String, "app-1")
    }

    func testFilesOutsideTheProjectWithTheSameNameDoNotCollide() throws {
        let project = try temporaryFolder()
        let first = try temporaryFolder().appendingPathComponent("Info.plist")
        let second = try temporaryFolder().appendingPathComponent("Info.plist")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        let backup = BackupStore(projectFolder: project, timestamp: "t")
        try backup.preserve(first)
        try backup.preserve(second)
        let copies = try FileManager.default.subpathsOfDirectory(atPath: backup.root.path)
            .filter { $0.hasSuffix("Info.plist") }
        XCTAssertEqual(copies.count, 2, "\(copies)")
        XCTAssertTrue(copies.allSatisfy { $0.hasPrefix("external/") })
    }

    func testAFailedWriteIsRolledBack() throws {
        let fixture = try workspace("TwoGroups")
        let before = try fixture.snapshot()
        let projectFolder = fixture.projectURL.path
        // The pbxproj cannot be replaced, so writing fails after the plists.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: projectFolder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projectFolder) }

        XCTAssertThrowsError(try fixture.apply(fixture.options()))
        let after = try fixture.snapshot().filter { !$0.key.hasPrefix(".openpush/") }
        XCTAssertEqual(after, before, "the Info.plists written before the failure are put back")
    }

    func testAnUnreadablePlistStopsTheRunInsteadOfBeingEmptied() throws {
        let fixture = try workspace("TwoGroups")
        try Data("not a plist".utf8).write(to: fixture.folder.appendingPathComponent("Duo.entitlements"))
        let before = try fixture.snapshot()

        XCTAssertThrowsError(try fixture.apply(fixture.options { $0.appGroup = "group.com.example.duo.push" })) { error in
            guard case SetupError.unreadablePlist(let path) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(path.hasSuffix("Duo.entitlements"))
        }
        XCTAssertEqual(try fixture.snapshot(), before)
    }
}
