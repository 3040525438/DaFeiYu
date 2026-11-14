import XCTest
@testable import DFCore

/// W9：备份容器与加密抽象、快照编码（真实 AES-GCM 需真机验收）
final class BackupCryptoTests: XCTestCase {
    /// Linux 无 CryptoKit 时的确定性替身：XOR 流 + SHA256 截断标签。
    /// 只验证容器编排与错误路径，不代表生产算法。
    private struct TestCipher: BackupCipher {
        let identifier = "test-xor"

        func seal(_ plaintext: Data, key: Data, nonce: Data) throws -> Data {
            try BackupContainer.validateKey(key)
            let stream = [UInt8](key + nonce)
            var output = Data()
            for (index, byte) in plaintext.enumerated() {
                output.append(byte ^ stream[index % stream.count])
            }
            let digest = tagBytes(for: plaintext, key: key, nonce: nonce)
            output.append(contentsOf: digest)
            return output
        }

        func open(_ sealed: Data, key: Data, nonce: Data) throws -> Data {
            try BackupContainer.validateKey(key)
            guard sealed.count > 16 else { throw BackupCipherError.truncatedContainer }
            let ciphertext = sealed.prefix(sealed.count - 16)
            let tag = [UInt8](sealed.suffix(16))
            let stream = [UInt8](key + nonce)
            var output = Data()
            for (index, byte) in ciphertext.enumerated() {
                output.append(byte ^ stream[index % stream.count])
            }
            guard tag == tagBytes(for: output, key: key, nonce: nonce) else {
                throw BackupCipherError.authenticationFailed
            }
            return output
        }

        private func tagBytes(for plaintext: Data, key: Data, nonce: Data) -> [UInt8] {
            Array(SHA256.hash(key + nonce + plaintext).utf8.prefix(16))
        }
    }

    private let key = Data((0..<32).map { UInt8($0) })

    func testContainerRoundTrip() throws {
        let plaintext = Data("她说她喜欢桂花味的一切".utf8)
        let container = try BackupContainer.seal(plaintext, key: key, cipher: TestCipher())
        XCTAssertEqual(Array(container.prefix(5)), BackupContainer.magic)
        XCTAssertEqual(container[5], BackupContainer.version)
        XCTAssertEqual(container.count, BackupContainer.headerLength + plaintext.count + 16)

        let opened = try BackupContainer.open(container, key: key, cipher: TestCipher())
        XCTAssertEqual(opened, plaintext)
    }

    func testWrongKeyFailsAuthentication() throws {
        let container = try BackupContainer.seal(Data("秘密".utf8), key: key, cipher: TestCipher())
        let wrongKey = Data(repeating: 7, count: 32)
        XCTAssertThrowsError(try BackupContainer.open(container, key: wrongKey, cipher: TestCipher())) { error in
            XCTAssertEqual(error as? BackupCipherError, .authenticationFailed)
        }
    }

    func testBadMagicAndTruncation() throws {
        let container = try BackupContainer.seal(Data("秘密".utf8), key: key, cipher: TestCipher())

        var tampered = container
        tampered[0] = 0x00
        XCTAssertThrowsError(try BackupContainer.open(tampered, key: key, cipher: TestCipher())) { error in
            XCTAssertEqual(error as? BackupCipherError, .badMagic)
        }

        XCTAssertThrowsError(try BackupContainer.open(Data([0x44]), key: key, cipher: TestCipher())) { error in
            XCTAssertEqual(error as? BackupCipherError, .truncatedContainer)
        }
    }

    func testInvalidKeyLength() {
        XCTAssertThrowsError(try BackupContainer.seal(Data(), key: Data([1, 2, 3]), cipher: TestCipher())) { error in
            XCTAssertEqual(error as? BackupCipherError, .invalidKeyLength(3))
        }
    }

    func testDeterministicNonceProducesSameContainer() throws {
        let nonce = Data(repeating: 9, count: BackupContainer.nonceLength)
        let first = try BackupContainer.seal(Data("abc".utf8), key: key, cipher: TestCipher(), nonce: nonce)
        let second = try BackupContainer.seal(Data("abc".utf8), key: key, cipher: TestCipher(), nonce: nonce)
        XCTAssertEqual(first, second)
    }

    func testSnapshotCodableRoundTrip() throws {
        let snapshot = BackupSnapshot(
            schemaVersion: "v11_local_models",
            appVersion: "0.1.0",
            createdAt: 1_000,
            tables: [
                BackupTableSnapshot(
                    name: "memories",
                    columns: ["id", "content", "salience"],
                    rows: [
                        [.text("m1"), .text("喜欢桂花"), .real(0.8)],
                        [.text("m2"), .null, .integer(1)]
                    ]
                )
            ],
            counts: ["memories": 2]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BackupSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.totalRows, 2)
    }

    func testPrivacyPasscodeHashIsSaltedAndStable() {
        let first = PrivacyGate.hashPasscode("123456")
        let second = PrivacyGate.hashPasscode("123456")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, PrivacyGate.hashPasscode("123457"))
        XCTAssertNotEqual(first, SHA256.hash("123456"), "必须加盐，不能是裸哈希")

        let settings = PrivacySettings(lockEnabled: true, passcodeHash: first)
        XCTAssertTrue(PrivacyGate.verify(passcode: "123456", settings: settings))
        XCTAssertFalse(PrivacyGate.verify(passcode: "000000", settings: settings))
    }

    func testDeletionPlanWarnings() {
        XCTAssertEqual(DataDeletionPlan.confirmationPhrase, "彻底删除全部数据")
        XCTAssertTrue(DataDeletionPlan.keyLossWarningText.contains("无法再解密"))
    }
}
