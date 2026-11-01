import Foundation

public enum RecordingStepKind: String, CaseIterable, Sendable {
    case click, move, wait, down, up, drag, scroll
}

public struct RecordingStep: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: RecordingStepKind
    public var x: Double = 0
    public var y: Double = 0
    public var button: UInt32 = 0
    public var clickCount: Int64 = 1
    /// Delay for wait rows, or press duration for a combined click.
    public var seconds: TimeInterval
    public var scroll = ScrollData(vertical: 0, horizontal: 0)

    public init(kind: RecordingStepKind) {
        self.kind = kind
        seconds = kind == .wait ? 1 : kind == .click ? 0.05 : 0
    }
}

public struct RecordingEdit: Equatable, Sendable {
    public var steps: [RecordingStep]
    public let createdAt: Date
    public let originalMode: RecordingMode

    public init(recording: MacroRecording) throws {
        _ = try recording.validated()
        createdAt = recording.createdAt; originalMode = recording.mode
        steps = []
        var previous: TimeInterval = 0
        var index = 0
        while index < recording.actions.count {
            let action = recording.actions[index]
            if action.time > previous {
                var wait = RecordingStep(kind: .wait); wait.seconds = action.time - previous; steps.append(wait)
            }
            let kind: RecordingStepKind
            switch action.kind {
            case .move: kind = .move
            case .down: kind = .down
            case .up: kind = .up
            case .drag: kind = .drag
            case .scroll: kind = .scroll
            }
            var step = RecordingStep(kind: kind)
            step.x = action.x; step.y = action.y; step.button = action.button; step.clickCount = action.clickCount
            if let scroll = action.scroll { step.scroll = scroll }
            previous = action.time
            // Group only an adjacent, stationary, matching press/release. Drags and
            // overlapping buttons retain every original event and its timing.
            if action.kind == .down, index + 1 < recording.actions.count {
                let up = recording.actions[index + 1]
                if up.kind == .up, up.button == action.button, up.x == action.x, up.y == action.y,
                   up.clickCount == action.clickCount {
                    step.kind = .click; step.seconds = up.time - action.time
                    previous = up.time; index += 1
                }
            }
            steps.append(step); index += 1
        }
        if recording.duration > previous {
            var wait = RecordingStep(kind: .wait); wait.seconds = recording.duration - previous; steps.append(wait)
        }
    }

    public init(createdAt: Date = Date()) {
        self.createdAt = createdAt; originalMode = .clicksOnly; steps = []
    }

    public var duration: TimeInterval { steps.reduce(0) { $0 + ([.wait, .click].contains($1.kind) ? $1.seconds : 0) } }

    public func recording() throws -> MacroRecording {
        guard steps.count <= MacroRecording.maxEvents * 2 + 64 else { throw AutomationError.invalid("편집 항목이 너무 많습니다.") }
        var time: TimeInterval = 0
        var actions: [MouseAction] = []
        var mode = originalMode
        for (index, step) in steps.enumerated() {
            if step.kind == .wait || step.kind == .click {
                guard step.seconds.isFinite, step.seconds >= 0, time + step.seconds <= MacroRecording.maxDuration + 1 else {
                    throw AutomationError.invalid("\(index + 1)번 항목의 시간을 확인해주세요. 시간은 0 이상, 전체 길이는 30분 이내여야 합니다.")
                }
            }
            if step.kind == .wait { time += step.seconds; continue }
            let kind: MouseActionKind
            switch step.kind {
            case .click, .down: kind = .down
            case .up: kind = .up
            case .move: kind = .move
            case .drag: kind = .drag
            case .scroll: kind = .scroll
            case .wait: continue
            }
            if [.move, .drag, .scroll].contains(kind) { mode = .allEvents }
            let action = MouseAction(time: time, kind: kind, x: step.x, y: step.y,
                button: step.button, clickCount: step.clickCount, scroll: kind == .scroll ? step.scroll : nil)
            actions.append(action)
            if step.kind == .click {
                time += step.seconds
                var up = action; up.kind = .up; up.time = time; actions.append(up)
            }
            guard actions.count <= MacroRecording.maxEvents + 32 else { throw AutomationError.invalid("마우스 이벤트가 너무 많습니다.") }
        }
        guard !actions.isEmpty else { throw AutomationError.invalid("클릭이나 이동 같은 마우스 동작을 하나 이상 추가해주세요.") }
        return try MacroRecording(duration: max(0.001, time), actions: actions, createdAt: createdAt, mode: mode).validated()
    }
}
