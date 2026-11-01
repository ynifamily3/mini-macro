import Foundation
import MacroCore
import Testing

@Test func overlayCoordinatesRoundTripForRetinaAndDisplaysLeftAboveAndBelow() {
    // Frames and mouse positions are logical points, never backing pixels.
    let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: -1920, y: 150, width: 1920, height: 1080),
        CGRect(x: 100, y: 900, width: 1200, height: 800),
        CGRect(x: 1440, y: -600, width: 1200, height: 800)]
    for frame in frames {
        let transform = RecordingScreenTransform(screenFrame: frame, primaryScreenTop: 900)
        for local in [CGPoint.zero, CGPoint(x: 50.5, y: 72.25), CGPoint(x: frame.width, y: frame.height)] {
            #expect(transform.localPoint(transform.globalPoint(local)) == local)
        }
        #expect(transform.globalPoint(.zero) == CGPoint(x: frame.minX, y: 900 - frame.maxY))
    }
}

@Test func movingClickChangesBothEventsWithoutChangingTimingOrOtherRows() throws {
    var edit = RecordingEdit()
    var click = RecordingStep(kind: .click); click.x = 30; click.y = 40
    var wait = RecordingStep(kind: .wait); wait.seconds = 2
    edit.steps = [click, wait, RecordingStep(kind: .click)]
    let original = edit
    try edit.reposition(click.id, to: CGPoint(x: -100, y: 600))
    let recording = try edit.recording(), before = try original.recording()
    #expect(recording.actions.map(\.time) == before.actions.map(\.time))
    #expect(recording.duration == before.duration)
    #expect(recording.actions[0].x == -100 && recording.actions[1].x == -100)
    #expect(recording.actions[0].y == 600 && recording.actions[1].y == 600)
    #expect(edit.steps[1] == original.steps[1] && edit.steps[2] == original.steps[2])
    #expect(edit.steps.map(\.id) == original.steps.map(\.id))
}

@Test func translatingEntireDragKeepsRelativePathButtonsAndScrollMetadata() throws {
    let source = MacroRecording(duration: 2, actions: [
        MouseAction(time: 0, kind: .move, x: 10, y: 20),
        MouseAction(time: 0.2, kind: .down, x: 10, y: 20),
        MouseAction(time: 0.5, kind: .drag, x: 70, y: 80),
        MouseAction(time: 1, kind: .up, x: 90, y: 100),
        MouseAction(time: 1.5, kind: .scroll, x: 90, y: 100, scroll: ScrollData(vertical: 2, horizontal: 0, pointVertical: 2.2, continuous: true, phase: 2))
    ])
    var edit = try RecordingEdit(recording: source)
    try edit.reposition(edit.steps[0].id, to: CGPoint(x: 110, y: -180), entirePath: true)
    let result = try edit.recording()
    for (a, b) in zip(result.actions, source.actions) {
        #expect(a.x == b.x + 100 && a.y == b.y - 200)
        #expect(abs(a.time - b.time) < 1e-9 && a.kind == b.kind && a.scroll == b.scroll && a.button == b.button)
    }
    #expect(result.createdAt == source.createdAt && result.mode == source.mode && result.duration == source.duration)
}

@Test func clickOnlyOverlappingButtonPositionsStayPairedWhenMovingARawRelease() throws {
    let source = MacroRecording(duration: 1, actions: [
        MouseAction(time: 0, kind: .down, x: 10, y: 20),
        MouseAction(time: 0.1, kind: .down, x: 40, y: 50, button: 1),
        MouseAction(time: 0.2, kind: .up, x: 10, y: 20),
        MouseAction(time: 0.3, kind: .up, x: 40, y: 50, button: 1)
    ], mode: .clicksOnly)
    var edit = try RecordingEdit(recording: source)
    let release = try #require(edit.steps.first { $0.kind == .up && $0.button == 0 })
    try edit.reposition(release.id, to: CGPoint(x: 200, y: 300))
    let result = try edit.recording()
    #expect(result.actions[0].x == 200 && result.actions[2].x == 200)
    #expect(result.actions[1].x == 40 && result.actions[3].x == 40)
}

@Test func invalidPositionOrTranslationDoesNotPartiallyMutateTheRecording() throws {
    var edit = RecordingEdit()
    var nearEdge = RecordingStep(kind: .move); nearEdge.x = 99_999
    edit.steps = [RecordingStep(kind: .click), RecordingStep(kind: .wait), nearEdge]
    let original = edit
    #expect(throws: (any Error).self) { try edit.reposition(edit.steps[0].id, to: CGPoint(x: 100, y: 0), entirePath: true) }
    #expect(edit == original)
    #expect(throws: (any Error).self) { try edit.reposition(edit.steps[1].id, to: .zero) }
    #expect(throws: (any Error).self) { try edit.reposition(edit.steps[0].id, to: CGPoint(x: Double.infinity, y: 0)) }
    #expect(edit == original)
}
