import Foundation
import MacroCore
@testable import MacMacro
import Testing

@Test @MainActor func oldAutomationIsBackedUpAndMigratedOnlyOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Automations")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var legacy = AutomationWorkflow(name: "기존 IF")
    var condition = AutomationStep(kind: .imageIf)
    condition.condition.templatePNG = Data([3, 4, 5])
    condition.thenSteps = [AutomationStep(kind: .wait)]
    condition.elseSteps = [AutomationStep(kind: .finish)]
    legacy.steps = [condition]
    let original = try JSONEncoder().encode(legacy)
    let url = folder.appendingPathComponent(legacy.id.uuidString).appendingPathExtension("json")
    try original.write(to: url)
    let first = AutomationStore(root: root)
    let migrated = try #require(first.workflows.first)
    #expect(migrated.graph != nil)
    #expect(migrated.steps.isEmpty)
    #expect(migrated.graph?.nodes.first(where: { $0.id == condition.id })?.step.condition.templatePNG == condition.condition.templatePNG)
    #expect(try Data(contentsOf: url.appendingPathExtension("v2-backup")) == original)
    let second = AutomationStore(root: root)
    #expect(second.workflows.first == migrated)
    #expect(try Data(contentsOf: url.appendingPathExtension("v2-backup")) == original)
}

@Test @MainActor func canvasChangesSurviveAStoreReload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AutomationStore(root: root)
    let id = store.createWorkflow()
    var flow = try #require(store.workflows.first)
    var graph = try #require(flow.graph)
    let start = try #require(graph.nodes.first { $0.kind == .start })
    let end = try #require(graph.nodes.first { $0.kind == .end })
    try graph.connect(source: start.id, outlet: .next, target: end.id)
    graph.nodes[0].x = 242
    graph.viewport.zoom = 0.6; graph.viewport.initialized = true
    flow.graph = graph
    store.update(flow); store.flush()
    let restored = AutomationStore(root: root)
    #expect(restored.workflows.first(where: { $0.id == id })?.graph == graph)
}
