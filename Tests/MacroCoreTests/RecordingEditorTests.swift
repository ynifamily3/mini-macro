import Foundation
import MacroCore
import Testing

@Test func clickEditorPreservesPausesHoldDurationAndCreationDate() throws {
    let recording = MacroRecording(duration: 2.5, actions: [
        MouseAction(time: 0.8, kind: .down, x: 100, y: -30, button: 1, clickCount: 2),
        MouseAction(time: 1.1, kind: .up, x: 100, y: -30, button: 1, clickCount: 2)
    ], mode: .clicksOnly)
    let edit = try RecordingEdit(recording: recording)
    #expect(edit.steps.map(\.kind) == [.wait, .click, .wait])
    #expect(abs(edit.steps[1].seconds - 0.3) < 1e-9)
    let restored = try edit.recording()
    #expect(restored.mode == .clicksOnly && restored.createdAt == recording.createdAt)
    #expect(abs(restored.duration - recording.duration) < 1e-9)
    for (a, b) in zip(restored.actions, recording.actions) {
        #expect(abs(a.time - b.time) < 1e-9)
        #expect(a.x == b.x && a.y == b.y && a.button == b.button && a.clickCount == b.clickCount && a.kind == b.kind)
    }
}

@Test func editingClickCoordinatesMovesBothPressAndReleaseAndShiftsLaterEvents() throws {
    var edit = RecordingEdit()
    var click = RecordingStep(kind: .click); click.x = 123; click.y = 456; click.seconds = 0.2
    var wait = RecordingStep(kind: .wait); wait.seconds = 1.5
    var move = RecordingStep(kind: .move); move.x = -200; move.y = 50
    edit.steps = [click, wait, move]
    let recording = try edit.recording()
    #expect(recording.mode == .allEvents)
    #expect(recording.actions.map(\.kind) == [.down, .up, .move])
    #expect(recording.actions[0].x == 123 && recording.actions[1].x == 123)
    #expect(recording.actions[0].y == 456 && recording.actions[1].y == 456)
    #expect(abs(recording.actions[2].time - 1.7) < 1e-9)
}

@Test func editingLeavesDragsOverlappingButtonsAndTrackpadMetadataIntact() throws {
    let scroll = ScrollData(vertical: 2, horizontal: -1, pointVertical: 2.5, pointHorizontal: -0.3,
        fixedVertical: 163840, fixedHorizontal: -19660, continuous: true, phase: 2, momentum: 1)
    let recording = MacroRecording(duration: 1.5, actions: [
        MouseAction(time: 0, kind: .move, x: 10, y: 20),
        MouseAction(time: 0.1, kind: .down, x: 10, y: 20),
        MouseAction(time: 0.2, kind: .down, x: 10, y: 20, button: 1),
        MouseAction(time: 0.3, kind: .drag, x: 30, y: 40),
        MouseAction(time: 0.4, kind: .up, x: 30, y: 40, button: 1),
        MouseAction(time: 0.5, kind: .up, x: 30, y: 40),
        MouseAction(time: 1, kind: .scroll, x: 30, y: 40, scroll: scroll)
    ])
    let edit = try RecordingEdit(recording: recording)
    #expect(!edit.steps.contains { $0.kind == .click })
    let restored = try edit.recording()
    #expect(restored.actions.count == recording.actions.count)
    for (a, b) in zip(restored.actions, recording.actions) {
        #expect(abs(a.time - b.time) < 1e-9)
        #expect(a.kind == b.kind && a.x == b.x && a.y == b.y && a.button == b.button && a.scroll == b.scroll)
    }
    #expect(abs(restored.duration - 1.5) < 1e-9)
}

@Test func editorRejectsBrokenButtonSequencesNonfiniteCoordinatesAndInvalidDelays() throws {
    var edit = RecordingEdit()
    edit.steps = [RecordingStep(kind: .up)]
    #expect(throws: (any Error).self) { try edit.recording() }
    edit.steps = [RecordingStep(kind: .click)]
    edit.steps[0].x = .nan
    #expect(throws: (any Error).self) { try edit.recording() }
    edit.steps[0].x = 0; edit.steps[0].seconds = -1
    #expect(throws: (any Error).self) { try edit.recording() }
    edit.steps[0].seconds = .infinity
    #expect(throws: (any Error).self) { try edit.recording() }
    edit.steps[0].seconds = 1802
    #expect(throws: (any Error).self) { try edit.recording() }
    edit.steps = [RecordingStep(kind: .wait)]
    #expect(throws: (any Error).self) { try edit.recording() }
}

@Test func adjacentReleaseWithDifferentPositionIsNeverCollapsedIntoAClick() throws {
    let recording = MacroRecording(duration: 1, actions: [
        MouseAction(time: 0, kind: .down, x: 10, y: 10),
        MouseAction(time: 0.5, kind: .up, x: 50, y: 50)
    ])
    let edit = try RecordingEdit(recording: recording)
    #expect(edit.steps.map(\.kind) == [.down, .wait, .up, .wait])
    #expect(try edit.recording() == recording)
}
