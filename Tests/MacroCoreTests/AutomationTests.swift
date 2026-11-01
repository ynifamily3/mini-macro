import Foundation
@testable import MacroCore
import Testing

private func macroStep(_ id: UUID) -> AutomationStep {
    var step = AutomationStep(kind: .macro); step.macroID = id; return step
}

private func imageStep() -> AutomationStep {
    var step = AutomationStep(kind: .imageIf)
    step.condition.templatePNG = Data([1, 2, 3])
    return step
}

@Test @MainActor func chainsMacrosAndRepeatsWholeWorkflow() async throws {
    let a = UUID(), b = UUID()
    var flow = AutomationWorkflow()
    flow.repetitions = 2
    var second = macroStep(b); second.repetitions = 3
    flow.steps = [macroStep(a), second]
    var calls: [(UUID, Int)] = []
    let runner = AutomationExecutor(play: { calls.append(($0, $1)) }, detect: { _ in nil }, click: { _ in })
    try await runner.run(flow, availableMacros: [a, b])
    #expect(calls.map(\.0) == [a, b, a, b])
    #expect(calls.map(\.1) == [1, 3, 1, 3])
}

@Test @MainActor func foundImageClicksThenExecutesOnlyTrueBranchAndContinues() async throws {
    let a = UUID(), b = UUID(), after = UUID()
    var condition = imageStep()
    condition.condition.clickWhenFound = true
    condition.thenSteps = [macroStep(a)]; condition.elseSteps = [macroStep(b)]
    var flow = AutomationWorkflow(); flow.steps = [condition, macroStep(after)]
    var log: [String] = []
    let runner = AutomationExecutor(play: { id, _ in log.append(id.uuidString) }, detect: { _ in
        log.append("detect"); return ImageMatch(x: 10, y: 20, width: 30, height: 40, score: 1)
    }, click: { match in #expect(match.x == 10); log.append("click") })
    try await runner.run(flow, availableMacros: [a, b, after])
    #expect(log == ["detect", "click", a.uuidString, after.uuidString])
}

@Test @MainActor func timeoutExecutesOnlyFalseBranch() async throws {
    let a = UUID(), b = UUID()
    var step = imageStep(); step.thenSteps = [macroStep(a)]; step.elseSteps = [macroStep(b)]
    var flow = AutomationWorkflow(); flow.steps = [step]
    var played: [UUID] = []
    let runner = AutomationExecutor(play: { id, _ in played.append(id) }, detect: { _ in nil }, click: { _ in Issue.record("Should not click") })
    try await runner.run(flow, availableMacros: [a, b])
    #expect(played == [b])
}

@Test @MainActor func captureErrorsNeverBecomeAFalseBranch() async {
    let a = UUID()
    var step = imageStep(); step.elseSteps = [macroStep(a)]
    var flow = AutomationWorkflow(); flow.steps = [step]
    var played = false
    let runner = AutomationExecutor(play: { _, _ in played = true }, detect: { _ in throw AutomationError.invalid("Capture denied") }, click: { _ in })
    await #expect(throws: AutomationError.self) { try await runner.run(flow, availableMacros: [a]) }
    #expect(!played)
}

@Test @MainActor func nestedFinishStopsFollowingStepsAndAllRepetitions() async throws {
    let a = UUID()
    var nested = imageStep(); nested.thenSteps = [AutomationStep(kind: .finish), macroStep(a)]
    var outer = imageStep(); outer.thenSteps = [nested]
    var flow = AutomationWorkflow(); flow.steps = [outer, macroStep(a)]; flow.repetitions = 5
    var detections = 0
    let runner = AutomationExecutor(play: { _, _ in Issue.record("Unexpected macro") }, detect: { _ in
        detections += 1; return ImageMatch(x: 0, y: 0, width: 10, height: 10, score: 1)
    }, click: { _ in })
    try await runner.run(flow, availableMacros: [a])
    #expect(detections == 2)
}

@Test @MainActor func cancellationDuringWaitPreventsLaterMacros() async {
    let a = UUID()
    var wait = AutomationStep(kind: .wait); wait.waitSeconds = 60
    var flow = AutomationWorkflow(); flow.steps = [wait, macroStep(a)]
    let snapshot = flow
    var entered = false, played = false
    let runner = AutomationExecutor(play: { _, _ in played = true }, detect: { _ in nil }, click: { _ in }, report: { _, _ in entered = true })
    let task = Task { try await runner.run(snapshot, availableMacros: [a]) }
    while !entered { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!played)
}

@Test @MainActor func missingMacroFailsBeforeAnyExecution() async {
    var flow = AutomationWorkflow(); flow.steps = [macroStep(UUID())]
    let runner = AutomationExecutor(play: { _, _ in Issue.record("Unexpected playback") }, detect: { _ in nil }, click: { _ in })
    await #expect(throws: AutomationError.self) { try await runner.run(flow, availableMacros: []) }
}

@Test @MainActor func cancellationWhileCaptureCompletesNeverClicksOrTakesABranch() async {
    let id = UUID()
    var step = imageStep(); step.condition.clickWhenFound = true; step.thenSteps = [macroStep(id)]
    var flow = AutomationWorkflow(); flow.steps = [step]
    let snapshot = flow
    var continuation: CheckedContinuation<ImageMatch?, Never>?
    var acted = false
    let runner = AutomationExecutor(play: { _, _ in acted = true }, detect: { _ in
        await withCheckedContinuation { continuation = $0 }
    }, click: { _ in acted = true })
    let task = Task { try await runner.run(snapshot, availableMacros: [id]) }
    while continuation == nil { await Task.yield() }
    task.cancel()
    continuation?.resume(returning: ImageMatch(x: 1, y: 2, width: 10, height: 10, score: 1))
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!acted)
}

@Test func workflowRoundTripPreservesNestedConditionsAndMacroReferences() throws {
    let id = UUID()
    var step = imageStep(); step.thenSteps = [macroStep(id)]; step.elseSteps = [AutomationStep(kind: .finish)]
    step.condition.region = SearchRegion(x: -100, y: 10, width: 200, height: 100)
    var flow = AutomationWorkflow(); flow.steps = [step]
    let restored = try JSONDecoder().decode(AutomationWorkflow.self, from: JSONEncoder().encode(flow)).validated(availableMacros: [id])
    #expect(restored == flow)
    #expect(restored.referencedMacroIDs == [id])
    #expect(restored.usesImages)
}

@Test func rejectsInvalidConditionBeforeSearching() {
    var step = imageStep(); step.condition.timeout = .nan
    var flow = AutomationWorkflow(); flow.steps = [step]
    #expect(throws: AutomationError.self) { try flow.validated(availableMacros: []) }
    step.condition.timeout = 10; step.condition.pollInterval = 0
    flow.steps = [step]
    #expect(throws: AutomationError.self) { try flow.validated(availableMacros: []) }
}

private func pattern(_ width: Int, _ height: Int) throws -> GrayImage {
    let pixels = (0..<(width * height)).map { i in Float((i * 97 + i / width * 31 + (i % 7) * 19) % 251) / 255 }
    return try GrayImage(width: width, height: height, pixels: pixels)
}

@Test func imageMatcherFindsExactPatternAtNonAlignedPosition() throws {
    let template = try pattern(24, 24)
    var pixels = [Float](repeating: 0.12, count: 140 * 100)
    for y in 0..<24 { for x in 0..<24 { pixels[(y + 37) * 140 + x + 53] = template.pixels[y * 24 + x] } }
    let image = try GrayImage(width: 140, height: 100, pixels: pixels)
    let match = try #require(try TemplateMatcher.find(template: template, in: image))
    #expect(match.x == 53)
    #expect(match.y == 37)
    #expect(match.score > 0.999)
}

@Test func imageMatcherFindsPatternAtLastRowAndColumn() throws {
    let template = try pattern(13, 11)
    var pixels = [Float](repeating: 0.7, count: 60 * 40)
    for y in 0..<11 { for x in 0..<13 { pixels[(y + 29) * 60 + x + 47] = template.pixels[y * 13 + x] } }
    let image = try GrayImage(width: 60, height: 40, pixels: pixels)
    let match = try #require(try TemplateMatcher.find(template: template, in: image))
    #expect(match.x == 47 && match.y == 29)
    #expect(match.score > 0.999)
}

@Test func imageMatcherRejectsFlatTemplatesAndReturnsNoHighMatchForAbsentPattern() throws {
    let flat = try GrayImage(width: 12, height: 12, pixels: Array(repeating: 0.5, count: 144))
    #expect(throws: AutomationError.self) { try TemplateMatcher.find(template: flat, in: flat) }
    let image = try GrayImage(width: 40, height: 30, pixels: Array(repeating: 0.5, count: 1_200))
    let match = try TemplateMatcher.find(template: pattern(12, 12), in: image)
    #expect((match?.score ?? 0) < 0.9)
}
