import Foundation

/// The overlay uses logical points, just like recorded Quartz mouse coordinates.
/// AppKit screens have a bottom-left origin; the overlay view itself is flipped.
public struct RecordingScreenTransform: Equatable, Sendable {
    public var screenFrame: CGRect
    public var primaryScreenTop: Double
    public init(screenFrame: CGRect, primaryScreenTop: Double) {
        self.screenFrame = screenFrame; self.primaryScreenTop = primaryScreenTop
    }
    public func localPoint(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - screenFrame.minX, y: global.y - (primaryScreenTop - screenFrame.maxY))
    }
    public func globalPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + screenFrame.minX, y: local.y + primaryScreenTop - screenFrame.maxY)
    }
}

public extension RecordingEdit {
    var positionIndices: [Int] {
        steps.indices.filter { steps[$0].kind != .wait && steps[$0].x.isFinite && steps[$0].y.isFinite && abs(steps[$0].x) <= 100_000 && abs(steps[$0].y) <= 100_000 }
    }

    /// Move only coordinates. Timing, button order, scroll data and step IDs remain intact.
    mutating func reposition(_ id: UUID, to point: CGPoint, entirePath: Bool = false) throws {
        guard let index = steps.firstIndex(where: { $0.id == id }), steps[index].kind != .wait,
              point.x.isFinite, point.y.isFinite, abs(point.x) <= 100_000, abs(point.y) <= 100_000 else {
            throw AutomationError.invalid("이 지점의 화면 좌표를 변경할 수 없습니다.")
        }
        let old = CGPoint(x: steps[index].x, y: steps[index].y)
        guard old.x.isFinite, old.y.isFinite else { throw AutomationError.invalid("먼저 올바른 좌표를 입력해주세요.") }
        var indices = entirePath ? steps.indices.filter { steps[$0].kind != .wait } : [index]
        // Click-only recordings may contain overlapping raw button events. Move
        // their matching release/press too, so changing a position cannot invent a drag.
        if !entirePath, originalMode == .clicksOnly {
            if steps[index].kind == .down,
               let partner = steps.indices.dropFirst(index + 1).first(where: { steps[$0].kind == .up && steps[$0].button == steps[index].button }) { indices.append(partner) }
            if steps[index].kind == .up,
               let partner = steps.indices.prefix(index).last(where: { steps[$0].kind == .down && steps[$0].button == steps[index].button }) { indices.append(partner) }
        }
        let dx = point.x - old.x, dy = point.y - old.y
        for i in indices {
            let x = steps[i].x + dx, y = steps[i].y + dy
            guard x.isFinite, y.isFinite, abs(x) <= 100_000, abs(y) <= 100_000 else {
                throw AutomationError.invalid("전체 경로를 이동하면 일부 좌표가 허용 범위를 벗어납니다.")
            }
        }
        for i in indices { steps[i].x += dx; steps[i].y += dy }
    }
}
