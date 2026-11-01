import AppKit
import SwiftUI

@MainActor
final class StatusHUD {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(title: String, detail: String, symbol: String, color: Color, dismissAfter: Double? = nil) {
        dismissTask?.cancel()
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 76),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            self.panel = panel
        }
        panel?.contentView = NSHostingView(rootView: HUDView(title: title, detail: detail, symbol: symbol, color: color))
        // Keep the HUD stationary; do not follow the replaying cursor across screens.
        if panel?.isVisible != true, let screen = NSScreen.main {
            panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 180, y: screen.visibleFrame.maxY - 100))
        }
        panel?.orderFrontRegardless()
        if let delay = dismissAfter {
            dismissTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.hide()
            }
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }
}

private struct HUDView: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 27, weight: .medium)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).frame(width: 360, height: 76)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.25), lineWidth: 1))
    }
}
