import Foundation
@testable import MacroCore
import Testing

private func graphMacro(_ id: UUID) -> AutomationStep { var s = AutomationStep(kind: .macro); s.macroID = id; return s }
private func graphIf() -> AutomationStep { var s = AutomationStep(kind: .imageIf); s.condition.templatePNG = Data([1]); return s }

@Test @MainActor func migratingNestedBranchesPreservesOrderAndRepetition() async throws {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    var image = graphIf(); image.thenSteps = [graphMacro(b)]; image.elseSteps = [graphMacro(c)]
    var legacy = AutomationWorkflow(); legacy.steps = [graphMacro(a), image, graphMacro(d)]; legacy.repetitions = 2
    var migrated = legacy; migrated.graph = try AutomationGraph.migrating(legacy.steps); migrated.steps = []
    for found in [true, false] {
        var oldCalls: [UUID] = [], newCalls: [UUID] = [], visited: [UUID] = [], edges: [UUID] = []
        let match: ImageMatch? = found ? ImageMatch(x: 1, y: 2, width: 3, height: 4, score: 1) : nil
        let old = AutomationExecutor(play: { id, _ in oldCalls.append(id) }, detect: { _ in match }, click: { _ in })
        let runner = AutomationExecutor(play: { id, _ in newCalls.append(id) }, detect: { _ in match }, click: { _ in },
                                        onNode: { id, _ in visited.append(id) }, onEdge: { edges.append($0) })
        try await old.run(legacy, availableMacros: [a, b, c, d])
        try await runner.run(migrated, availableMacros: [a, b, c, d])
        #expect(newCalls == oldCalls)
        #expect(newCalls == [a, found ? b : c, d, a, found ? b : c, d])
        #expect(visited.contains(image.id))
        let expectedBranch = try #require(migrated.graph?.edges.first { $0.source == image.id && $0.outlet == (found ? .found : .notFound) })
        #expect(edges.contains(expectedBranch.id))
        #expect(Set(visited).count == 6) // Start, A, IF, chosen branch, D, end.
    }
}

@Test @MainActor func migratedEarlyFinishStillStopsAllIterations() async throws {
    let id = UUID()
    var condition = graphIf(); condition.thenSteps = [AutomationStep(kind: .finish)]
    var flow = AutomationWorkflow(); flow.steps = [condition, graphMacro(id)]; flow.repetitions = 5
    flow.graph = try AutomationGraph.migrating(flow.steps); flow.steps = []
    var detections = 0
    let runner = AutomationExecutor(play: { _, _ in Issue.record("Must stop before macro") }, detect: { _ in
        detections += 1; return ImageMatch(x: 0, y: 0, width: 10, height: 10, score: 1)
    }, click: { _ in })
    try await runner.run(flow, availableMacros: [id])
    #expect(detections == 1)
}

@Test func rewiringReplacesOnlyTheSelectedOutletAndRejectsCyclesAtomically() throws {
    let start = GraphNode(kind: .start), a = GraphNode(kind: .wait), b = GraphNode(kind: .wait), end = GraphNode(kind: .end)
    var graph = AutomationGraph(nodes: [start, a, b, end])
    try graph.connect(source: start.id, outlet: .next, target: a.id)
    try graph.connect(source: a.id, outlet: .next, target: b.id)
    try graph.connect(source: b.id, outlet: .next, target: end.id)
    let before = graph
    #expect(throws: AutomationError.self) { try graph.connect(source: b.id, outlet: .next, target: a.id) }
    #expect(graph == before)
    #expect(throws: AutomationError.self) { try graph.connect(source: a.id, outlet: .next, target: start.id) }
    #expect(graph == before)
    try graph.connect(source: a.id, outlet: .next, target: end.id)
    #expect(graph.edges.count == 3)
    #expect(graph.edges.first(where: { $0.source == a.id })?.target == end.id)
    #expect(!graph.reachableIDs.contains(b.id))
}

@Test func deletingANodeRemovesAllItsConnectionsButStartCannotBeDeleted() throws {
    let start = GraphNode(kind: .start), wait = GraphNode(kind: .wait), end = GraphNode(kind: .end)
    var graph = AutomationGraph(nodes: [start, wait, end])
    try graph.connect(source: start.id, outlet: .next, target: wait.id)
    try graph.connect(source: wait.id, outlet: .next, target: end.id)
    graph.removeNode(wait.id)
    #expect(graph.nodes.count == 2)
    #expect(graph.edges.isEmpty)
    graph.removeNode(start.id)
    #expect(graph.nodes.count == 2)
    #expect(throws: AutomationError.self) { try graph.validated(availableMacros: []) }
}

@Test func reachableIfRequiresBothOutputsButUnconnectedDraftsAreNotExecuted() throws {
    let start = GraphNode(kind: .start), end = GraphNode(kind: .end), unused = GraphNode(kind: .macro)
    var image = GraphNode(kind: .imageIf); image.step.condition.templatePNG = Data([1])
    var graph = AutomationGraph(nodes: [start, image, end, unused])
    try graph.connect(source: start.id, outlet: .next, target: image.id)
    try graph.connect(source: image.id, outlet: .found, target: end.id)
    #expect(throws: AutomationError.self) { try graph.validated(availableMacros: []) }
    try graph.connect(source: image.id, outlet: .notFound, target: end.id)
    _ = try graph.validated(availableMacros: [])
    #expect(!graph.reachableIDs.contains(unused.id))
    #expect(graph.usesImages)
}

@Test @MainActor func graphCancellationAfterCaptureNeverTakesAnOutputOrClicks() async {
    var step = graphIf(); step.condition.clickWhenFound = true
    var flow = AutomationWorkflow()
    do { flow.graph = try AutomationGraph.migrating([step]) } catch { Issue.record(error); return }
    let snapshot = flow
    var continuation: CheckedContinuation<ImageMatch?, Never>?
    var clicked = false, edges: [UUID] = []
    let runner = AutomationExecutor(play: { _, _ in Issue.record("No macros expected") }, detect: { _ in
        await withCheckedContinuation { continuation = $0 }
    }, click: { _ in clicked = true }, onEdge: { edges.append($0) })
    let task = Task { try await runner.run(snapshot, availableMacros: []) }
    while continuation == nil { await Task.yield() }
    task.cancel()
    continuation?.resume(returning: ImageMatch(x: 0, y: 0, width: 10, height: 10, score: 1))
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!clicked)
    #expect(edges.count == 1) // Only start -> IF; never IF -> branch.
}

@Test func viewportZoomKeepsThePointUnderThePointerStationary() {
    var viewport = GraphViewport(); viewport.x = -53; viewport.y = 81; viewport.zoom = 0.65
    let pointer = CGPoint(x: 310, y: 220)
    let world = viewport.worldPoint(pointer)
    let changed = viewport.zoomed(by: 1.4, around: pointer)
    let after = changed.screenPoint(world)
    #expect(abs(after.x - pointer.x) < 0.000_001)
    #expect(abs(after.y - pointer.y) < 0.000_001)
    #expect(changed.zoom > viewport.zoom)
    #expect(viewport.zoomed(by: 100, around: pointer).zoom == 2)
    #expect(viewport.zoomed(by: 0.001, around: pointer).zoom == 0.2)
}

@Test func graphRoundTripKeepsPositionsConnectionsAndCamera() throws {
    var flow = AutomationWorkflow()
    flow.graph = try AutomationGraph.migrating([AutomationStep(kind: .wait)])
    flow.graph?.nodes[0].x = -82
    flow.graph?.viewport.x = 121
    flow.graph?.viewport.zoom = 0.45
    let restored = try JSONDecoder().decode(AutomationWorkflow.self, from: JSONEncoder().encode(flow))
    #expect(restored == flow)
    _ = try restored.validated(availableMacros: [])
}
