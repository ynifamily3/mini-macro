import Foundation

public struct SavedMacro: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var recording: MacroRecording
    public init(id: UUID = UUID(), name: String, recording: MacroRecording) {
        self.id = id; self.name = name; self.recording = recording
    }
}

public struct SearchRegion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 400, height: Double = 300) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct ImageCondition: Codable, Equatable, Sendable {
    public var templatePNG: Data = Data()
    public var imageName = "이미지 없음"
    public var displayID: UInt32? = nil
    public var region: SearchRegion? = nil
    public var similarity = 0.9
    public var timeout: TimeInterval = 10
    public var pollInterval: TimeInterval = 0.5
    public var clickWhenFound = false
    public init() { }
}

public enum AutomationStepKind: String, Codable, CaseIterable, Sendable {
    case macro, wait, imageIf, finish
}

public struct AutomationStep: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: AutomationStepKind
    public var macroID: UUID? = nil
    public var repetitions = 1
    public var waitSeconds: TimeInterval = 1
    public var condition = ImageCondition()
    public var thenSteps: [AutomationStep] = []
    public var elseSteps: [AutomationStep] = []
    public init(id: UUID = UUID(), kind: AutomationStepKind) { self.id = id; self.kind = kind }
}

public struct AutomationWorkflow: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var repetitions = 1
    public var steps: [AutomationStep] = []
    public var graph: AutomationGraph? = nil
    public init(id: UUID = UUID(), name: String = "새 자동화") { self.id = id; self.name = name }

    private enum CodingKeys: String, CodingKey { case id, name, repetitions, steps, graph }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        repetitions = try values.decode(Int.self, forKey: .repetitions)
        steps = try values.decodeIfPresent([AutomationStep].self, forKey: .steps) ?? []
        graph = try values.decodeIfPresent(AutomationGraph.self, forKey: .graph)
    }

    public var referencedMacroIDs: Set<UUID> {
        if let graph { return graph.referencedMacroIDs }
        func collect(_ steps: [AutomationStep]) -> Set<UUID> {
            var result = Set<UUID>()
            for step in steps {
                if step.kind == .macro, let id = step.macroID { result.insert(id) }
                if step.kind == .imageIf { result.formUnion(collect(step.thenSteps)); result.formUnion(collect(step.elseSteps)) }
            }
            return result
        }
        return collect(steps)
    }

    public var usesImages: Bool {
        if let graph { return graph.usesImages }
        func contains(_ steps: [AutomationStep]) -> Bool {
            steps.contains { $0.kind == .imageIf }
        }
        return contains(steps)
    }

    public func validated(availableMacros: Set<UUID>) throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...9_999).contains(repetitions), graph != nil || !steps.isEmpty else {
            throw AutomationError.invalid("자동화 이름과 실행할 단계를 입력해주세요.")
        }
        if let graph { _ = try graph.validated(availableMacros: availableMacros); return self }
        var ids = Set<UUID>()
        var count = 0
        func validate(_ steps: [AutomationStep], depth: Int) throws {
            guard depth <= 8 else { throw AutomationError.invalid("IF 중첩은 최대 8단계까지 지원합니다.") }
            for step in steps {
                count += 1
                guard count <= 1_000, ids.insert(step.id).inserted else {
                    throw AutomationError.invalid("단계가 너무 많거나 중복된 단계가 있습니다.")
                }
                switch step.kind {
                case .macro:
                    guard let id = step.macroID, availableMacros.contains(id) else {
                        throw AutomationError.invalid("선택하지 않았거나 보관함에 없는 매크로가 있습니다.")
                    }
                    guard (1...9_999).contains(step.repetitions) else { throw AutomationError.invalid("매크로 반복 횟수는 1~9,999회입니다.") }
                case .wait:
                    guard step.waitSeconds.isFinite, (0...3_600).contains(step.waitSeconds) else {
                        throw AutomationError.invalid("대기 시간은 0~3,600초입니다.")
                    }
                case .imageIf:
                    let c = step.condition
                    guard !c.templatePNG.isEmpty, c.templatePNG.count <= 10_000_000,
                          c.similarity.isFinite, (0.5...1).contains(c.similarity),
                          c.timeout.isFinite, (0...300).contains(c.timeout),
                          c.pollInterval.isFinite, (0.2...5).contains(c.pollInterval) else {
                        throw AutomationError.invalid("IF 이미지와 유사도·대기 시간 설정을 확인해주세요.")
                    }
                    if let r = c.region {
                        guard [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite),
                              abs(r.x) <= 100_000, abs(r.y) <= 100_000,
                              (1...100_000).contains(r.width), (1...100_000).contains(r.height) else {
                            throw AutomationError.invalid("이미지 검색 영역이 올바르지 않습니다.")
                        }
                    }
                    try validate(step.thenSteps, depth: depth + 1)
                    try validate(step.elseSteps, depth: depth + 1)
                case .finish: break
                }
            }
        }
        try validate(steps, depth: 0)
        return self
    }
}

public enum AutomationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public struct ImageMatch: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var score: Double
    public init(x: Double, y: Double, width: Double, height: Double, score: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.score = score
    }
}

/// The executor owns control flow only. Input posting and screen capture are injected,
/// so branch selection, cancellation, and errors can be verified without operating a Mac.
@MainActor
public struct AutomationExecutor {
    public var play: (UUID, Int) async throws -> Void
    public var detect: (ImageCondition) async throws -> ImageMatch?
    public var click: (ImageMatch) async throws -> Void
    public var report: (String, Int) -> Void
    public var onNode: (UUID, Int) -> Void
    public var onEdge: (UUID) -> Void

    public init(play: @escaping (UUID, Int) async throws -> Void,
                detect: @escaping (ImageCondition) async throws -> ImageMatch?,
                click: @escaping (ImageMatch) async throws -> Void,
                report: @escaping (String, Int) -> Void = { _, _ in },
                onNode: @escaping (UUID, Int) -> Void = { _, _ in },
                onEdge: @escaping (UUID) -> Void = { _ in }) {
        self.play = play; self.detect = detect; self.click = click; self.report = report
        self.onNode = onNode; self.onEdge = onEdge
    }

    public func run(_ workflow: AutomationWorkflow, availableMacros: Set<UUID>) async throws {
        _ = try workflow.validated(availableMacros: availableMacros)
        for iteration in 1...workflow.repetitions {
            if let graph = workflow.graph {
                if try await !executeGraph(graph, iteration: iteration) { return }
            } else if try await !execute(workflow.steps, iteration: iteration) { return }
        }
    }

    private func executeGraph(_ graph: AutomationGraph, iteration: Int) async throws -> Bool {
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        var current = graph.nodes.first(where: { $0.kind == .start })!.id
        while true {
            try Task.checkCancellation()
            let node = nodes[current]!
            onNode(node.id, iteration)
            var outlet = GraphOutlet.next
            switch node.kind {
            case .start: report("시작 · \(iteration)회차", iteration)
            case .macro:
                report("매크로 \(node.step.repetitions)회 실행", iteration)
                try await play(node.step.macroID!, node.step.repetitions)
            case .wait:
                report("\(node.step.waitSeconds.formatted())초 대기", iteration)
                try await Task.sleep(for: .seconds(node.step.waitSeconds))
            case .imageIf:
                report("IF · \(node.step.condition.imageName) 검색 중", iteration)
                let match = try await detect(node.step.condition)
                try Task.checkCancellation()
                if let match {
                    report("IF 발견 · 참 경로 실행", iteration)
                    if node.step.condition.clickWhenFound { try await click(match) }
                    outlet = .found
                } else { report("IF 시간 초과 · 거짓 경로 실행", iteration); outlet = .notFound }
            case .end: report("\(iteration)회차 종료", iteration); return true
            case .finish: report("전체 자동화 종료", iteration); return false
            }
            try Task.checkCancellation()
            guard let edge = graph.edges.first(where: { $0.source == current && $0.outlet == outlet }) else {
                throw AutomationError.invalid("실행할 다음 노드가 연결되어 있지 않습니다.")
            }
            onEdge(edge.id)
            current = edge.target
            await Task.yield()
        }
    }

    private func execute(_ steps: [AutomationStep], iteration: Int) async throws -> Bool {
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            switch step.kind {
            case .macro:
                report("단계 \(index + 1) · 매크로 \(step.repetitions)회 실행", iteration)
                try await play(step.macroID!, step.repetitions)
            case .wait:
                report("\(step.waitSeconds.formatted())초 대기", iteration)
                try await Task.sleep(for: .seconds(step.waitSeconds))
            case .imageIf:
                report("IF · \(step.condition.imageName) 검색 중", iteration)
                let result = try await detect(step.condition)
                try Task.checkCancellation()
                if let match = result {
                    report("IF 발견 · 참 경로 실행", iteration)
                    if step.condition.clickWhenFound { try await click(match) }
                    if try await !execute(step.thenSteps, iteration: iteration) { return false }
                } else {
                    report("IF 시간 초과 · 거짓 경로 실행", iteration)
                    if try await !execute(step.elseSteps, iteration: iteration) { return false }
                }
            case .finish:
                report("자동화 종료 단계", iteration)
                return false
            }
        }
        try Task.checkCancellation()
        return true
    }
}
