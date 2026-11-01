import AppKit
import Foundation
import MacroCore
@testable import MacMacro
import Testing

private func sampleRecording() -> MacroRecording {
    var buffer = RecordingAccumulator(x: 10, y: 20, mode: .clicksOnly)
    buffer.append(MouseAction(time: 0.1, kind: .down, x: 10, y: 20))
    buffer.append(MouseAction(time: 0.2, kind: .up, x: 10, y: 20))
    return buffer.finish(at: 0.3)
}

@Test @MainActor func libraryAndWorkflowPersistAndReloadWithoutChangingIDs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AutomationStore(root: root)
    let id = try #require(store.addRecording(sampleRecording(), name: "첫 매크로"))
    store.renameMacro(id, name: "바뀐 이름")
    let flowID = store.createWorkflow()
    var flow = try #require(store.workflows.first)
    var step = AutomationStep(kind: .macro); step.macroID = id
    flow.steps = [step]; flow.graph = nil; flow.name = "순서 실행"
    store.update(flow); store.flush()
    let expected = store.workflows.first
    let restored = AutomationStore(root: root)
    #expect(restored.macros.first?.id == id)
    #expect(restored.macros.first?.name == "바뀐 이름")
    #expect(restored.workflows.first?.id == flowID)
    #expect(restored.workflows.first == expected)
    #expect(restored.error == nil)
}

@Test @MainActor func migrationPreservesLegacyRecordingAndDoesNotDuplicate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = try JSONEncoder().encode(sampleRecording())
    try original.write(to: root.appendingPathComponent("last-recording.json"))
    let first = AutomationStore(root: root)
    let second = AutomationStore(root: root)
    #expect(first.macros.count == 1 && second.macros.count == 1)
    #expect(first.macros.first?.id == second.macros.first?.id)
    #expect(try Data(contentsOf: root.appendingPathComponent("last-recording.json")) == original)
}

@Test @MainActor func unreadableFilesRemainUntouched() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Macros")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let bad = Data("invalid".utf8); try bad.write(to: file)
    let store = AutomationStore(root: root)
    #expect(store.error != nil)
    #expect(try Data(contentsOf: file) == bad)
}

@Test @MainActor func multipleMacrosStaySeparateAndDuplicateImportsReuseTheExistingMacro() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AutomationStore(root: root)
    let first = sampleRecording()
    var second = first; second.createdAt = first.createdAt.addingTimeInterval(1)
    second.actions[0].x = 30; second.actions[1].x = 30
    let a = try #require(store.addRecording(first, name: "A"))
    let b = try #require(store.addRecording(second, name: "B"))
    #expect(a != b)
    #expect(store.addRecording(first) == a)
    let loaded = AutomationStore(root: root)
    #expect(loaded.macros.count == 2)
    #expect(loaded.macros.first(where: { $0.id == a })?.recording == first)
    #expect(loaded.macros.first(where: { $0.id == b })?.recording == second)
}

@Test @MainActor func deletingAMacroReferencedInsideAnIfIsBlocked() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AutomationStore(root: root)
    let id = try #require(store.addRecording(sampleRecording()))
    _ = store.createWorkflow()
    var flow = try #require(store.workflows.first)
    var macro = AutomationStep(kind: .macro); macro.macroID = id
    var condition = AutomationStep(kind: .imageIf); condition.thenSteps = [macro]
    flow.steps = [condition]; flow.graph = nil; store.update(flow); store.flush()
    store.deleteMacro(id)
    #expect(store.error != nil)
    #expect(store.macros.count == 1)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Macros/\(id.uuidString).json").path))
}

@Test func screenMatcherMapsRetinaPixelsAndSearchRegionToGlobalCoordinates() async throws {
    let width = 160, height = 120
    var pixels = [UInt8](repeating: 40, count: width * height)
    for y in 0..<24 { for x in 0..<24 { pixels[(y + 35) * width + x + 61] = UInt8((x * 37 + y * 59 + x * y * 3) % 240 + 10) } }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let pattern = try #require(image.cropping(to: CGRect(x: 61, y: 35, width: 24, height: 24)))
    let frame = CapturedScreen(image: image, bounds: CGRect(x: 200, y: -100, width: 80, height: 60), displayID: 1)
    var condition = ImageCondition()
    condition.templatePNG = try ScreenImageService.png(pattern)
    condition.region = SearchRegion(x: 220, y: -90, width: 40, height: 40)
    condition.similarity = 0.99
    let match = try #require(try await ScreenImageService.match(condition, frame: frame))
    #expect(abs(match.x - 230.5) < 0.1)
    #expect(abs(match.y - -82.5) < 0.1)
    #expect(match.width == 12 && match.height == 12)
}
