import XCTest
@testable import DFCore

/// W8：七层记忆加工的纯逻辑（层级 / 三主体治理 / 抽取闸门 / 冲突 / 反思 / L7 工作记忆）
final class MemoryProcessingTests: XCTestCase {
    private let policy = MemoryExtractionPolicy.default

    private func candidate(
        title: String = "喜欢桂花",
        content: String = "用户喜欢桂花味的一切",
        evidence: String = "喜欢桂花味",
        scope: MemoryScope = .user,
        layer: MemoryLayer = .semantic,
        category: String = "preference",
        importance: Double = 0.5,
        needsConfirmation: Bool = false
    ) -> MemoryCandidate {
        MemoryCandidate(
            scope: scope,
            layer: layer,
            category: category,
            title: title,
            content: content,
            evidenceQuote: evidence,
            importance: importance,
            scopeNeedsConfirmation: needsConfirmation
        )
    }

    // MARK: - 层级

    func testLayerMetadata() {
        XCTAssertEqual(MemoryLayer.raw.level, 1)
        XCTAssertEqual(MemoryLayer.working.level, 7)
        XCTAssertEqual(MemoryLayer.semantic.displayName, "L3 语义记忆")
        XCTAssertFalse(MemoryLayer.raw.persistsInMemories)
        XCTAssertFalse(MemoryLayer.graph.persistsInMemories)
        XCTAssertFalse(MemoryLayer.working.persistsInMemories)
        XCTAssertTrue(MemoryLayer.reflective.persistsInMemories)
        XCTAssertEqual(MemoryLayer.semantic.retrievalWeight, 1.0)
        XCTAssertEqual(MemoryLayer.episodic.retrievalWeight, 0.90)
        // L1 原始经历只属于共同经历
        XCTAssertEqual(MemoryLayer.raw.allowedScopes, [.shared])
    }

    // MARK: - 三主体治理

    func testSubjectScopeResolution() {
        XCTAssertEqual(MemoryGovernance.resolveScope(subject: .user).scope, .user)
        XCTAssertFalse(MemoryGovernance.resolveScope(subject: .user).needsConfirmation)

        XCTAssertEqual(MemoryGovernance.resolveScope(subject: .both).scope, .shared)
        XCTAssertEqual(MemoryGovernance.resolveScope(subject: .aiSelf).scope, .selfScope)

        let unknown = MemoryGovernance.resolveScope(subject: .unknown)
        XCTAssertEqual(unknown.scope, .shared)
        XCTAssertTrue(unknown.needsConfirmation, "无法判断主语时必须标记待确认，禁止静默归类")
    }

    func testGovernanceRejectsInvalidCombination() {
        XCTAssertThrowsError(try MemoryGovernance.validate(scope: .user, layer: .raw))
        XCTAssertNoThrow(try MemoryGovernance.validate(scope: .selfScope, layer: .semantic))
        XCTAssertNoThrow(try MemoryGovernance.validate(scope: .user, layer: .reflective))
    }

    // MARK: - 抽取闸门

    func testScreenDropsFabricatedEvidence() {
        let source = "她说她最近喜欢上了桂花味的一切，还买了一瓶香水"
        let result = policy.screen(
            [
                candidate(evidence: "喜欢上了桂花味"),
                candidate(title: "讨厌桂花", content: "用户讨厌桂花", evidence: "我讨厌桂花")
            ],
            sourceText: source
        )
        XCTAssertEqual(result.accepted.count, 1)
        XCTAssertEqual(result.rejections.count, 1)
        XCTAssertEqual(result.rejections.first?.reason, .evidenceNotLocated)
    }

    func testScreenCapsCandidatesPerTurn() {
        let source = "今天聊了摄影、考试、杭州、桂花、猫、咖啡、跑步、电影、朋友和工作"
        let topics = ["摄影", "考试", "杭州", "桂花", "猫", "咖啡", "跑步", "电影", "朋友", "工作"]
        let candidates = topics.map { topic in
            candidate(
                title: topic,
                content: "用户今天提到了\(topic)",
                evidence: source,
                category: "topic"
            )
        }
        let result = policy.screen(candidates, sourceText: source)
        XCTAssertEqual(result.accepted.count, 8, "单轮最多 8 条")
        XCTAssertEqual(result.droppedByBudget, 2)
    }

    func testScreenDropsEmptyAndBatchDuplicates() {
        let source = "用户喜欢桂花味"
        let result = policy.screen(
            [
                candidate(content: "   "),
                candidate(),
                candidate(title: "重复", content: "用户喜欢桂花味的一切", evidence: "喜欢桂花味")
            ],
            sourceText: source
        )
        XCTAssertEqual(result.rejections.map(\.reason), [.emptyContent, .duplicateInBatch])
        XCTAssertEqual(result.accepted.count, 1)
    }

    func testScreenRespectsRemainingBudget() {
        let source = "用户喜欢桂花味"
        let result = policy.screen(
            [
                candidate(title: "a", content: "用户喜欢桂花味的一切"),
                candidate(title: "b", content: "用户买了桂花香水"),
                candidate(title: "c", content: "用户周末去了杭州")
            ],
            sourceText: source,
            remainingBudget: 2
        )
        XCTAssertEqual(result.accepted.count, 2)
        XCTAssertEqual(result.droppedByBudget, 1)
    }

    func testEvidenceLocateToleratesPunctuation() {
        XCTAssertTrue(policy.locate(quote: "喜欢 桂花！", in: "她说她喜欢桂花味的香水"))
        XCTAssertFalse(policy.locate(quote: "", in: "她说她喜欢桂花味的香水"))
        XCTAssertGreaterThan(policy.similarity("用户喜欢拍海边照片", "用户很喜欢拍摄海边照片"), 0.4)
        XCTAssertEqual(policy.similarity("完全不同", "毫无关系"), 0)
    }

    func testRouteRules() {
        XCTAssertEqual(policy.route(for: candidate(importance: 0.8)), .confirm, "高重要度必须确认")
        XCTAssertEqual(policy.route(for: candidate(category: "relationship", importance: 0.3)), .confirm)
        XCTAssertEqual(policy.route(for: candidate(importance: 0.3, needsConfirmation: true)), .confirm)
        XCTAssertEqual(policy.route(for: candidate(importance: 0.3)), .direct)
    }

    func testDedupeKeyStable() {
        let first = policy.normalizedDedupeKey(for: candidate(content: "用户喜欢桂花味的一切。"))
        let second = policy.normalizedDedupeKey(for: candidate(content: "用户喜欢桂花味的一切"))
        XCTAssertEqual(first, second, "去重键必须对空白/标点不敏感")
        XCTAssertTrue(first.hasPrefix("user|semantic|preference|"))
    }

    // MARK: - 冲突与合并

    func testConflictDetection() {
        let shared = MemoryFactSnapshot(id: "a", subject: "e1", attribute: "city", value: "杭州", validFrom: 100)
        let newer = MemoryFactSnapshot(id: "b", subject: "e1", attribute: "city", value: "上海", validFrom: 200)
        XCTAssertEqual(MemoryConflictDetector.conflict(between: shared, and: newer), .timeChange)

        let sameTime = MemoryFactSnapshot(id: "b", subject: "e1", attribute: "city", value: "上海", validFrom: 100)
        XCTAssertEqual(MemoryConflictDetector.conflict(between: shared, and: sameTime), .dispute)

        let sameValue = MemoryFactSnapshot(id: "b", subject: "e1", attribute: "city", value: "杭州", validFrom: 200)
        XCTAssertEqual(MemoryConflictDetector.conflict(between: shared, and: sameValue), .none)

        let otherAttribute = MemoryFactSnapshot(id: "b", subject: "e1", attribute: "job", value: "上海", validFrom: 200)
        XCTAssertEqual(MemoryConflictDetector.conflict(between: shared, and: otherAttribute), .none)
    }

    func testDuplicateGroupsKeepLongestAsSurvivor() {
        let items = [
            MemoryConsolidationItem(
                id: "a", scope: .user, layer: "semantic", category: "hobby",
                title: "摄影", content: "喜欢摄影", salience: 0.5,
                lastRecalledAt: nil, firstSeenAt: 0
            ),
            MemoryConsolidationItem(
                id: "b", scope: .user, layer: "semantic", category: "hobby",
                title: "摄影", content: "用户非常喜欢摄影，并且常去海边拍摄", salience: 0.8,
                lastRecalledAt: nil, firstSeenAt: 0
            ),
            MemoryConsolidationItem(
                id: "c", scope: .user, layer: "semantic", category: "event",
                title: "天气", content: "今天天气不错", salience: 0.5,
                lastRecalledAt: nil, firstSeenAt: 0
            )
        ]
        let groups = MemoryConsolidationPlanner.duplicateGroups(items, threshold: 0.9) { _, _ in 1.0 }
        XCTAssertEqual(groups.count, 1, "不同 category 不合并")
        XCTAssertEqual(groups.first?.first, "b", "信息量最大的一条作为幸存者")
        XCTAssertEqual(Set(groups.first ?? []), ["a", "b"])
    }

    func testArchiveRule() {
        let day: Int64 = 24 * 60 * 60 * 1000
        let now: Int64 = 1_000 * day
        let cold = MemoryConsolidationItem(
            id: "cold", scope: .user, layer: "semantic", category: "fact",
            title: "", content: "", salience: 0.2, lastRecalledAt: nil, firstSeenAt: now - 200 * day
        )
        XCTAssertTrue(MemoryConsolidationPlanner.shouldArchive(cold, now: now))

        let warm = MemoryConsolidationItem(
            id: "warm", scope: .user, layer: "semantic", category: "fact",
            title: "", content: "", salience: 0.8, lastRecalledAt: nil, firstSeenAt: now - 200 * day
        )
        XCTAssertFalse(MemoryConsolidationPlanner.shouldArchive(warm, now: now))

        let recalled = MemoryConsolidationItem(
            id: "recalled", scope: .user, layer: "semantic", category: "fact",
            title: "", content: "", salience: 0.2, lastRecalledAt: now - 10 * day, firstSeenAt: now - 200 * day
        )
        XCTAssertFalse(MemoryConsolidationPlanner.shouldArchive(recalled, now: now))
    }

    // MARK: - 反思

    func testReflectionValidationRequiresRealRefs() {
        let result = ReflectionPolicy.default.validate(
            [
                ReflectionConclusion(content: "我好像更喜欢晚上聊天", evidenceRefs: ["m1"], epistemicStatus: "inferred"),
                ReflectionConclusion(content: "没有引用", evidenceRefs: [], epistemicStatus: "inferred"),
                ReflectionConclusion(content: "引用了不存在的素材", evidenceRefs: ["m9"], epistemicStatus: "inferred"),
                ReflectionConclusion(content: "认识状态非法", evidenceRefs: ["m1"], epistemicStatus: "hallucinated")
            ],
            availableRefs: ["m1"]
        )
        XCTAssertEqual(result.accepted.count, 1)
        XCTAssertEqual(result.rejected.count, 3)
        XCTAssertEqual(result.accepted.first?.evidenceRefs, ["m1"])
    }

    // MARK: - L7 工作记忆

    func testWorkingMemoryAssemblyOrderAndDropped() {
        let items = [
            WorkingMemoryItem(id: "t1", kind: .recentTurn, text: "上一轮", estimatedTokens: 5),
            WorkingMemoryItem(id: "m1", kind: .retrievedMemory, text: "旧记忆", estimatedTokens: 100),
            WorkingMemoryItem(id: "p1", kind: .pinnedFact, text: "她今天生病", estimatedTokens: 5),
            WorkingMemoryItem(id: "u1", kind: .currentUserMessage, text: "在吗", estimatedTokens: 30)
        ]
        let package = WorkingMemoryAssembler.assemble(
            conversationID: "c1",
            items: items,
            budget: WorkingMemoryBudget(maxTokens: 45),
            at: 100
        )
        XCTAssertEqual(package.items.map(\.id), ["u1", "p1", "t1"], "按优先级装载，且预算内")
        XCTAssertEqual(package.estimatedTokens, 40)
        XCTAssertEqual(package.dropped.count, 1)
        XCTAssertTrue(package.dropped.contains { $0.id == "m1" && $0.reason == .budgetExceeded })
    }

    func testWorkingMemoryDropsDuplicateText() {
        let items = [
            WorkingMemoryItem(id: "a", kind: .pinnedFact, text: "她今天生病", estimatedTokens: 5),
            WorkingMemoryItem(id: "b", kind: .recentTurn, text: "她今天生病。", estimatedTokens: 5)
        ]
        let package = WorkingMemoryAssembler.assemble(
            conversationID: "c1",
            items: items,
            budget: .default,
            at: 1
        )
        XCTAssertEqual(package.items.map(\.id), ["a"])
        XCTAssertEqual(package.dropped.map(\.id), ["b"])
        XCTAssertEqual(package.dropped.first?.reason, .duplicate)
    }

    func testWorkingMemoryKeepsCurrentMessageEvenOverBudget() {
        let items = [
            WorkingMemoryItem(id: "u1", kind: .currentUserMessage, text: "很长的一段话", estimatedTokens: 500),
            WorkingMemoryItem(id: "p1", kind: .pinnedFact, text: "重要事实", estimatedTokens: 10)
        ]
        let package = WorkingMemoryAssembler.assemble(
            conversationID: "c1",
            items: items,
            budget: WorkingMemoryBudget(maxTokens: 100),
            at: 1
        )
        XCTAssertEqual(package.items.map(\.id), ["u1"], "当前用户消息永不被裁掉")
        XCTAssertEqual(package.dropped.map(\.id), ["p1"])
    }

    func testWorkingMemoryPackageCodableRoundTrip() throws {
        let package = WorkingMemoryAssembler.assemble(
            conversationID: "c1",
            items: [WorkingMemoryItem(id: "u1", kind: .currentUserMessage, text: "在吗", estimatedTokens: 3)],
            budget: .default,
            at: 100
        )
        let data = try JSONEncoder().encode(package)
        let decoded = try JSONDecoder().decode(WorkingMemoryPackage.self, from: data)
        XCTAssertEqual(decoded, package)
    }

    func testTokenEstimateIsPositive() {
        XCTAssertGreaterThan(WorkingMemoryAssembler.estimateTokens("你好，今天过得怎么样？"), 0)
        XCTAssertGreaterThan(WorkingMemoryAssembler.estimateTokens("hello world"), 0)
        XCTAssertEqual(WorkingMemoryAssembler.estimateTokens(""), 1)
    }
}
