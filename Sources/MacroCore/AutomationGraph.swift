import Foundation

public enum GraphNodeKind: String, Codable, CaseIterable, Sendable {
    case start, macro, wait, imageIf, end, finish
    public var stepKind: AutomationStepKind {
        switch self { case .macro: .macro; case .wait: .wait; case .imageIf: .imageIf; default: .finish }
    }
    public var outlets: [GraphOutlet] {
        switch self { case .imageIf: [.found, .notFound]; case .end, .finish: []; default: [.next] }
    }
}

public enum GraphOutlet: String, Codable, CaseIterable, Sendable { case next, found, notFound }

public struct GraphNode: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: GraphNodeKind
    public var title: String = ""
    public var x: Double
    public var y: Double
    public var step: AutomationStep
    public init(id: UUID = UUID(), kind: GraphNodeKind, x: Double = 80, y: Double = 240) {
        self.id = id; self.kind = kind; self.x = x; self.y = y
        step = AutomationStep(id: id, kind: kind.stepKind)
    }
}

public struct GraphEdge: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var source: UUID
    public var outlet: GraphOutlet
    public var target: UUID
    public init(id: UUID = UUID(), source: UUID, outlet: GraphOutlet, target: UUID) {
        self.id = id; self.source = source; self.outlet = outlet; self.target = target
    }
}

public struct GraphViewport: Codable, Equatable, Sendable {
    public var x: Double = 0
    public var y: Double = 0
    public var zoom: Double = 0.8
    public var initialized = false
    public init() { }

    public func screenPoint(_ world: CGPoint) -> CGPoint { CGPoint(x: world.x * zoom + x, y: world.y * zoom + y) }
    public func worldPoint(_ screen: CGPoint) -> CGPoint { CGPoint(x: (screen.x - x) / zoom, y: (screen.y - y) / zoom) }
    public func zoomed(by factor: Double, around anchor: CGPoint) -> Self {
        guard factor.isFinite, factor > 0 else { return self }
        let world = worldPoint(anchor)
        var result = self
        result.zoom = min(2, max(0.2, zoom * factor))
        result.x = min(1_000_000, max(-1_000_000, anchor.x - world.x * result.zoom))
        result.y = min(1_000_000, max(-1_000_000, anchor.y - world.y * result.zoom))
        result.initialized = true
        return result
    }
}

public struct AutomationGraph: Codable, Equatable, Sendable {
    public var version = 1
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]
    public var viewport = GraphViewport()
    public init(nodes: [GraphNode] = [], edges: [GraphEdge] = []) { self.nodes = nodes; self.edges = edges }

    public static func draft() -> Self {
        Self(nodes: [GraphNode(kind: .start, x: 80, y: 240), GraphNode(kind: .end, x: 700, y: 240)])
    }

    public var reachableIDs: Set<UUID> {
        guard let start = nodes.first(where: { $0.kind == .start }) else { return [] }
        var visited: Set<UUID> = [start.id], queue = [start.id], cursor = 0
        let outgoing = Dictionary(grouping: edges, by: \.source)
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for edge in outgoing[id] ?? [] where visited.insert(edge.target).inserted { queue.append(edge.target) }
        }
        return visited
    }

    public var referencedMacroIDs: Set<UUID> {
        Set(nodes.filter { $0.kind == .macro }.compactMap { $0.step.macroID })
    }
    public var usesImages: Bool { let reachable = reachableIDs; return nodes.contains { reachable.contains($0.id) && $0.kind == .imageIf } }

    public func validateStructure() throws {
        guard version == 1, nodes.count <= 1_002, edges.count <= 2_004,
              nodes.filter({ $0.kind == .start }).count == 1,
              Set(nodes.map(\.id)).count == nodes.count,
              Set(edges.map(\.id)).count == edges.count,
              viewport.x.isFinite, viewport.y.isFinite, abs(viewport.x) <= 1_000_000, abs(viewport.y) <= 1_000_000,
              viewport.zoom.isFinite, (0.2...2).contains(viewport.zoom) else {
            throw AutomationError.invalid("노드 그래프 형식 또는 시작 노드를 확인해주세요.")
        }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for node in nodes {
            guard node.x.isFinite, node.y.isFinite, abs(node.x) <= 500_000, abs(node.y) <= 500_000,
                  node.step.thenSteps.isEmpty, node.step.elseSteps.isEmpty,
                  node.kind.stepKind == node.step.kind else { throw AutomationError.invalid("노드 데이터가 올바르지 않습니다.") }
        }
        var ports = Set<String>()
        for edge in edges {
            guard let source = byID[edge.source], let target = byID[edge.target],
                  source.kind.outlets.contains(edge.outlet), target.kind != .start,
                  source.id != target.id,
                  ports.insert("\(edge.source)-\(edge.outlet.rawValue)").inserted else {
                throw AutomationError.invalid("연결선을 확인해주세요. 출력 포트 하나에는 연결선 하나를 사용할 수 있습니다.")
            }
        }
        guard topologicalOrder().count == nodes.count else {
            throw AutomationError.invalid("순환 연결은 사용할 수 없습니다. 반복 횟수 설정을 사용해주세요.")
        }
    }

    public func validated(availableMacros: Set<UUID>) throws -> Self {
        try validateStructure()
        let reachable = reachableIDs
        for node in nodes where reachable.contains(node.id) {
            for outlet in node.kind.outlets {
                guard edges.contains(where: { $0.source == node.id && $0.outlet == outlet }) else {
                    throw AutomationError.invalid(node.kind == .imageIf ? "IF의 발견·시간 초과 포트를 모두 연결해주세요." : "실행 경로의 모든 출력 포트를 다음 노드나 종료 노드에 연결해주세요.")
                }
            }
            if [.macro, .wait, .imageIf].contains(node.kind) {
                var single = AutomationWorkflow(name: "노드")
                single.steps = [node.step]
                _ = try single.validated(availableMacros: availableMacros)
            }
        }
        return self
    }

    public mutating func connect(source: UUID, outlet: GraphOutlet, target: UUID) throws {
        var candidate = self
        candidate.edges.removeAll { $0.source == source && $0.outlet == outlet }
        candidate.edges.append(GraphEdge(source: source, outlet: outlet, target: target))
        try candidate.validateStructure()
        self = candidate
    }

    public mutating func removeNode(_ id: UUID) {
        guard nodes.first(where: { $0.id == id })?.kind != .start else { return }
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.source == id || $0.target == id }
    }

    public func arranged() -> Self {
        let order = topologicalOrder()
        guard order.count == nodes.count, let start = nodes.first(where: { $0.kind == .start }) else { return self }
        var result = self
        var rank: [UUID: Int] = [start.id: 0]
        let outgoing = Dictionary(grouping: edges, by: \.source)
        for id in order {
            guard let level = rank[id] else { continue }
            for edge in outgoing[id] ?? [] { rank[edge.target] = max(rank[edge.target] ?? 0, level + 1) }
        }
        var groups: [Int: [UUID]] = [:]
        // Breadth-first ordering keeps the IF's true path above its false path.
        var bfs = [start.id], seen: Set<UUID> = [start.id], cursor = 0
        while cursor < bfs.count {
            let id = bfs[cursor]; cursor += 1
            groups[rank[id] ?? 0, default: []].append(id)
            for edge in (outgoing[id] ?? []).sorted(by: { $0.outlet.rawValue < $1.outlet.rawValue }) where seen.insert(edge.target).inserted { bfs.append(edge.target) }
        }
        for (level, ids) in groups {
            for (row, id) in ids.enumerated() {
                if let i = result.nodes.firstIndex(where: { $0.id == id }) {
                    result.nodes[i].x = 80 + Double(level) * 310
                    result.nodes[i].y = 280 + (Double(row) - Double(ids.count - 1) / 2) * 200
                }
            }
        }
        let bottom = (result.nodes.filter { seen.contains($0.id) }.map(\.y).max() ?? 280) + 240
        for (index, id) in nodes.filter({ !seen.contains($0.id) }).map(\.id).enumerated() {
            if let i = result.nodes.firstIndex(where: { $0.id == id }) {
                result.nodes[i].x = 80 + Double(index % 3) * 310
                result.nodes[i].y = bottom + Double(index / 3) * 200
            }
        }
        return result
    }

    private func topologicalOrder() -> [UUID] {
        var degree = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        for edge in edges { degree[edge.target, default: 0] += 1 }
        let outgoing = Dictionary(grouping: edges, by: \.source)
        var queue = nodes.filter { degree[$0.id] == 0 }.map(\.id), cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for edge in outgoing[id] ?? [] {
                degree[edge.target, default: 0] -= 1
                if degree[edge.target] == 0 { queue.append(edge.target) }
            }
        }
        return queue
    }

    public static func migrating(_ steps: [AutomationStep]) throws -> Self {
        let start = GraphNode(kind: .start), end = GraphNode(kind: .end)
        var graph = Self(nodes: [start, end])
        func append(_ steps: [AutomationStep], next: UUID, depth: Int) throws -> UUID {
            guard depth <= 8 else { throw AutomationError.invalid("기존 IF의 중첩 깊이가 너무 큽니다.") }
            var entry = next
            for step in steps.reversed() {
                guard graph.nodes.count < 1_002 else { throw AutomationError.invalid("자동화 노드가 너무 많습니다.") }
                let kind: GraphNodeKind
                switch step.kind { case .macro: kind = .macro; case .wait: kind = .wait; case .imageIf: kind = .imageIf; case .finish: kind = .finish }
                var node = GraphNode(id: step.id, kind: kind)
                node.step = step; node.step.thenSteps = []; node.step.elseSteps = []
                graph.nodes.append(node)
                if kind == .imageIf {
                    let yes = try append(step.thenSteps, next: entry, depth: depth + 1)
                    let no = try append(step.elseSteps, next: entry, depth: depth + 1)
                    graph.edges.append(GraphEdge(source: node.id, outlet: .found, target: yes))
                    graph.edges.append(GraphEdge(source: node.id, outlet: .notFound, target: no))
                } else if kind != .finish {
                    graph.edges.append(GraphEdge(source: node.id, outlet: .next, target: entry))
                }
                entry = node.id
            }
            return entry
        }
        let entry = try append(steps, next: end.id, depth: 0)
        graph.edges.append(GraphEdge(source: start.id, outlet: .next, target: entry))
        try graph.validateStructure()
        return graph.arranged()
    }
}
