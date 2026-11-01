import Foundation
import MacroCore
@testable import MacMacro
import Testing

@Test @MainActor func editingSavedMacroPreservesIDWorkflowReferencesAndPersists() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AutomationStore(root: root)
    var edit = RecordingEdit(); edit.steps = [RecordingStep(kind: .click)]
    let id = try #require(store.addRecording(edit.recording(), name: "원본"))
    let old = try #require(store.macros.first)
    _ = store.createWorkflow()
    var flow = try #require(store.workflows.first)
    var node = GraphNode(kind: .macro); node.step.macroID = id
    flow.graph?.nodes.append(node); store.update(flow); store.flush()
    edit.steps[0].x = 700
    let saved = try store.saveEditedMacro(SavedMacro(id: id, name: "수정", recording: edit.recording()), replacing: old)
    let restored = AutomationStore(root: root)
    #expect(saved.id == id && restored.macros.count == 1)
    #expect(restored.macros.first?.recording.actions.first?.x == 700)
    #expect(restored.macros.first?.name == "수정")
    #expect(restored.workflows.first?.referencedMacroIDs.contains(id) == true)
    #expect(throws: (any Error).self) { try store.saveEditedMacro(old, replacing: old) }
    var invalid = saved; invalid.recording.actions.removeLast()
    #expect(throws: (any Error).self) { try store.saveEditedMacro(invalid, replacing: saved) }
    #expect(AutomationStore(root: root).macros.first == saved)
}
