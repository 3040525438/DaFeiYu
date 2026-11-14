import XCTest
@testable import DFCore

/// 环境身份解析与校验（E01–E10、E14、E15、E17、E19、E20）
final class EnvironmentIdentityTests: XCTestCase {

    private let prodID = "com.dafeiyu.app"
    private let labID = "com.dafeiyu.lab"

    private func info(_ value: String) -> [String: Any] {
        ["DFEnvironment": value]
    }

    private func tempRoot(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - E01 / E02 正常路径

    func testE01_ProductionResolves() throws {
        let identity = try EnvironmentIdentity.resolve(info: info("production"), actualBundleID: prodID)
        XCTAssertEqual(identity.environment, .production)
        XCTAssertNil(identity.signatureSuffix)
        XCTAssertEqual(identity.environment.dataDirectoryName, "DaFeiYu")
        XCTAssertEqual(identity.environment.keychainService, "com.dafeiyu.app.keys")

        let root = tempRoot(named: "DaFeiYu")
        let db = root.appendingPathComponent("dafeiyu.sqlite")
        XCTAssertNoThrow(try identity.validate(root: root, databaseURL: db,
                                               keychainService: identity.environment.keychainService))
    }

    func testE02_LabResolves() throws {
        let identity = try EnvironmentIdentity.resolve(info: info("lab"), actualBundleID: labID)
        XCTAssertEqual(identity.environment, .lab)
        XCTAssertNil(identity.signatureSuffix)
        XCTAssertEqual(identity.environment.dataDirectoryName, "DaFeiYuLab")
        XCTAssertEqual(identity.environment.keychainService, "com.dafeiyu.lab.keys")

        let root = tempRoot(named: "DaFeiYuLab")
        let db = root.appendingPathComponent("dafeiyu.sqlite")
        XCTAssertNoThrow(try identity.validate(root: root, databaseURL: db,
                                               keychainService: identity.environment.keychainService))
    }

    // MARK: - E03 / E19 签名追加后缀

    func testE03_SignatureSuffixAllowed() throws {
        let identity = try EnvironmentIdentity.resolve(
            info: info("lab"),
            actualBundleID: "com.dafeiyu.lab.424HCPR7NT"
        )
        XCTAssertEqual(identity.environment, .lab, "环境仍由 DFEnvironment 决定")
        XCTAssertEqual(identity.signatureSuffix, "424HCPR7NT")
        XCTAssertEqual(identity.environment.dataDirectoryName, "DaFeiYuLab")
    }

    func testE19_ProductionSuffixAllowed() throws {
        let identity = try EnvironmentIdentity.resolve(
            info: info("production"),
            actualBundleID: "com.dafeiyu.app.ABCD1234"
        )
        XCTAssertEqual(identity.environment, .production)
        XCTAssertEqual(identity.signatureSuffix, "ABCD1234")
        XCTAssertEqual(identity.environment.dataDirectoryName, "DaFeiYu")
    }

    // MARK: - E04 / E05 配置缺失与非法

    func testE04_MissingConfigFailsClosed() {
        XCTAssertThrowsError(try EnvironmentIdentity.resolve(info: [:], actualBundleID: prodID)) { error in
            XCTAssertEqual(error as? EnvironmentValidationError, .configMissing)
        }
    }

    func testE05_InvalidConfig() {
        XCTAssertThrowsError(try EnvironmentIdentity.resolve(info: info("dev"), actualBundleID: prodID)) { error in
            XCTAssertEqual(error as? EnvironmentValidationError, .configInvalid("dev"))
        }
    }

    // MARK: - E06 / E07 Bundle ID 不匹配或缺失

    func testE06_ConfigBundleMismatch() {
        XCTAssertThrowsError(try EnvironmentIdentity.resolve(info: info("lab"), actualBundleID: prodID)) { error in
            XCTAssertEqual(error as? EnvironmentValidationError,
                           .bundleIDMismatch(expected: labID, actual: prodID))
        }
        XCTAssertThrowsError(try EnvironmentIdentity.resolve(info: info("production"), actualBundleID: labID)) { error in
            XCTAssertEqual(error as? EnvironmentValidationError,
                           .bundleIDMismatch(expected: prodID, actual: labID))
        }
    }

    func testE07_MissingBundleID() {
        XCTAssertThrowsError(try EnvironmentIdentity.resolve(info: info("production"), actualBundleID: nil)) { error in
            XCTAssertEqual(error as? EnvironmentValidationError, .bundleIDMissing)
        }
        XCTAssertThrowsError(try EnvironmentIdentity.resolve(info: info("production"), actualBundleID: "")) { error in
            XCTAssertEqual(error as? EnvironmentValidationError, .bundleIDMissing)
        }
    }

    // MARK: - E08 / E14 / E20 目录校验

    func testE08_DataDirectoryMismatch() throws {
        let identity = try EnvironmentIdentity.resolve(info: info("lab"), actualBundleID: labID)
        let wrongRoot = tempRoot(named: "DaFeiYu")
        let db = wrongRoot.appendingPathComponent("dafeiyu.sqlite")
        XCTAssertThrowsError(try identity.validate(root: wrongRoot, databaseURL: db,
                                                   keychainService: identity.environment.keychainService)) { error in
            XCTAssertEqual(error as? EnvironmentValidationError,
                           .dataDirectoryMismatch(expected: "DaFeiYuLab", actual: "DaFeiYu"))
        }
    }

    func testE14_ProductionDirWithLabIdentity() throws {
        let identity = try EnvironmentIdentity.resolve(info: info("lab"), actualBundleID: labID)
        let prodRoot = tempRoot(named: "DaFeiYu")
        let db = prodRoot.appendingPathComponent("dafeiyu.sqlite")
        XCTAssertThrowsError(try identity.validate(root: prodRoot, databaseURL: db,
                                                   keychainService: identity.environment.keychainService))
    }

    func testE20_UnknownRootRejected() throws {
        let identity = try EnvironmentIdentity.resolve(info: info("lab"), actualBundleID: labID)
        let unknown = tempRoot(named: "DaFeiYu2")
        let db = unknown.appendingPathComponent("dafeiyu.sqlite")
        XCTAssertThrowsError(try identity.validate(root: unknown, databaseURL: db,
                                                   keychainService: identity.environment.keychainService)) { error in
            XCTAssertEqual(error as? EnvironmentValidationError,
                           .dataDirectoryMismatch(expected: "DaFeiYuLab", actual: "DaFeiYu2"))
        }
    }

    // MARK: - E09 Keychain 冲突

    func testE09_KeychainServiceMismatch() throws {
        let identity = try EnvironmentIdentity.resolve(info: info("lab"), actualBundleID: labID)
        let root = tempRoot(named: "DaFeiYuLab")
        let db = root.appendingPathComponent("dafeiyu.sqlite")
        XCTAssertThrowsError(try identity.validate(root: root, databaseURL: db,
                                                   keychainService: "com.dafeiyu.app.keys")) { error in
            XCTAssertEqual(error as? EnvironmentValidationError,
                           .keychainServiceMismatch(expected: "com.dafeiyu.lab.keys",
                                                    actual: "com.dafeiyu.app.keys"))
        }
    }

    // MARK: - E10 两环境目录互斥

    func testE10_DirectoriesAreDisjoint() throws {
        let prod = try EnvironmentIdentity.resolve(info: info("production"), actualBundleID: prodID)
        let lab = try EnvironmentIdentity.resolve(info: info("lab"), actualBundleID: labID)

        XCTAssertNotEqual(prod.environment.dataDirectoryName, lab.environment.dataDirectoryName)
        XCTAssertFalse(prod.environment.dataDirectoryName.hasPrefix(lab.environment.dataDirectoryName + "/"))
        XCTAssertFalse(lab.environment.dataDirectoryName.hasPrefix(prod.environment.dataDirectoryName + "/"))

        let prodDB = URL(fileURLWithPath: "/tmp/DaFeiYu/dafeiyu.sqlite")
        let labDB = URL(fileURLWithPath: "/tmp/DaFeiYuLab/dafeiyu.sqlite")
        XCTAssertNotEqual(prodDB, labDB)
        XCTAssertFalse(prodDB.path.hasPrefix("/tmp/DaFeiYuLab/"))
        XCTAssertFalse(labDB.path.hasPrefix("/tmp/DaFeiYu/"))
        XCTAssertNotEqual(prod.environment.keychainService, lab.environment.keychainService)
    }

    // MARK: - E15 实验版绝不使用正式版 Keychain service

    func testE15_LabNeverUsesProductionService() {
        XCTAssertEqual(EnvironmentID.lab.keychainService, "com.dafeiyu.lab.keys")
        XCTAssertNotEqual(EnvironmentID.lab.keychainService, EnvironmentID.production.keychainService)
    }

    // MARK: - E17 后缀形态非法

    func testE17_InvalidSignatureSuffix() {
        let cases = [
            "com.dafeiyu.lab.",       // 空后缀
            "com.dafeiyu.lab.a b",    // 含空白
            "com.dafeiyu.lab.a/b"     // 含斜杠
        ]
        for bundleID in cases {
            XCTAssertThrowsError(try EnvironmentIdentity.resolve(info: info("lab"), actualBundleID: bundleID),
                                 "应拒绝：\(bundleID)") { error in
                XCTAssertEqual(error as? EnvironmentValidationError,
                               .signatureSuffixInvalid(String(bundleID.dropFirst("com.dafeiyu.lab.".count))))
            }
        }
    }

    // MARK: - F2 签名后缀不放松任何校验

    func testF2_SignatureSuffixDoesNotRelaxValidation() throws {
        let plain = try EnvironmentIdentity.resolve(info: info("lab"), actualBundleID: labID)
        let signed = try EnvironmentIdentity.resolve(info: info("lab"),
                                                     actualBundleID: "com.dafeiyu.lab.424HCPR7NT")
        XCTAssertNotNil(signed.signatureSuffix)
        XCTAssertNil(plain.signatureSuffix)

        let wrongRoot = tempRoot(named: "DaFeiYu")
        let wrongDB = wrongRoot.appendingPathComponent("dafeiyu.sqlite")
        let goodRoot = tempRoot(named: "DaFeiYuLab")
        let goodDB = goodRoot.appendingPathComponent("dafeiyu.sqlite")

        // 目录不对：带后缀与不带后缀必须同样抛错
        XCTAssertThrowsError(try signed.validate(root: wrongRoot, databaseURL: wrongDB,
                                                 keychainService: "com.dafeiyu.lab.keys")) { error in
            XCTAssertEqual(error as? EnvironmentValidationError,
                           .dataDirectoryMismatch(expected: "DaFeiYuLab", actual: "DaFeiYu"))
        }
        XCTAssertThrowsError(try plain.validate(root: wrongRoot, databaseURL: wrongDB,
                                                keychainService: "com.dafeiyu.lab.keys"))

        // Keychain 不对：带后缀同样抛错，不退化为正式版 service
        XCTAssertThrowsError(try signed.validate(root: goodRoot, databaseURL: goodDB,
                                                 keychainService: "com.dafeiyu.app.keys")) { error in
            XCTAssertEqual(error as? EnvironmentValidationError,
                           .keychainServiceMismatch(expected: "com.dafeiyu.lab.keys",
                                                    actual: "com.dafeiyu.app.keys"))
        }

        // 库路径越界：带后缀同样抛错
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside.sqlite")
        XCTAssertThrowsError(try signed.validate(root: goodRoot, databaseURL: outside,
                                                 keychainService: "com.dafeiyu.lab.keys"))

        // 全部正确时才通过
        XCTAssertNoThrow(try signed.validate(root: goodRoot, databaseURL: goodDB,
                                             keychainService: "com.dafeiyu.lab.keys"))
    }

    // MARK: - F4 配置大小写与空白敏感

    func testF4_ConfigIsCaseAndWhitespaceSensitive() {
        for raw in ["Lab", "LAB", " lab", "lab ", "Production"] {
            XCTAssertThrowsError(try EnvironmentIdentity.resolve(info: info(raw), actualBundleID: labID),
                                 "应拒绝：\(raw)") { error in
                XCTAssertEqual(error as? EnvironmentValidationError, .configInvalid(raw))
            }
        }
    }

    // MARK: - 库路径必须位于根目录下

    func testDatabaseOutsideRootRejected() throws {
        let identity = try EnvironmentIdentity.resolve(info: info("lab"), actualBundleID: labID)
        let root = tempRoot(named: "DaFeiYuLab")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere.sqlite")
        XCTAssertThrowsError(try identity.validate(root: root, databaseURL: outside,
                                                   keychainService: identity.environment.keychainService)) { error in
            XCTAssertEqual(error as? EnvironmentValidationError, .databaseOutsideRoot(outside.path))
        }
    }
}
