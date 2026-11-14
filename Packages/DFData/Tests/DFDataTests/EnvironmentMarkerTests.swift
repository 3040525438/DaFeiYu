import XCTest
import Foundation
import DFCore
@testable import DFData

/// 目录归属标记（E11、E12、E13、E16、E18）
final class EnvironmentMarkerTests: XCTestCase {

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func listing(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    // MARK: - E16 原子写入

    func testE16_MarkerWriteIsAtomic() throws {
        let root = try makeTempRoot()
        let url = EnvironmentMarkerStore.markerURL(root: root)
        let marker = EnvironmentMarker(environment: .lab, createdAt: 1, createdBy: "test+1")

        try EnvironmentMarkerStore.writeAtomically(marker, to: url)

        let files = listing(root)
        XCTAssertEqual(files, [EnvironmentMarkerStore.fileName], "不得残留临时文件")
        XCTAssertFalse(files.contains { $0.contains(".tmp-") })

        let readBack = try EnvironmentMarkerStore.read(from: url)
        XCTAssertEqual(readBack, marker)

        // 覆盖写入同样不残留
        let updated = EnvironmentMarker(environment: .lab, createdAt: 2, createdBy: "test+2")
        try EnvironmentMarkerStore.writeAtomically(updated, to: url)
        XCTAssertEqual(listing(root), [EnvironmentMarkerStore.fileName])
        XCTAssertEqual(try EnvironmentMarkerStore.read(from: url), updated)
    }

    func testWriteAtomicallyCreatesValidJSON() throws {
        let root = try makeTempRoot()
        let url = EnvironmentMarkerStore.markerURL(root: root)
        try EnvironmentMarkerStore.writeAtomically(
            EnvironmentMarker(environment: .production, createdAt: 0, createdBy: "test"),
            to: url
        )
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(json?["environment"] as? String, "production")
        XCTAssertEqual((json?["schema"] as? NSNumber)?.intValue, 1)
    }

    // MARK: - E11 无标记但已有数据 → 拒绝，且不写标记

    func testE11_MarkerMissingRefusesToStart() throws {
        let root = try makeTempRoot()
        let db = root.appendingPathComponent("dafeiyu.sqlite")
        try Data("legacy".utf8).write(to: db)

        XCTAssertThrowsError(try EnvironmentMarkerStore.verifyOrCreate(
            root: root, expected: .lab, createdBy: "test", now: 0
        )) { error in
            XCTAssertEqual(error as? EnvironmentMarkerError, .missing(root.path))
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: EnvironmentMarkerStore.markerURL(root: root).path),
            "缺失标记时不得自动补写"
        )
        XCTAssertEqual(listing(root), ["dafeiyu.sqlite"])
    }

    // MARK: - E12 标记环境不一致 → 拒绝，且内容不被改写

    func testE12_MarkerMismatchRefusesToStart() throws {
        let root = try makeTempRoot()
        let url = EnvironmentMarkerStore.markerURL(root: root)
        try EnvironmentMarkerStore.writeAtomically(
            EnvironmentMarker(environment: .production, createdAt: 5, createdBy: "test"),
            to: url
        )
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try EnvironmentMarkerStore.verifyOrCreate(
            root: root, expected: .lab, createdBy: "test", now: 9
        )) { error in
            XCTAssertEqual(error as? EnvironmentMarkerError,
                           .mismatched(expected: .lab, found: .production))
        }

        XCTAssertEqual(try Data(contentsOf: url), before, "拒绝启动时不得改写标记")
    }

    // MARK: - E18 标记损坏 → 拒绝

    func testE18_CorruptedMarkerRefusesToStart() throws {
        let root = try makeTempRoot()
        let url = EnvironmentMarkerStore.markerURL(root: root)
        try Data("not a json".utf8).write(to: url)

        XCTAssertThrowsError(try EnvironmentMarkerStore.verifyOrCreate(
            root: root, expected: .lab, createdBy: "test", now: 0
        )) { error in
            XCTAssertEqual(error as? EnvironmentMarkerError, .corrupted(url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("not a json".utf8))
    }

    func testUnknownEnvironmentValueIsCorrupted() throws {
        let root = try makeTempRoot()
        let url = EnvironmentMarkerStore.markerURL(root: root)
        try Data(#"{"schema":1,"environment":"dev","createdAt":0,"createdBy":"x"}"#.utf8).write(to: url)
        XCTAssertThrowsError(try EnvironmentMarkerStore.read(from: url)) { error in
            XCTAssertEqual(error as? EnvironmentMarkerError, .corrupted(url.path))
        }
    }

    // MARK: - E13 校验失败不产生任何写入

    func testE13_FailedValidationCreatesNothing() throws {
        let root = try makeTempRoot()
        let url = EnvironmentMarkerStore.markerURL(root: root)
        try EnvironmentMarkerStore.writeAtomically(
            EnvironmentMarker(environment: .production, createdAt: 1, createdBy: "test"),
            to: url
        )
        let snapshot = try listing(root).map { name -> String in
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            return "\(name)#\(data.count)#\(data.hashValue)"
        }

        XCTAssertThrowsError(try EnvironmentMarkerStore.verifyOrCreate(
            root: root, expected: .lab, createdBy: "test", now: 2
        ))

        let after = try listing(root).map { name -> String in
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            return "\(name)#\(data.count)#\(data.hashValue)"
        }
        XCTAssertEqual(after, snapshot, "校验失败后目录内容必须完全不变")
    }

    // MARK: - F1 正常主路径：标记一致 + 已有数据库 → 通过且不改写

    func testF1_MarkerMatchesAllowsExistingData() throws {
        let root = try makeTempRoot()
        let url = EnvironmentMarkerStore.markerURL(root: root)
        let db = root.appendingPathComponent("dafeiyu.sqlite")
        try EnvironmentMarkerStore.writeAtomically(
            EnvironmentMarker(environment: .lab, createdAt: 7, createdBy: "test+7"),
            to: url
        )
        try Data("existing-db".utf8).write(to: db)

        let markerBytes = try Data(contentsOf: url)
        let dbBytes = try Data(contentsOf: db)

        let marker = try EnvironmentMarkerStore.verifyOrCreate(
            root: root, expected: .lab, createdBy: "other+9", now: 99
        )

        XCTAssertEqual(marker.environment, .lab)
        XCTAssertEqual(marker.createdAt, 7, "已存在的标记不得被覆盖")
        XCTAssertEqual(marker.createdBy, "test+7")
        XCTAssertEqual(try Data(contentsOf: url), markerBytes, "标记内容必须原样保留")
        XCTAssertEqual(try Data(contentsOf: db), dbBytes, "数据库内容不得被触碰")
        XCTAssertEqual(listing(root).count, 2)
    }

    // MARK: - F3 根路径是普通文件 → 明确拒绝，不当成空目录

    func testF3_RootPathIsRegularFileFails() throws {
        let base = try makeTempRoot()
        let root = base.appendingPathComponent("DaFeiYuLab", isDirectory: false)
        let original = Data("i-am-a-file".utf8)
        try original.write(to: root)

        XCTAssertThrowsError(try EnvironmentMarkerStore.verifyOrCreate(
            root: root, expected: .lab, createdBy: "test", now: 0
        )) { error in
            XCTAssertEqual(error as? EnvironmentMarkerError, .notADirectory(root.path))
        }

        XCTAssertEqual(try Data(contentsOf: root), original, "普通文件不得被改写")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(EnvironmentMarkerStore.fileName).path)
        )
    }

    // MARK: - 空目录首次写入

    func testEmptyDirectoryGetsMarker() throws {
        let root = try makeTempRoot()
        let marker = try EnvironmentMarkerStore.verifyOrCreate(
            root: root, expected: .lab, createdBy: "test", now: 3
        )
        XCTAssertEqual(marker.environment, .lab)
        XCTAssertEqual(listing(root), [EnvironmentMarkerStore.fileName])
    }

    func testMissingDirectoryIsCreatedWithMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-new-\(UUID().uuidString)/DaFeiYuLab", isDirectory: true)
        let marker = try EnvironmentMarkerStore.verifyOrCreate(
            root: root, expected: .lab, createdBy: "test", now: 4
        )
        XCTAssertEqual(marker.environment, .lab)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: EnvironmentMarkerStore.markerURL(root: root).path
        ))
    }
}
