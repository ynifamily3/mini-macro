import AppKit
import SwiftUI

struct CanvasWheelObserver: NSViewRepresentable {
    var enabled: Bool
    var pan: (CGSize) -> Void
    var zoom: (Double, CGPoint) -> Void
    func makeNSView(context: Context) -> CanvasWheelView { CanvasWheelView() }
    func updateNSView(_ view: CanvasWheelView, context: Context) { view.enabled = enabled; view.pan = pan; view.zoom = zoom }
    static func dismantleNSView(_ view: CanvasWheelView, coordinator: ()) { view.stop() }
}

final class CanvasWheelView: NSView {
    var enabled = true
    var pan: ((CGSize) -> Void)?
    var zoom: ((Double, CGPoint) -> Void)?
    private var monitor: Any?
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.enabled, !self.isHiddenOrHasHiddenAncestor, let window = self.window, event.window === window else { return false }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return false }
                if event.type == .magnify { self.zoom?(max(0.1, 1 + Double(event.magnification)), point) }
                else if !event.modifierFlags.intersection([.command, .option]).isEmpty {
                    self.zoom?(exp(Double(event.scrollingDeltaY) * 0.012), point)
                } else { self.pan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)) }
                return true
            }
            return handled ? nil : event
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
