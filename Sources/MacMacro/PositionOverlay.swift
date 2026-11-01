import AppKit
import Combine
import MacroCore
import os

@MainActor
final class PositionOverlay: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isShowing = false
    private(set) var edit = RecordingEdit()
    private var initial = RecordingEdit()
    private(set) var positionIndices: [Int] = []
    private(set) var markerIndices: [Int] = []
    private(set) var pathIndices: [Int] = []
    private(set) var selectedIndex = 0
    private(set) var shade = 0.16
    private var primaryTop = 0.0
    private var panels: [NSPanel] = []
    private var canvases: [PositionCanvas] = []
    private var controls: NSPanel?
    private var hiddenWindows: [NSWindow] = []
    private var hiddenWindowStates: [ObjectIdentifier: (opacity: CGFloat, ignoresMouse: Bool)] = [:]
    private var previouslyKey: NSWindow?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var completion: ((RecordingEdit?, UUID?) -> Void)?
    private var undoPositions: [[CGPoint]] = []
    private var dragPointer: CGPoint?
    private var dragOrigin: CGPoint?
    private var draggingAll = false
    private var canvasFocused = false
    private let logger = Logger(subsystem: "ing.miel.mousemacro", category: "PositionOverlay")
    private let rowField = NSTextField(string: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let moveAll = NSButton(checkboxWithTitle: "전체 경로 함께 이동", target: nil, action: nil)
    private let undoButton = NSButton(title: "되돌리기", target: nil, action: nil)

    func present(edit: RecordingEdit, selected: UUID?, completion: @escaping (RecordingEdit?, UUID?) -> Void) throws {
        guard !isShowing else { throw AutomationError.invalid("화면 배치가 이미 열려 있습니다.") }
        guard let primary = NSScreen.screens.first else { throw AutomationError.invalid("연결된 화면을 찾을 수 없습니다.") }
        self.edit = edit; initial = edit; positionIndices = edit.positionIndices
        guard !positionIndices.isEmpty else { throw AutomationError.invalid("화면에 배치할 클릭이나 이동 항목을 먼저 추가해주세요.") }
        selectedIndex = selected.flatMap { id in positionIndices.first { edit.steps[$0].id == id } } ?? positionIndices[0]
        primaryTop = primary.frame.maxY; self.completion = completion
        undoPositions = []; dragPointer = nil; moveAll.state = .off; canvasFocused = false
        // Hide only our own windows; the target apps remain live beneath the layer.
        previouslyKey = NSApp.windows.first { $0.isSheet && $0.isVisible } ?? NSApp.keyWindow
        hiddenWindows = NSApp.orderedWindows.filter { $0.isVisible && $0.level.rawValue < NSWindow.Level.statusBar.rawValue }
        hiddenWindowStates = [:]
        for window in hiddenWindows {
            hiddenWindowStates[ObjectIdentifier(window)] = (window.alphaValue, window.ignoresMouseEvents)
            // Ordering out a SwiftUI sheet can dismiss its draft. Keep it attached
            // while making both the parent and sheet invisible and noninteractive.
            window.alphaValue = 0; window.ignoresMouseEvents = true
        }
        isShowing = true
        rebuildSamples()
        for screen in NSScreen.screens {
            let panel = PositionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.title = "화면 배치 레이어 · \(screen.localizedName)"
            panel.acceptsMain = true
            panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.ignoresMouseEvents = false; panel.hidesOnDeactivate = false
            panel.worksWhenModal = true; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let canvas = PositionCanvas(frame: NSRect(origin: .zero, size: screen.frame.size), overlay: self,
                transform: RecordingScreenTransform(screenFrame: screen.frame, primaryScreenTop: primaryTop))
            panel.contentView = canvas; panels.append(panel); canvases.append(canvas)
            panel.orderFrontRegardless(); panel.makeFirstResponder(canvas)
        }
        showControls(on: NSScreen.main ?? primary)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        let center = NotificationCenter.default
        for notification in [NSApplication.didChangeScreenParametersNotification, NSApplication.didResignActiveNotification,
                             NSApplication.didBecomeActiveNotification, NSApplication.willTerminateNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, self.isShowing else { return }
                    if note.name == NSApplication.didResignActiveNotification {
                        // Let the user adjust the target app, then resume without losing the draft.
                        self.endDrag()
                        for panel in self.panels { panel.orderOut(nil) }
                        self.controls?.orderOut(nil)
                    } else if note.name == NSApplication.didBecomeActiveNotification {
                        for panel in self.panels { panel.orderFrontRegardless() }
                        self.controls?.orderFrontRegardless()
                        if self.canvasFocused { self.focusCanvas() }
                        else { self.controls?.makeKeyAndOrderFront(nil); self.controls?.makeFirstResponder(nil) }
                    } else {
                        self.finish(apply: false, activate: false, restore: note.name != NSApplication.willTerminateNotification, reason: note.name.rawValue)
                    }
                }
            })
        }
        NSApp.activate(ignoringOtherApps: true)
        controls?.makeKeyAndOrderFront(nil)
        controls?.makeFirstResponder(nil)
        refresh()
    }

    func cancel() { finish(apply: false, reason: "cancel") }
    func editorDidDisappear() {
        // Hiding a parent window must not dismiss its still-attached sheet.
        if isShowing, previouslyKey?.sheetParent == nil { finish(apply: false, reason: "editor detached") }
    }

    private func showControls(on screen: NSScreen) {
        let panel = PositionPanel(contentRect: NSRect(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.maxY - 265, width: 470, height: 222),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "화면에서 배치 · Mouse Macro"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua); panel.delegate = self
        let material = NSVisualEffectView(); material.material = .hudWindow; material.blendingMode = .behindWindow; material.state = .active
        panel.contentView = material
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; material.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: material.topAnchor, constant: 14)])
        rowField.placeholderString = "항목 번호"; rowField.alignment = .right; rowField.stringValue = "\(selectedIndex + 1)"
        rowField.target = self; rowField.action = #selector(selectRow)
        rowField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let previous = button("이전 ◀", #selector(previousPoint)), next = button("다음 ▶", #selector(nextPoint))
        stack.addArrangedSubview(row([NSTextField(labelWithString: "선택"), rowField, NSTextField(labelWithString: "번 항목"), previous, next, button("화면 보기", #selector(focusCanvas))]))
        locationLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium); stack.addArrangedSubview(locationLabel)
        let opacity = NSSlider(value: shade, minValue: 0.04, maxValue: 0.45, target: self, action: #selector(changeShade))
        opacity.widthAnchor.constraint(equalToConstant: 92).isActive = true
        stack.addArrangedSubview(row([moveAll, OverlaySpacer(), NSTextField(labelWithString: "배경"), opacity]))
        hintLabel.stringValue = "마커 드래그 · 빈 곳 클릭 · 방향키 미세 이동(Shift: 10)\n적용 후 편집기에서 저장하세요. 아래 앱에는 입력되지 않습니다."
        hintLabel.font = .systemFont(ofSize: 10); hintLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hintLabel)
        undoButton.target = self; undoButton.action = #selector(undoMove)
        let cancel = button("취소 Esc", #selector(cancelAction)), apply = button("적용 ↵", #selector(applyAction))
        apply.bezelColor = .systemIndigo
        stack.addArrangedSubview(row([undoButton, button("원래 위치", #selector(resetPositions)), OverlaySpacer(), cancel, apply]))
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        controls = panel
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func row(_ views: [NSView]) -> NSStackView { let row = NSStackView(views: views); row.spacing = 8; row.alignment = .centerY; return row }
    private func snapshot() -> [CGPoint] { positionIndices.map { CGPoint(x: edit.steps[$0].x, y: edit.steps[$0].y) } }
    private func remember() {
        undoPositions.append(snapshot())
        let limit = max(1, min(30, 2_000_000 / positionIndices.count))
        if undoPositions.count > limit { undoPositions.removeFirst() }
    }
    private func rebuildSamples() {
        let count = positionIndices.count
        let stride = max(1, (count + 299) / 300)
        let important = positionIndices.filter { ![.move, .drag].contains(edit.steps[$0].kind) }.prefix(1_500)
        markerIndices = Array(Set(important).union(positionIndices.enumerated().filter { $0.offset % stride == 0 }.map(\.element)).union([selectedIndex])).sorted()
        let pathStride = max(1, (count + 3_999) / 4_000)
        pathIndices = Array(Set(positionIndices.enumerated().filter { $0.offset % pathStride == 0 }.map(\.element)).union(markerIndices).union([positionIndices.last!])).sorted()
    }
    private func refresh() {
        let step = edit.steps[selectedIndex]
        if rowField.currentEditor() == nil { rowField.stringValue = "\(selectedIndex + 1)" }
        let visible = canvases.contains { $0.bounds.contains($0.transform.localPoint(CGPoint(x: step.x, y: step.y))) }
        locationLabel.stringValue = "\(step.kind.positionLabel) · X \(step.x.formatted(.number.precision(.fractionLength(0...1))))  Y \(step.y.formatted(.number.precision(.fractionLength(0...1))))\(visible ? "" : " · 화면 밖")"
        undoButton.isEnabled = !undoPositions.isEmpty
        for canvas in canvases { canvas.needsDisplay = true }
    }
    func point(_ index: Int) -> CGPoint { CGPoint(x: edit.steps[index].x, y: edit.steps[index].y) }
    func select(_ index: Int) { selectedIndex = index; rebuildSamples(); refresh() }

    func beginDrag(at global: CGPoint, hit: Int?) {
        canvasFocused = true
        if let hit { select(hit) }
        remember(); draggingAll = moveAll.state == .on
        dragPointer = global; dragOrigin = point(selectedIndex)
        if hit == nil { move(to: global); dragOrigin = point(selectedIndex) }
    }
    func drag(to global: CGPoint) {
        guard let start = dragPointer, let origin = dragOrigin else { return }
        move(to: CGPoint(x: origin.x + global.x - start.x, y: origin.y + global.y - start.y))
    }
    func endDrag() { dragPointer = nil; dragOrigin = nil }
    private func move(to point: CGPoint) {
        // Keep the pointer's destination on a connected screen, including layouts
        // with negative origins and gaps between displays.
        let rects = canvases.map { canvas in CGRect(origin: canvas.transform.globalPoint(.zero), size: canvas.bounds.size) }
        let target: CGPoint
        if rects.contains(where: { $0.contains(point) }) { target = point }
        else {
            target = rects.map { rect in CGPoint(x: min(rect.maxX - 0.01, max(rect.minX, point.x)), y: min(rect.maxY - 0.01, max(rect.minY, point.y))) }
                .min(by: { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }) ?? point
        }
        do { try edit.reposition(edit.steps[selectedIndex].id, to: target, entirePath: draggingAll) }
        catch { NSSound.beep() }
        refresh()
    }

    @objc private func previousPoint() { advance(-1) }
    @objc private func nextPoint() { advance(1) }
    @objc private func focusCanvas() {
        canvasFocused = true
        let canvas = canvases.first { $0.bounds.contains($0.transform.localPoint(point(selectedIndex))) } ?? canvases.first
        canvas?.window?.makeKeyAndOrderFront(nil); canvas?.window?.makeMain(); canvas?.window?.makeFirstResponder(canvas)
    }
    private func advance(_ delta: Int) {
        guard let offset = positionIndices.firstIndex(of: selectedIndex) else { return }
        select(positionIndices[(offset + delta + positionIndices.count) % positionIndices.count])
    }
    @objc private func selectRow() {
        guard let value = Int(rowField.stringValue), let index = positionIndices.first(where: { $0 >= value - 1 }) else { rowField.stringValue = "\(selectedIndex + 1)"; return }
        controls?.makeFirstResponder(nil); select(index)
    }
    @objc private func changeShade(_ sender: NSSlider) { shade = sender.doubleValue; refresh() }
    @objc private func undoMove() {
        guard let positions = undoPositions.popLast() else { return }
        for (index, position) in zip(positionIndices, positions) { edit.steps[index].x = position.x; edit.steps[index].y = position.y }
        refresh()
    }
    @objc private func resetPositions() { remember(); edit = initial; refresh() }
    @objc private func applyAction() { finish(apply: true) }
    @objc private func cancelAction() { finish(apply: false) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard isShowing else { return false }
        if event.keyCode == 53 { cancel(); return true }
        if event.modifierFlags.contains(.command), event.keyCode == 12 || event.charactersIgnoringModifiers?.lowercased() == "q" { return false }
        if controls?.firstResponder is NSTextView { return false }
        if [36, 76].contains(event.keyCode) { applyAction(); return true }
        if event.keyCode == 48 { advance(event.modifierFlags.contains(.shift) ? -1 : 1); return true }
        if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift), event.keyCode == 6 || event.charactersIgnoringModifiers?.lowercased() == "z" { undoMove(); return true }
        if (123...126).contains(event.keyCode) {
            remember(); draggingAll = moveAll.state == .on
            let amount = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
            var point = point(selectedIndex)
            switch event.keyCode { case 123: point.x -= amount; case 124: point.x += amount; case 125: point.y += amount; default: point.y -= amount }
            move(to: point); return true
        }
        return event.modifierFlags.contains(.command) // Keep playback shortcuts out of placement mode.
    }

    private func finish(apply: Bool, activate: Bool = true, restore: Bool = true, reason: String = "action") {
        guard isShowing else { return }; isShowing = false
        logger.info("Placement closed: apply=\(apply) reason=\(reason, privacy: .public)")
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
        for panel in panels { panel.orderOut(nil); panel.close() }
        controls?.orderOut(nil); controls?.close(); controls = nil; panels = []; canvases = []
        if restore {
            for window in hiddenWindows.reversed() {
                if let state = hiddenWindowStates[ObjectIdentifier(window)] {
                    window.alphaValue = state.opacity; window.ignoresMouseEvents = state.ignoresMouse
                }
                if activate, window.isVisible { window.orderFront(nil) }
            }
            if activate {
                NSApp.activate(ignoringOtherApps: true)
                if previouslyKey?.isVisible == true { previouslyKey?.makeKeyAndOrderFront(nil) }
            }
        }
        hiddenWindows = []; hiddenWindowStates = [:]; previouslyKey = nil
        let callback = completion; completion = nil
        callback?(apply ? edit : nil, apply ? edit.steps[selectedIndex].id : nil)
        undoPositions = []; dragPointer = nil
    }
}

private final class OverlaySpacer: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }
    override init(frame: NSRect) { super.init(frame: frame); setContentHuggingPriority(.defaultLow, for: .horizontal) }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class PositionPanel: NSPanel {
    var acceptsMain = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { acceptsMain }
}

private extension RecordingStepKind {
    var positionLabel: String { switch self { case .click: "클릭"; case .move: "이동"; case .wait: "시간 지연"; case .down: "버튼 누름"; case .up: "버튼 해제"; case .drag: "드래그"; case .scroll: "스크롤" } }
    var positionColor: NSColor { switch self { case .click: .systemIndigo; case .move: .systemTeal; case .down: .systemBlue; case .up: .systemGreen; case .drag: .systemOrange; default: .systemPurple } }
}

private final class PositionCanvas: NSView {
    weak var overlay: PositionOverlay?
    let transform: RecordingScreenTransform
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(frame: NSRect, overlay: PositionOverlay, transform: RecordingScreenTransform) {
        self.overlay = overlay; self.transform = transform; super.init(frame: frame)
        setAccessibilityRole(.group); setAccessibilityLabel("화면 배치 레이어. 마커를 드래그하거나 빈 곳을 클릭해 지점을 옮기세요.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        guard let overlay else { return }
        NSColor.black.withAlphaComponent(overlay.shade).setFill(); bounds.fill()
        let path = NSBezierPath(); path.lineWidth = 1.5; path.setLineDash([5, 5], count: 2, phase: 0)
        for (offset, index) in overlay.pathIndices.enumerated() {
            let point = transform.localPoint(overlay.point(index))
            if offset == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        NSColor.white.withAlphaComponent(0.65).setStroke(); path.stroke()
        for index in overlay.markerIndices where index != overlay.selectedIndex { marker(index, selected: false, overlay: overlay) }
        marker(overlay.selectedIndex, selected: true, overlay: overlay)
    }
    private func marker(_ index: Int, selected: Bool, overlay: PositionOverlay) {
        let point = transform.localPoint(overlay.point(index))
        guard bounds.insetBy(dx: -25, dy: -25).contains(point) else { return }
        let color = overlay.edit.steps[index].kind.positionColor
        let radius = selected ? 18.0 : 14.0
        let circle = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        NSColor.white.setFill(); circle.fill(); color.setStroke(); circle.lineWidth = selected ? 4 : 2.5; circle.stroke()
        let label = "\(index + 1)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: label.length > 3 ? 8 : 11, weight: .bold), .foregroundColor: color]
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attributes)
        if selected {
            let cross = NSBezierPath(); cross.lineWidth = 0.7
            cross.move(to: CGPoint(x: point.x, y: 0)); cross.line(to: CGPoint(x: point.x, y: bounds.height))
            cross.move(to: CGPoint(x: 0, y: point.y)); cross.line(to: CGPoint(x: bounds.width, y: point.y))
            NSColor.white.withAlphaComponent(0.25).setStroke(); cross.stroke()
            let caption = "\(index + 1)번 \(overlay.edit.steps[index].kind.positionLabel) · \(Int(overlay.point(index).x)), \(Int(overlay.point(index).y))" as NSString
            let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let textSize = caption.size(withAttributes: attr)
            let rect = CGRect(x: max(6, min(bounds.width - textSize.width - 22, point.x + 24)), y: max(6, min(bounds.height - 32, point.y - 40)), width: textSize.width + 16, height: 28)
            NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            caption.draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 6), withAttributes: attr)
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let overlay else { return }; window?.makeKey(); window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        let candidates = [overlay.selectedIndex] + overlay.markerIndices.reversed().filter { $0 != overlay.selectedIndex }
        let hit = candidates.first { index in let p = transform.localPoint(overlay.point(index)); return hypot(p.x - local.x, p.y - local.y) <= 22 }
        overlay.beginDrag(at: transform.globalPoint(local), hit: hit)
    }
    override func mouseDragged(with event: NSEvent) { overlay?.drag(to: transform.globalPoint(convert(event.locationInWindow, from: nil))) }
    override func mouseUp(with event: NSEvent) { overlay?.endDrag() }
    // Consume every mouse button and scroll event instead of forwarding to target apps.
    override func rightMouseDown(with event: NSEvent) { }
    override func rightMouseUp(with event: NSEvent) { }
    override func rightMouseDragged(with event: NSEvent) { }
    override func otherMouseDown(with event: NSEvent) { }
    override func otherMouseUp(with event: NSEvent) { }
    override func otherMouseDragged(with event: NSEvent) { }
    override func scrollWheel(with event: NSEvent) { }
}
