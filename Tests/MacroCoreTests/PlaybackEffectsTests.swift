import Foundation
import MacroCore
import Testing

@Test func effectsMapOnlyVisibleMouseActionsAndPreserveScrollDirection() throws {
    #expect(PlaybackEffectEvent(MouseAction(time: 0, kind: .up, x: 3, y: 4)) == nil)
    #expect(PlaybackEffectEvent(MouseAction(time: 0, kind: .drag, x: 3, y: 4)) == .movement(CGPoint(x: 3, y: 4), dragging: true))
    let continuous = MouseAction(time: 0, kind: .scroll, x: 20, y: 30,
        scroll: ScrollData(vertical: 1, horizontal: -1, pointVertical: 4.5, pointHorizontal: -2.25, continuous: true))
    #expect(PlaybackEffectEvent(continuous) == .scroll(CGPoint(x: 20, y: 30), delta: CGPoint(x: 2.25, y: -4.5)))
    var line = continuous; line.scroll?.continuous = false
    #expect(PlaybackEffectEvent(line) == .scroll(CGPoint(x: 20, y: 30), delta: CGPoint(x: 1, y: -1)))
    line.scroll = nil; #expect(PlaybackEffectEvent(line) == nil)
}

@Test func effectsCannotActivateWhenMasterOrTheirTypeIsDisabled() {
    var timeline = PlaybackEffectTimeline(), settings = PlaybackEffectSettings()
    settings.enabled = false
    for event in [PlaybackEffectEvent.click(.zero), .movement(.zero, dragging: false), .scroll(.zero, delta: CGPoint(x: 0, y: 1))] {
        #expect({ !timeline.record(event, at: 1, settings: settings) }())
    }
    settings.enabled = true; settings.clicks = false; settings.movement = false; settings.scrolling = false
    #expect({ !timeline.record(.click(.zero), at: 1, settings: settings) }())
    #expect({ !timeline.record(.movement(.zero, dragging: false), at: 1, settings: settings) }())
    #expect({ !timeline.record(.scroll(.zero, delta: CGPoint(x: 0, y: 1)), at: 1, settings: settings) }())
    #expect(timeline.isEmpty)
}

@Test func effectsExpireWithoutMoreInputAndKeepOnlyBoundedWorkDuringBursts() {
    var timeline = PlaybackEffectTimeline(); let settings = PlaybackEffectSettings()
    for index in 0..<10_000 {
        let time = 1 + Double(index) / 100_000
        timeline.record(.click(.zero), at: time, settings: settings)
        timeline.record(.movement(CGPoint(x: index, y: index), dragging: false), at: time, settings: settings)
    }
    #expect(timeline.pulses.count == PlaybackEffectTimeline.maximumPulses)
    #expect(timeline.trail.count <= PlaybackEffectTimeline.maximumTrailPoints)
    #expect(timeline.trail.count < 20) // Input at 100 kHz cannot grow ribbon work at that rate.
    #expect(timeline.head?.point == CGPoint(x: 9_999, y: 9_999))
    timeline.prune(at: 3)
    #expect(timeline.isEmpty)
}

@Test func movementSeedsStayInvisibleAndLongPausesBreakTheTrail() {
    var timeline = PlaybackEffectTimeline(); let settings = PlaybackEffectSettings()
    timeline.seedMovement(CGPoint(x: -500, y: 100)); #expect(timeline.isEmpty)
    timeline.record(.movement(CGPoint(x: 200, y: 100), dragging: false), at: 1, settings: settings)
    #expect(timeline.trail.first?.point == CGPoint(x: -500, y: 100))
    #expect(timeline.trail.last?.startsSegment == false)
    timeline.record(.movement(CGPoint(x: 220, y: 100), dragging: true), at: 1.4, settings: settings)
    #expect(timeline.trail.last?.startsSegment == true)
    #expect(timeline.head?.dragging == true)
    timeline.clear(); #expect(timeline.isEmpty)
}

@Test func scrollPulsesAreNormalizedThrottledAndIgnoreZeroOrInvalidEvents() {
    var timeline = PlaybackEffectTimeline(); let settings = PlaybackEffectSettings()
    #expect({ timeline.record(.scroll(.zero, delta: CGPoint(x: 3, y: -4)), at: 1, settings: settings) }())
    #expect(timeline.pulses.last?.direction == CGPoint(x: 0.6, y: -0.8))
    #expect({ !timeline.record(.scroll(.zero, delta: CGPoint(x: 1, y: 0)), at: 1.01, settings: settings) }())
    #expect({ !timeline.record(.scroll(.zero, delta: .zero), at: 1.2, settings: settings) }())
    #expect({ !timeline.record(.click(CGPoint(x: Double.nan, y: 0)), at: 1.2, settings: settings) }())
    #expect({ !timeline.record(.click(.zero), at: .infinity, settings: settings) }())
    #expect({ !timeline.record(.click(.zero), at: 0.5, settings: settings) }())
    #expect(timeline.pulses.count == 1)
    #expect({ timeline.record(.scroll(.zero, delta: CGPoint(x: -1, y: 0)), at: 1.2, settings: settings) }())
}

@Test func effectPreviewProducesVisualClicksOnlyOnceAndEndsWithoutPostingInput() {
    var demo = PlaybackEffectDemo(rect: CGRect(x: 0, y: 0, width: 400, height: 200))
    var events: [PlaybackEffectEvent] = []
    for frame in 0...220 { events += demo.sample(at: Double(frame) / 60) }
    let clicks = events.filter { if case .click = $0 { return true }; return false }
    #expect(clicks.count == 2)
    #expect(events.contains { if case .scroll = $0 { return true }; return false })
    #expect(events.contains { if case .movement = $0 { return true }; return false })
    #expect({ demo.sample(at: 5).isEmpty }())
}

@Test func effectPreferencesRoundTripWithStyleAndTypeChoices() throws {
    var settings = PlaybackEffectSettings(); settings.style = .soft; settings.scrolling = false
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(PlaybackEffectSettings.self, from: data) == settings)
}
