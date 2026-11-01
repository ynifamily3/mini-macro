import CoreGraphics
import Foundation

public enum MouseEventCodec {
    public static let allHardwareEvents: CGEventFilterMask = [
        .permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents
    ]
    // Keep playback and cleanup events distinguishable from incoming user input.
    public static let marker: Int64 = 0x4D_41_43_4D_41_43_52_4F
    public static let mouseTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
        .otherMouseDragged, .scrollWheel
    ]
    // Raw Quartz type 14 corresponds to NSEvent.systemDefined (media keys).
    public static let keyboardTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, CGEventType(rawValue: 14)!]

    public static func isOwnEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    public static func action(from event: CGEvent, time: TimeInterval) -> MouseAction? {
        let kind: MouseActionKind
        switch event.type {
        case .mouseMoved: kind = .move
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .up
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .drag
        case .scrollWheel: kind = .scroll
        default: return nil // Keyboard data is never retained.
        }
        let point = event.location
        let button: UInt32
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: button = 1
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            button = UInt32(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
        default: button = 0
        }
        let scroll: ScrollData? = kind == .scroll ? ScrollData(
            vertical: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            horizontal: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            pointVertical: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            pointHorizontal: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            fixedVertical: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixedHorizontal: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        ) : nil
        return MouseAction(time: time, kind: kind, x: point.x, y: point.y,
                           button: button, clickCount: min(3, max(0, event.getIntegerValueField(.mouseEventClickState))),
                           scroll: scroll)
    }

    public static func event(from action: MouseAction, source: CGEventSource) -> CGEvent? {
        let event: CGEvent?
        if action.kind == .scroll, let scroll = action.scroll {
            event = CGEvent(scrollWheelEvent2Source: source,
                            units: scroll.continuous ? .pixel : .line, wheelCount: 2,
                            wheel1: Int32(clamping: scroll.vertical),
                            wheel2: Int32(clamping: scroll.horizontal), wheel3: 0)
            // Pixel-unit initializers derive line deltas; restore all captured fields.
            event?.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: scroll.vertical)
            event?.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: scroll.horizontal)
            event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: scroll.continuous ? 1 : 0)
            event?.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: scroll.pointVertical)
            event?.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: scroll.pointHorizontal)
            event?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: scroll.fixedVertical)
            event?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: scroll.fixedHorizontal)
            event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: scroll.phase)
            event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: scroll.momentum)
        } else {
            let type: CGEventType
            switch (action.kind, action.button) {
            case (.move, _): type = .mouseMoved
            case (.down, 0): type = .leftMouseDown
            case (.down, 1): type = .rightMouseDown
            case (.down, _): type = .otherMouseDown
            case (.up, 0): type = .leftMouseUp
            case (.up, 1): type = .rightMouseUp
            case (.up, _): type = .otherMouseUp
            case (.drag, 0): type = .leftMouseDragged
            case (.drag, 1): type = .rightMouseDragged
            case (.drag, _): type = .otherMouseDragged
            default: return nil
            }
            guard let button = CGMouseButton(rawValue: action.button) else { return nil }
            event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: CGPoint(x: action.x, y: action.y), mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: action.clickCount)
        }
        event?.location = CGPoint(x: action.x, y: action.y)
        event?.flags = [] // This first version records no keyboard modifiers.
        event?.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    public static func playbackEvents(from action: MouseAction, mode: RecordingMode, source: CGEventSource) -> [CGEvent]? {
        guard let click = event(from: action, source: source) else { return nil }
        if mode == .clicksOnly, action.kind == .down {
            // Click-only files contain no path. Position the cursor at the click
            // before pressing; this generated jump is never added to the recording.
            let position = MouseAction(time: action.time, kind: .move, x: action.x, y: action.y)
            guard let jump = event(from: position, source: source) else { return nil }
            return [jump, click]
        }
        return [click]
    }

    public static func makeSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = marker
        source.localEventsSuppressionInterval = 0
        source.setLocalEventsFilterDuringSuppressionState(allHardwareEvents, state: .eventSuppressionStateSuppressionInterval)
        source.setLocalEventsFilterDuringSuppressionState(allHardwareEvents, state: .eventSuppressionStateRemoteMouseDrag)
        return source
    }
}
