import CoreGraphics
import Foundation
@testable import MacroCore
import Testing

@Test func balancesAnInterruptedDrag() throws {
    var buffer = RecordingAccumulator(x: 100, y: 100)
    buffer.append(MouseAction(time: 0.1, kind: .down, x: 100, y: 100))
    buffer.append(MouseAction(time: 0.2, kind: .drag, x: 200, y: 200))
    let recording = try buffer.finish(at: 0.8).validated()
    #expect(recording.actions.last?.kind == .up)
    #expect(recording.actions.last?.time == 0.8)
    #expect(recording.actions.last?.x == 200)
}

@Test func midDragStartDoesNotInventAButtonPress() throws {
    var buffer = RecordingAccumulator(x: 100, y: 100)
    buffer.append(MouseAction(time: 0.1, kind: .drag, x: 120, y: 120))
    buffer.append(MouseAction(time: 0.2, kind: .up, x: 120, y: 120))
    let recording = try buffer.finish(at: 0.3).validated()
    #expect(recording.actions.count == 2)
    #expect(recording.actions.last?.kind == .move)
    #expect(recording.clickCount == 0)
}

@Test func retainsTrailingPauseAndRepeatsExactlyNTimes() {
    let recording = MacroRecording(duration: 2, actions: [MouseAction(time: 0.5, kind: .move, x: 1, y: 1)])
    var timeline = PlaybackTimeline(recording: recording, repetitions: 2, gap: 0.25)
    #expect(timeline.nextDeadline == 0.5)
    #expect(timeline.takeNext() != nil)
    #expect(timeline.nextDeadline == 2)
    #expect(timeline.takeNext() == nil)
    #expect(timeline.nextDeadline == 2.75)
    #expect(timeline.takeNext() != nil)
    #expect(timeline.nextDeadline == 4.25)
    #expect(timeline.takeNext() == nil)
    #expect(timeline.nextDeadline == nil)
    #expect(timeline.iteration == 2)
    #expect(timeline.totalDuration == 4.25)
}

@Test func cancellationStopsEveryRemainingEvent() {
    let recording = MacroRecording(duration: 2, actions: [MouseAction(time: 0, kind: .move, x: 1, y: 1)])
    var timeline = PlaybackTimeline(recording: recording, repetitions: 99)
    timeline.cancel()
    #expect(timeline.nextDeadline == nil)
    #expect(timeline.takeNext() == nil)
    #expect(timeline.iteration == 0)
}

@Test func rejectsMalformedAndUnbalancedImportedMacros() {
    for actions in [
        [MouseAction(time: 0, kind: .up, x: 1, y: 1)],
        [MouseAction(time: 0, kind: .down, x: 1, y: 1)],
        [MouseAction(time: 0.8, kind: .move, x: 1, y: 1), MouseAction(time: 0.2, kind: .move, x: 1, y: 1)],
        [MouseAction(time: 0, kind: .move, x: .infinity, y: 1)],
        [MouseAction(time: 0, kind: .move, x: 1, y: 1, button: 32)],
        [MouseAction(time: 0, kind: .scroll, x: 1, y: 1)],
        [MouseAction(time: 0, kind: .scroll, x: 1, y: 1, scroll: ScrollData(vertical: .min, horizontal: 0))]
    ] {
        #expect(throws: (any Error).self) { try MacroRecording(duration: 1, actions: actions).validated() }
    }
}

@Test func savesAndRestoresRecordingWithoutChangingTiming() throws {
    var buffer = RecordingAccumulator(x: -100, y: 20)
    buffer.append(MouseAction(time: 0.2, kind: .down, x: -100, y: 20, button: 1, clickCount: 2))
    buffer.append(MouseAction(time: 0.4, kind: .up, x: -100, y: 20, button: 1, clickCount: 2))
    let recording = buffer.finish(at: 0.9)
    let restored = try JSONDecoder().decode(MacroRecording.self, from: JSONEncoder().encode(recording)).validated()
    #expect(restored == recording)
}

@Test func ownSyntheticEventsAreTaggedAndDoNotReplayModifiers() throws {
    let source = try #require(MouseEventCodec.makeSource())
    let action = MouseAction(time: 0, kind: .down, x: 100, y: 200, button: 1, clickCount: 2)
    let event = try #require(MouseEventCodec.event(from: action, source: source))
    #expect(event.type == .rightMouseDown)
    #expect(event.location == CGPoint(x: 100, y: 200))
    #expect(event.flags.isEmpty)
    #expect(MouseEventCodec.isOwnEvent(event))
    #expect(event.getIntegerValueField(.mouseEventClickState) == 2)
    #expect(source.localEventsSuppressionInterval == 0)
    #expect(source.getLocalEventsFilterDuringSuppressionState(.eventSuppressionStateRemoteMouseDrag) == MouseEventCodec.allHardwareEvents)
}

@Test func neverRecordsKeyboardEvents() throws {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    #expect(MouseEventCodec.action(from: event, time: 0) == nil)
}

@Test func scrollRoundTripPreservesTrackpadPhasesAndPrecision() throws {
    let source = try #require(MouseEventCodec.makeSource())
    let scroll = ScrollData(vertical: -3, horizontal: 2, pointVertical: -12, pointHorizontal: 8,
                            fixedVertical: -2.5, fixedHorizontal: 1.5, continuous: true, phase: 2, momentum: 1)
    let action = MouseAction(time: 0.2, kind: .scroll, x: 300, y: 400, scroll: scroll)
    let event = try #require(MouseEventCodec.event(from: action, source: source))
    let captured = try #require(MouseEventCodec.action(from: event, time: 0.2))
    #expect(captured.scroll == scroll)
    #expect(captured.x == action.x)
    #expect(captured.y == action.y)
}

@Test func clicksOnlyRecordsClickCoordinatesAndTimingWithoutMovement() throws {
    var buffer = RecordingAccumulator(x: 999, y: 999, mode: .clicksOnly)
    buffer.append(MouseAction(time: 0.1, kind: .move, x: 900, y: 700))
    buffer.append(MouseAction(time: 0.6, kind: .down, x: 100, y: 200))
    buffer.append(MouseAction(time: 0.65, kind: .drag, x: 150, y: 250))
    buffer.append(MouseAction(time: 0.7, kind: .up, x: 150, y: 250))
    buffer.append(MouseAction(time: 1, kind: .scroll, x: 300, y: 400,
                              scroll: ScrollData(vertical: 2, horizontal: 0)))
    buffer.append(MouseAction(time: 2.1, kind: .down, x: -50, y: 500, button: 1))
    buffer.append(MouseAction(time: 2.2, kind: .up, x: -50, y: 500, button: 1))
    let result = try buffer.finish(at: 3).validated()
    #expect(result.mode == .clicksOnly)
    #expect(result.actions.map(\.kind) == [.down, .up, .down, .up])
    #expect(result.actions.map(\.time) == [0.6, 0.7, 2.1, 2.2])
    #expect(result.actions.map(\.x) == [100, 100, -50, -50])
    #expect(result.actions.map(\.y) == [200, 200, 500, 500])
    #expect(result.moveCount == 0)
    #expect(result.scrollCount == 0)
    #expect(result.clickCount == 2)
    #expect(buffer.eventCount == 4)
    #expect(result.duration == 3)
    let restored = try JSONDecoder().decode(MacroRecording.self, from: JSONEncoder().encode(result)).validated()
    #expect(restored == result)
    var playback = PlaybackTimeline(recording: restored, repetitions: 2, gap: 0)
    var replayed: [MouseAction] = []
    while playback.nextDeadline != nil {
        if let action = playback.takeNext() { replayed.append(action) }
    }
    #expect(replayed == result.actions + result.actions)
}

@Test func clicksOnlyWithoutClicksKeepsAnEmptyBuffer() {
    var buffer = RecordingAccumulator(x: 100, y: 200, mode: .clicksOnly)
    buffer.append(MouseAction(time: 0.1, kind: .move, x: 300, y: 400))
    buffer.append(MouseAction(time: 0.2, kind: .drag, x: 500, y: 600))
    buffer.append(MouseAction(time: 0.3, kind: .up, x: 500, y: 600))
    #expect(!buffer.hasRecordedActions)
    #expect(buffer.eventCount == 0)
    #expect(buffer.finish(at: 1).actions.isEmpty)
}

@Test func endingClicksOnlyWithButtonsHeldReleasesAtEachClickOrigin() throws {
    var buffer = RecordingAccumulator(x: 0, y: 0, mode: .clicksOnly)
    buffer.append(MouseAction(time: 0.1, kind: .down, x: 100, y: 200))
    #expect(buffer.hasRecordedActions) // A single held click must still be saved.
    buffer.append(MouseAction(time: 0.2, kind: .down, x: 300, y: 400, button: 1))
    buffer.append(MouseAction(time: 0.3, kind: .drag, x: 500, y: 600))
    let recording = try buffer.finish(at: 1).validated()
    let releases = recording.actions.filter { $0.kind == .up }
    #expect(releases.map(\.x) == [100, 300])
    #expect(releases.map(\.y) == [200, 400])
    #expect(releases.map(\.time) == [1, 1])
}

@Test func legacyFilesWithoutModeRemainFullRecordings() throws {
    let original = MacroRecording(duration: 1, actions: [MouseAction(time: 0, kind: .move, x: 10, y: 20)])
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    legacy.removeValue(forKey: "mode")
    let restored = try JSONDecoder().decode(MacroRecording.self, from: JSONSerialization.data(withJSONObject: legacy)).validated()
    #expect(restored == original)
    #expect(restored.mode == .allEvents)
}

@Test func rejectsMovementInsideAnImportedClicksOnlyRecording() {
    let movement = MacroRecording(duration: 1, actions: [MouseAction(time: 0, kind: .move, x: 10, y: 20)], mode: .clicksOnly)
    let mismatchedClick = MacroRecording(duration: 1, actions: [
        MouseAction(time: 0.1, kind: .down, x: 10, y: 20),
        MouseAction(time: 0.2, kind: .up, x: 30, y: 40)
    ], mode: .clicksOnly)
    #expect(throws: (any Error).self) { try movement.validated() }
    #expect(throws: (any Error).self) { try mismatchedClick.validated() }
}

@Test func clicksOnlyPlaybackJumpsToEachClickUsingTaggedEvents() throws {
    let source = try #require(MouseEventCodec.makeSource())
    let down = MouseAction(time: 1, kind: .down, x: 100, y: 200)
    let events = try #require(MouseEventCodec.playbackEvents(from: down, mode: .clicksOnly, source: source))
    #expect(events.map(\.type) == [.mouseMoved, .leftMouseDown])
    #expect(events.allSatisfy { $0.location == CGPoint(x: 100, y: 200) && MouseEventCodec.isOwnEvent($0) })
    let release = MouseAction(time: 1.1, kind: .up, x: 100, y: 200)
    let up = try #require(MouseEventCodec.playbackEvents(from: release, mode: .clicksOnly, source: source))
    #expect(up.map(\.type) == [.leftMouseUp])
    let fullMode = try #require(MouseEventCodec.playbackEvents(from: down, mode: .allEvents, source: source))
    #expect(fullMode.map(\.type) == [.leftMouseDown])
}
