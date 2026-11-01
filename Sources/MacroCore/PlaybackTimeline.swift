import Foundation

/// Absolute deadlines preserve recorded pauses without accumulating timer drift.
public struct PlaybackTimeline {
    public let recording: MacroRecording
    public let repetitions: Int
    public let gap: TimeInterval
    public private(set) var iteration = 0
    public private(set) var actionIndex = 0
    public private(set) var cancelled = false

    public init(recording: MacroRecording, repetitions: Int, gap: TimeInterval = 0.35) {
        self.recording = recording
        self.repetitions = max(1, min(9_999, repetitions))
        self.gap = max(0, gap)
    }

    public var totalDuration: TimeInterval {
        Double(repetitions) * recording.duration + Double(repetitions - 1) * gap
    }

    public var nextDeadline: TimeInterval? {
        guard !cancelled, iteration < repetitions else { return nil }
        let start = Double(iteration) * (recording.duration + gap)
        if actionIndex < recording.actions.count { return start + recording.actions[actionIndex].time }
        return start + recording.duration
    }

    /// A nil event represents an iteration's trailing recorded pause.
    public mutating func takeNext() -> MouseAction? {
        guard !cancelled, iteration < repetitions else { return nil }
        if actionIndex < recording.actions.count {
            defer { actionIndex += 1 }
            return recording.actions[actionIndex]
        }
        iteration += 1
        actionIndex = 0
        return nil
    }

    public mutating func cancel() { cancelled = true }
}
