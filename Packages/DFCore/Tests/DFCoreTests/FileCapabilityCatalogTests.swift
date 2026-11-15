import XCTest
@testable import DFCore

/// D29：常见文件类型的保存 / 预览 / 读取 / 理解能力分级，不得夸大能力。
final class FileCapabilityCatalogTests: XCTestCase {

    func testImageSupportsOCRAndPreview() {
        let profile = FileCapabilityCatalog.profile(fileName: "photo.HEIC")
        XCTAssertEqual(profile.category, "image")
        XCTAssertTrue(profile.supports(.save))
        XCTAssertTrue(profile.supports(.preview))
        XCTAssertTrue(profile.supports(.readText))
        XCTAssertTrue(profile.supports(.understand))
    }

    func testAudioCanTranscribeButNotUnderstood() {
        let profile = FileCapabilityCatalog.profile(fileName: "voice.m4a")
        XCTAssertEqual(profile.category, "audio")
        XCTAssertTrue(profile.supports(.readText))
        XCTAssertFalse(profile.supports(.understand), "音频不应被声称可被模型直接理解")
    }

    func testVideoDoesNotClaimTextOrUnderstanding() {
        let profile = FileCapabilityCatalog.profile(fileName: "clip.mp4")
        XCTAssertEqual(profile.category, "video")
        XCTAssertTrue(profile.supports(.preview))
        XCTAssertFalse(profile.supports(.readText))
        XCTAssertFalse(profile.supports(.understand))
    }

    func testPlainTextCanBeReadAndUnderstood() {
        let profile = FileCapabilityCatalog.profile(fileName: "notes.md")
        XCTAssertEqual(profile.category, "text")
        XCTAssertTrue(profile.supports(.readText))
        XCTAssertTrue(profile.supports(.understand))
    }

    func testPDFOnlySaveAndPreview() {
        let profile = FileCapabilityCatalog.profile(fileName: "paper.pdf")
        XCTAssertEqual(profile.category, "pdf")
        XCTAssertTrue(profile.supports(.preview))
        XCTAssertFalse(profile.supports(.readText), "当前不提取 PDF 正文，不能声称可检索")
        XCTAssertFalse(profile.supports(.understand))
    }

    func testArchiveOnlySaved() {
        let profile = FileCapabilityCatalog.profile(fileName: "backup.zip")
        XCTAssertEqual(profile.category, "archive")
        XCTAssertEqual(profile.capabilities, [.save])
    }

    func testUnknownExtensionSavesOnly() {
        let profile = FileCapabilityCatalog.profile(fileName: "data.bin")
        XCTAssertEqual(profile.category, "other")
        XCTAssertEqual(profile.capabilities, [.save])
    }

    func testMimeFallbackWhenExtensionMissing() {
        let profile = FileCapabilityCatalog.profile(fileName: "upload", mime: "image/jpeg")
        XCTAssertEqual(profile.category, "image")

        let pdf = FileCapabilityCatalog.profile(fileName: "upload", mime: "application/pdf")
        XCTAssertEqual(pdf.category, "pdf")
    }

    func testSummaryListsOnlySupportedCapabilitiesInOrder() {
        let image = FileCapabilityCatalog.profile(fileName: "a.png")
        XCTAssertEqual(FileCapabilityCatalog.summary(image), "保存 · 预览 · 读取文字 · 模型理解")

        let archive = FileCapabilityCatalog.profile(fileName: "a.zip")
        XCTAssertEqual(FileCapabilityCatalog.summary(archive), "保存")
    }

    func testEveryProfileHasHonestNote() {
        for name in ["a.png", "b.m4a", "c.mp4", "d.txt", "e.pdf", "f.zip", "g.bin"] {
            XCTAssertFalse(FileCapabilityCatalog.profile(fileName: name).note.isEmpty)
        }
    }
}
