import XCTest
@testable import OpenPushSetupKit

final class AnswerFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openpush-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRewritingReplacesFoundAndKeepsChoicesAndUnknownFields() throws {
        let url = folder.appendingPathComponent(SetupAnswerFile.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"schema": "openpush-setup/1", "platform": "ios",
             "found": [{"kind": "app_group", "id": "group.stale", "source": "x", "vendor": null,
                        "editable": true, "details": {}}],
             "choices": {"app_group": {"mode": "reuse", "value": "group.kept"}},
             "note": "kept"}
            """.utf8).write(to: url)

        var answers = try SetupAnswerFile.load(from: url)
        try answers.replaceFound([SetupFinding(kind: .appGroup, id: "group.fresh", source: "App.entitlements")])
        try answers.write(to: url)

        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(written["note"] as? String, "kept")
        XCTAssertEqual((written["choices"] as? [String: [String: String]])?["app_group"]?["value"], "group.kept")
        let found = try XCTUnwrap(written["found"] as? [[String: Any]])
        XCTAssertEqual(found.map { $0["id"] as? String }, ["group.fresh"])
        XCTAssertTrue(found[0].keys.contains("vendor"), "vendor is written as null, not left out")
        XCTAssertTrue(found[0]["vendor"] is NSNull)
    }

    func testANewFileCarriesTheSchemaAndPlatform() throws {
        let answers = try SetupAnswerFile.load(from: folder.appendingPathComponent("missing.json"))
        XCTAssertEqual(answers.document["schema"] as? String, "openpush-setup/1")
        XCTAssertEqual(answers.document["platform"] as? String, "ios")
    }

    func testFindingsRoundTrip() throws {
        let finding = SetupFinding(kind: .serviceExtension, id: "NSE", source: "Info.plist", vendor: nil,
                                   details: ["target": "NSE", "embedded": true, "sources": .strings(["a.swift"])])
        let decoded = try JSONDecoder().decode(SetupFinding.self, from: JSONEncoder().encode(finding))
        XCTAssertEqual(decoded, finding)
    }
}
