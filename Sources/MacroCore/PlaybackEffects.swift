import Foundation

public enum PlaybackEffectStyle: String, Codable, CaseIterable, Sendable { case soft, vivid }

public struct PlaybackEffectSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var clicks = true
    public var movement = true
    public var scrolling = true
    public var style: PlaybackEffectStyle = .vivid
    public init() { }
}

/// Visual-only events cannot be posted as Quartz input. Previews use this type too.
public enum PlaybackEffectEvent: Equatable, Sendable {
    case movement(CGPoint, dragging: Bool)
    case click(CGPoint)
    case scroll(CGPoint, delta: CGPoint)

    public init?(_ action: MouseAction) {
        let point = CGPoint(x: action.x, y: action.y)
        switch action.kind {
        case .move, .drag: self = .movement(point, dragging: action.kind == .drag)
        case .down: self = .click(point)
        case .scroll:
            guard let scroll = action.scroll else { return nil }
            let vertical = scroll.continuous && scroll.pointVertical != 0 ? scroll.pointVertical : Double(scroll.vertical)
            let horizontal = scroll.continuous && scroll.pointHorizontal != 0 ? scroll.pointHorizontal : Double(scroll.horizontal)
            self = .scroll(point, delta: CGPoint(x: -horizontal, y: -vertical))
        case .up: return nil
        }
    }
}

public struct PlaybackEffectPulse: Identifiable, Sendable {
    public enum Kind: Sendable { case click, scroll }
    public var id: UInt64
    public var kind: Kind
    public var point: CGPoint
    public var direction: CGPoint
    public var birth: TimeInterval
    public var lifetime: TimeInterval { kind == .click ? 1.05 : 0.9 }
}

public struct PlaybackTrailPoint: Sendable {
    public var point: CGPoint
    public var time: TimeInterval
    public var startsSegment: Bool
    public var dragging: Bool
}

public struct PlaybackEffectTimeline: Sendable {
    public static let trailLifetime = 0.8
    public static let maximumPulses = 24
    public static let maximumTrailPoints = 120
    public private(set) var pulses: [PlaybackEffectPulse] = []
    public private(set) var trail: [PlaybackTrailPoint] = []
    public private(set) var head: PlaybackTrailPoint?
    private var anchor: CGPoint?
    private var lastTime: TimeInterval = 0
    private var lastScroll: TimeInterval = -.infinity
    private var sequence: UInt64 = 0
    public init() { }
    public var isEmpty: Bool { pulses.isEmpty && trail.isEmpty && head == nil }

    public mutating func seedMovement(_ point: CGPoint) {
        if Self.valid(point) { anchor = point }
    }
    public mutating func clear() { self = Self() }
    public mutating func prune(at time: TimeInterval) {
        guard time.isFinite else { return }
        pulses.removeAll { time - $0.birth >= $0.lifetime }
        trail.removeAll { time - $0.time >= Self.trailLifetime }
        if let head, time - head.time >= Self.trailLifetime { self.head = nil }
    }

    @discardableResult
    public mutating func record(_ event: PlaybackEffectEvent, at time: TimeInterval, settings: PlaybackEffectSettings) -> Bool {
        guard settings.enabled, time.isFinite, time >= lastTime else { return false }
        switch event {
        case let .movement(point, dragging):
            guard settings.movement, Self.valid(point) else { return false }
            prune(at: time); lastTime = time
            head = PlaybackTrailPoint(point: point, time: time, startsSegment: false, dragging: dragging)
            var seeded = false
            if trail.isEmpty, let anchor, anchor != point {
                trail.append(PlaybackTrailPoint(point: anchor, time: time - 1 / 120, startsSegment: true, dragging: dragging))
                seeded = true
            }
            let previous = trail.last
            anchor = point
            if let previous, !seeded, time - previous.time < 1 / 120 { return true }
            if let previous, !seeded, hypot(point.x - previous.point.x, point.y - previous.point.y) < 0.5, time - previous.time < 0.04 { return true }
            trail.append(PlaybackTrailPoint(point: point, time: time,
                startsSegment: previous == nil || time - previous!.time > 0.22, dragging: dragging))
            if trail.count > Self.maximumTrailPoints { trail.removeFirst(trail.count - Self.maximumTrailPoints) }
        case let .click(point):
            guard settings.clicks, Self.valid(point) else { return false }
            prune(at: time); lastTime = time; sequence &+= 1
            pulses.append(PlaybackEffectPulse(id: sequence, kind: .click, point: point, direction: .zero, birth: time))
        case let .scroll(point, delta):
            guard settings.scrolling, Self.valid(point), delta.x.isFinite, delta.y.isFinite else { return false }
            let length = hypot(delta.x, delta.y)
            guard length.isFinite, length > 0, time - lastScroll >= 0.075 else { return false }
            prune(at: time); lastTime = time; lastScroll = time; sequence &+= 1
            pulses.append(PlaybackEffectPulse(id: sequence, kind: .scroll, point: point,
                direction: CGPoint(x: delta.x / length, y: delta.y / length), birth: time))
        }
        if pulses.count > Self.maximumPulses { pulses.removeFirst(pulses.count - Self.maximumPulses) }
        return true
    }
    private static func valid(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && abs(point.x) <= 100_000 && abs(point.y) <= 100_000
    }
}

public struct PlaybackEffectDemo: Sendable {
    public static let duration = 3.3
    public var rect: CGRect
    private var lastTime = -1.0
    private var lastScroll = -1.0
    public init(rect: CGRect) { self.rect = rect }
    public mutating func sample(at time: TimeInterval) -> [PlaybackEffectEvent] {
        guard time.isFinite, time >= 0, time >= lastTime, time <= Self.duration else { return [] }
        var result: [PlaybackEffectEvent] = []
        func position(_ progress: Double) -> CGPoint {
            CGPoint(x: rect.minX + progress * rect.width,
                y: rect.midY + sin(progress * .pi * 2) * rect.height * 0.28)
        }
        if time <= 1.4 { result.append(.movement(position(time / 1.4), dragging: false)) }
        for moment in [0.65, 1.4] where lastTime < moment && time >= moment { result.append(.click(position(moment / 1.4))) }
        if (1.85...2.45).contains(time), time - lastScroll >= 0.12 {
            result.append(.scroll(CGPoint(x: rect.midX + rect.width * 0.12, y: rect.midY), delta: CGPoint(x: 0, y: -1)))
            lastScroll = time
        }
        lastTime = time
        return result
    }
}
