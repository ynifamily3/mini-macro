import Foundation

public enum RecordingMode: String, Codable, CaseIterable, Sendable {
    case allEvents
    case clicksOnly
}

public enum MouseActionKind: String, Codable, Sendable {
    case move, down, up, drag, scroll
}

public struct MouseAction: Codable, Equatable, Sendable {
    public var time: TimeInterval
    public var kind: MouseActionKind
    public var x: Double
    public var y: Double
    public var button: UInt32
    public var clickCount: Int64
    public var scroll: ScrollData?

    public init(time: TimeInterval, kind: MouseActionKind, x: Double, y: Double,
                button: UInt32 = 0, clickCount: Int64 = 1, scroll: ScrollData? = nil) {
        self.time = time
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.clickCount = clickCount
        self.scroll = scroll
    }
}

public struct ScrollData: Codable, Equatable, Sendable {
    public var vertical: Int64
    public var horizontal: Int64
    public var pointVertical: Double
    public var pointHorizontal: Double
    public var fixedVertical: Double
    public var fixedHorizontal: Double
    public var continuous: Bool
    public var phase: Int64
    public var momentum: Int64

    public init(vertical: Int64, horizontal: Int64, pointVertical: Double = 0,
                pointHorizontal: Double = 0, fixedVertical: Double = 0,
                fixedHorizontal: Double = 0, continuous: Bool = false,
                phase: Int64 = 0, momentum: Int64 = 0) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.pointVertical = pointVertical
        self.pointHorizontal = pointHorizontal
        self.fixedVertical = fixedVertical
        self.fixedHorizontal = fixedHorizontal
        self.continuous = continuous
        self.phase = phase
        self.momentum = momentum
    }
}

public struct MacroRecording: Codable, Equatable, Sendable {
    public static let maxEvents = 200_000
    public static let maxDuration: TimeInterval = 1_800
    public var version: Int
    public var createdAt: Date
    public var duration: TimeInterval
    public var actions: [MouseAction]
    public var mode: RecordingMode

    public init(duration: TimeInterval, actions: [MouseAction], createdAt: Date = Date(), mode: RecordingMode = .allEvents) {
        self.version = 1
        self.createdAt = createdAt
        self.duration = duration
        self.actions = actions
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey { case version, createdAt, duration, actions, mode }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        actions = try values.decode([MouseAction].self, forKey: .actions)
        mode = try values.decodeIfPresent(RecordingMode.self, forKey: .mode) ?? .allEvents
    }

    public var clickCount: Int { actions.filter { $0.kind == .down }.count }
    public var moveCount: Int { actions.filter { $0.kind == .move || $0.kind == .drag }.count }
    public var scrollCount: Int { actions.filter { $0.kind == .scroll }.count }

    public func validated() throws -> Self {
        guard version == 1 else { throw RecordingError.unsupportedVersion }
        guard duration.isFinite, duration > 0, duration <= Self.maxDuration + 1,
              !actions.isEmpty, actions.count <= Self.maxEvents + 32 else {
            throw RecordingError.invalidRecording
        }
        var previous: TimeInterval = 0
        var held: [UInt32: MouseAction] = [:]
        for action in actions {
            guard action.time.isFinite, action.time >= previous, action.time <= duration,
                  action.x.isFinite, action.y.isFinite,
                  abs(action.x) <= 100_000, abs(action.y) <= 100_000,
                  action.button < 32, (0...3).contains(action.clickCount) else {
                throw RecordingError.invalidRecording
            }
            if mode == .clicksOnly, action.kind != .down && action.kind != .up {
                throw RecordingError.invalidRecording
            }
            if let scroll = action.scroll {
                guard action.kind == .scroll,
                      (-100_000...100_000).contains(scroll.vertical), (-100_000...100_000).contains(scroll.horizontal),
                      [scroll.pointVertical, scroll.pointHorizontal, scroll.fixedVertical,
                       scroll.fixedHorizontal].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
                      (0...255).contains(scroll.phase), (0...255).contains(scroll.momentum) else {
                    throw RecordingError.invalidRecording
                }
            } else if action.kind == .scroll {
                throw RecordingError.invalidRecording
            }
            switch action.kind {
            case .down:
                guard held[action.button] == nil else { throw RecordingError.unbalancedButtons }
                held[action.button] = action
            case .up:
                guard let down = held.removeValue(forKey: action.button) else { throw RecordingError.unbalancedButtons }
                if mode == .clicksOnly, action.x != down.x || action.y != down.y {
                    throw RecordingError.invalidRecording
                }
            case .drag:
                guard held[action.button] != nil else { throw RecordingError.unbalancedButtons }
            default: break
            }
            previous = action.time
        }
        guard held.isEmpty else { throw RecordingError.unbalancedButtons }
        return self
    }
}

public enum RecordingError: LocalizedError {
    case unsupportedVersion, invalidRecording, unbalancedButtons

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "지원하지 않는 녹화 파일 버전입니다."
        case .invalidRecording: return "녹화 파일의 시간 또는 마우스 데이터가 올바르지 않습니다."
        case .unbalancedButtons: return "마우스 버튼의 누름·해제 순서가 올바르지 않습니다."
        }
    }
}

/// Balances mouse buttons even when recording begins or ends during a drag.
public struct RecordingAccumulator {
    public let mode: RecordingMode
    public private(set) var actions: [MouseAction] = []
    public private(set) var clickCount = 0
    private var held: [UInt32: MouseAction] = [:]

    public init(x: Double, y: Double, mode: RecordingMode = .allEvents) {
        self.mode = mode
        if mode == .allEvents { actions = [MouseAction(time: 0, kind: .move, x: x, y: y)] }
    }

    public var eventCount: Int { actions.count - (mode == .allEvents ? 1 : 0) }
    public var hasRecordedActions: Bool { eventCount > 0 }

    public mutating func append(_ input: MouseAction) {
        guard actions.count < MacroRecording.maxEvents else { return }
        if mode == .clicksOnly, input.kind != .down && input.kind != .up { return }
        var action = input
        action.time = max(actions.last?.time ?? 0, action.time)
        switch action.kind {
        case .down:
            guard held[action.button] == nil else { return }
            held[action.button] = action
            clickCount += 1
        case .up:
            guard let down = held.removeValue(forKey: action.button) else { return }
            if mode == .clicksOnly { action.x = down.x; action.y = down.y }
        case .drag:
            if held[action.button] == nil { action.kind = .move }
        default: break
        }
        actions.append(action)
    }

    public func finish(at duration: TimeInterval) -> MacroRecording {
        var result = actions
        let end = max(0.001, duration, result.last?.time ?? 0)
        if let last = result.last {
            for button in held.keys.sorted() {
                let position = mode == .clicksOnly ? held[button]! : last
                result.append(MouseAction(time: end, kind: .up, x: position.x, y: position.y,
                                          button: button, clickCount: held[button]!.clickCount))
            }
        }
        return MacroRecording(duration: end, actions: result, mode: mode)
    }
}
