import XCTest
@testable import DFCore

/// D53：错误归类与建议（原因、建议、可重试、是否需用户操作）。
final class ErrorDiagnosisTests: XCTestCase {
    // MARK: - 归类

    func testClassificationOfCommonFailures() {
        let cases: [(String, ErrorCategory)] = [
            ("尚未配置 API Key", .missingAPIKey),
            ("HTTP 401 Unauthorized", .authentication),
            ("403 forbidden", .authentication),
            ("429 Too Many Requests", .rateLimited),
            ("insufficient_quota: your balance is low", .quotaExceeded),
            ("The request timed out.", .timeout),
            ("The Internet connection appears to be offline.", .offline),
            ("404 model not found", .modelNotFound),
            ("maximum context length exceeded", .contextTooLong),
            ("400 Bad Request", .invalidRequest),
            ("502 bad gateway", .serverError),
            ("本次请求会超出预算上限", .budgetExceeded),
            ("数据库当前不可写入（只读模式）", .databaseReadOnly),
            ("可用存储空间不足", .storageFull),
            ("备份文件校验未通过", .backupCorrupted),
            ("数据库升级未完成", .migrationFailed),
            ("permission denied", .permissionDenied)
        ]
        for (message, expected) in cases {
            XCTAssertEqual(
                ErrorDiagnoser.diagnose(message).category,
                expected,
                "「\(message)」应归类为 \(expected)"
            )
        }
    }

    func testUnknownMessageFallsBackToUnknown() {
        let diagnosis = ErrorDiagnoser.diagnose("something odd happened")
        XCTAssertEqual(diagnosis.category, .unknown)
        XCTAssertTrue(diagnosis.isRetryable)
    }

    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(ErrorDiagnoser.diagnose("RATE LIMIT exceeded").category, .rateLimited)
        XCTAssertEqual(ErrorDiagnoser.diagnose("Timed Out").category, .timeout)
    }

    // MARK: - 结论完整性

    func testEveryCategoryHasCauseAndSuggestion() {
        for category in ErrorCategory.allCases {
            let diagnosis = ErrorDiagnoser.diagnosis(category)
            XCTAssertFalse(diagnosis.cause.isEmpty, "\(category) 缺原因")
            XCTAssertFalse(diagnosis.suggestions.isEmpty, "\(category) 缺建议")
            XCTAssertTrue(diagnosis.suggestions.allSatisfy { !$0.isEmpty })
            XCTAssertFalse(diagnosis.headline.isEmpty)
        }
    }

    func testRetryableFlagsAreSensible() {
        XCTAssertTrue(ErrorDiagnoser.diagnosis(.timeout).isRetryable)
        XCTAssertTrue(ErrorDiagnoser.diagnosis(.rateLimited).isRetryable)
        XCTAssertTrue(ErrorDiagnoser.diagnosis(.serverError).isRetryable)
        XCTAssertTrue(ErrorDiagnoser.diagnosis(.offline).isRetryable)
        XCTAssertTrue(ErrorDiagnoser.diagnosis(.migrationFailed).isRetryable)

        XCTAssertFalse(ErrorDiagnoser.diagnosis(.missingAPIKey).isRetryable)
        XCTAssertFalse(ErrorDiagnoser.diagnosis(.authentication).isRetryable)
        XCTAssertFalse(ErrorDiagnoser.diagnosis(.budgetExceeded).isRetryable)
        XCTAssertFalse(ErrorDiagnoser.diagnosis(.backupCorrupted).isRetryable)
    }

    func testUserActionFlagsAreSensible() {
        XCTAssertTrue(ErrorDiagnoser.diagnosis(.missingAPIKey).needsUserAction)
        XCTAssertTrue(ErrorDiagnoser.diagnosis(.modelNotFound).needsUserAction)
        XCTAssertTrue(ErrorDiagnoser.diagnosis(.databaseReadOnly).needsUserAction)
        XCTAssertFalse(ErrorDiagnoser.diagnosis(.timeout).needsUserAction)
        XCTAssertFalse(ErrorDiagnoser.diagnosis(.serverError).needsUserAction)
    }

    func testDiagnosisDoesNotEchoRawMessage() {
        let raw = "HTTP 401 Unauthorized: key sk-secret-123 is invalid"
        let diagnosis = ErrorDiagnoser.diagnose(raw)
        XCTAssertFalse(diagnosis.cause.contains("sk-secret-123"))
        XCTAssertFalse(diagnosis.headline.contains("sk-secret-123"))
    }

    func testEmptySuggestionsFallBackToDefault() {
        let diagnosis = ErrorDiagnosis(
            category: .unknown,
            cause: "x",
            suggestions: [],
            isRetryable: true,
            needsUserAction: false
        )
        XCTAssertEqual(diagnosis.suggestions.count, 1)
        XCTAssertTrue(diagnosis.suggestions[0].contains("诊断"))
    }
}
