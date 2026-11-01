import AppKit
import MacroCore
import QuartzCore

/// Nonactivating, click-through panels. This object never creates input events.
@MainActor
final class PlaybackEffectsDisplay {
    private var settings = PlaybackEffectSettings()
    private var timeline = PlaybackEffectTimeline()
    private var panels: [NSPanel] = []
    private var views: [PlaybackEffectsSurface] = []
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var demo: PlaybackEffectDemo?
    private var demoStart = 0.0
    private var sessionActive = false

    func configure(_ settings: PlaybackEffectSettings) { self.settings = settings; stop() }
    func begin(anchor: CGPoint) {
        stop(); guard settings.enabled else { return }
        sessionActive = true; timeline.seedMovement(anchor); ensurePanels()
    }
    func finish() {
        sessionActive = false
        if timeline.isEmpty { stop() }
    }
    func posted(_ action: MouseAction, mode: RecordingMode) {
        guard settings.enabled else { return }
        let now = CACurrentMediaTime()
        var accepted = false
        if mode == .clicksOnly, action.kind == .down {
            accepted = timeline.record(.movement(CGPoint(x: action.x, y: action.y), dragging: false), at: now, settings: settings)
        }
        if let event = PlaybackEffectEvent(action), timeline.record(event, at: now, settings: settings) { accepted = true }
        guard accepted else { return }
        ensurePanels(); render(at: now); startTimer()
    }
    func preview() {
        stop(); guard settings.enabled, let screen = NSScreen.main, let primary = NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let center = RecordingScreenTransform(screenFrame: frame, primaryScreenTop: primary.frame.maxY).globalPoint(CGPoint(x: frame.width / 2, y: frame.height / 2))
        demo = PlaybackEffectDemo(rect: CGRect(x: center.x - 240, y: center.y - 110, width: 480, height: 220))
        demoStart = CACurrentMediaTime(); ensurePanels(); startTimer()
    }
    func stop() {
        timer?.invalidate(); timer = nil; demo = nil; sessionActive = false; timeline.clear()
        for view in views { view.clear() }
        for panel in panels { panel.orderOut(nil) }
    }
    func shutdown() {
        stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        for panel in panels { panel.close() }; panels = []; views = []
    }
    private func ensurePanels() {
        if panels.isEmpty, let primary = NSScreen.screens.first {
            for screen in NSScreen.screens {
                let panel = PlaybackEffectsPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "매크로 재생 이펙트"
                panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear
                panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                let view = PlaybackEffectsSurface(frame: NSRect(origin: .zero, size: screen.frame.size),
                    transform: RecordingScreenTransform(screenFrame: screen.frame, primaryScreenTop: primary.frame.maxY))
                panel.contentView = view; panels.append(panel); views.append(view)
            }
            if screenObserver == nil {
                screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.stop()
                        self?.panels.forEach { $0.close() }; self?.panels = []; self?.views = []
                    }
                }
            }
        }
        for panel in panels where !panel.isVisible { panel.orderFrontRegardless() }
    }
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func tick() {
        let now = CACurrentMediaTime()
        if var demo {
            let elapsed = now - demoStart
            for event in demo.sample(at: elapsed) { _ = timeline.record(event, at: now, settings: settings) }
            self.demo = elapsed <= PlaybackEffectDemo.duration ? demo : nil
        }
        timeline.prune(at: now)
        render(at: now)
        if timeline.isEmpty, demo == nil {
            timer?.invalidate(); timer = nil
            if !sessionActive { stop() }
        }
    }
    private func render(at time: TimeInterval) { for view in views { view.render(timeline, settings: settings, at: time) } }
}

private final class PlaybackEffectsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Core Animation animates particles/rings on the compositor. The timer updates
/// only a bounded ribbon and removes finished layers; there is no idle timer.
final class PlaybackEffectsSurface: NSView {
    var transform: RecordingScreenTransform
    private let root = CALayer()
    private let ribbon = CALayer()
    private let trailEmitter = CAEmitterLayer()
    private let head = CAShapeLayer()
    private var strips: [CAShapeLayer] = []
    private var pulseLayers: [UInt64: CALayer] = [:]
    private var currentStyle: PlaybackEffectStyle?
    private static let colors: [NSColor] = [.systemPink, .systemOrange, .systemYellow, .systemGreen, .systemCyan, .systemPurple]
    private static let sparkTexture = texture(star: true)
    private static let dotTexture = texture(star: false)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(frame: NSRect, transform: RecordingScreenTransform) {
        self.transform = transform; super.init(frame: frame)
        wantsLayer = true; layer = root; root.isGeometryFlipped = true; root.masksToBounds = true
        root.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
        ribbon.actions = ["sublayers": NSNull()]; root.addSublayer(ribbon)
        trailEmitter.renderMode = .additive; trailEmitter.emitterShape = .point
        trailEmitter.actions = ["emitterPosition": NSNull(), "birthRate": NSNull()]
        root.addSublayer(trailEmitter)
        head.path = CGPath(ellipseIn: CGRect(x: -4, y: -4, width: 8, height: 8), transform: nil)
        head.fillColor = NSColor.white.cgColor; head.shadowColor = NSColor.systemCyan.cgColor
        head.shadowOpacity = 1; head.shadowRadius = 10
        head.actions = ["position": NSNull(), "opacity": NSNull()]; root.addSublayer(head)
        head.opacity = 0
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(_ timeline: PlaybackEffectTimeline, settings: PlaybackEffectSettings, at time: TimeInterval) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = bounds; ribbon.frame = bounds; trailEmitter.frame = bounds
        if currentStyle != settings.style {
            currentStyle = settings.style
            trailEmitter.emitterCells = Self.cells(style: settings.style, trail: true, direction: nil)
        }
        let ids = Set(timeline.pulses.map(\.id))
        for id in Array(pulseLayers.keys) where !ids.contains(id) { pulseLayers.removeValue(forKey: id)?.removeFromSuperlayer() }
        for pulse in timeline.pulses where pulseLayers[pulse.id] == nil {
            let point = transform.localPoint(pulse.point)
            if bounds.insetBy(dx: -180, dy: -180).contains(point) {
                let node = makePulse(pulse, at: point, style: settings.style)
                root.addSublayer(node); pulseLayers[pulse.id] = node
            }
        }
        var points = timeline.trail
        if let latest = timeline.head, points.last?.point != latest.point { points.append(latest) }
        let stride = max(1, (points.count + 46) / 47)
        if stride > 1 { points = points.enumerated().filter { $0.offset % stride == 0 || $0.offset == points.count - 1 }.map(\.element) }
        let needed = max(0, points.count - 1) * Self.colors.count
        while strips.count < needed {
            let strip = CAShapeLayer(); strip.fillColor = nil; strip.lineCap = .round; strip.lineJoin = .round
            strip.shadowOpacity = 0.7; strip.shadowRadius = 4
            strip.actions = ["path": NSNull(), "opacity": NSNull(), "lineWidth": NSNull()]
            strips.append(strip); ribbon.addSublayer(strip)
        }
        for (index, strip) in strips.enumerated() {
            guard index < needed else { strip.opacity = 0; continue }
            let segment = index / 6, colorIndex = index % 6
            let a = transform.localPoint(points[segment].point), b = transform.localPoint(points[segment + 1].point)
            let length = max(0.001, hypot(b.x - a.x, b.y - a.y))
            let width = settings.style == .vivid ? 1.8 : 1.0
            let offset = (Double(colorIndex) - 2.5) * width
            let normal = CGPoint(x: -(b.y - a.y) / length * offset, y: (b.x - a.x) / length * offset)
            let path = CGMutablePath(); path.move(to: CGPoint(x: a.x + normal.x, y: a.y + normal.y)); path.addLine(to: CGPoint(x: b.x + normal.x, y: b.y + normal.y))
            let opacity = max(0, 1 - (time - points[segment + 1].time) / PlaybackEffectTimeline.trailLifetime)
            strip.path = path; strip.lineWidth = width; strip.strokeColor = Self.colors[colorIndex].cgColor
            strip.shadowColor = Self.colors[colorIndex].cgColor
            strip.opacity = points[segment + 1].startsSegment ? 0 : Float(opacity * opacity * (settings.style == .vivid ? 0.95 : 0.65))
        }
        if let latest = timeline.head, time - latest.time < 0.16 {
            let point = transform.localPoint(latest.point)
            trailEmitter.emitterPosition = point; trailEmitter.birthRate = 1
            head.position = point; head.opacity = settings.style == .vivid ? 1 : 0.6
        } else { trailEmitter.birthRate = 0; head.opacity = 0 }
        CATransaction.commit()
    }

    func clear() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for node in pulseLayers.values { node.removeAllAnimations(); node.removeFromSuperlayer() }; pulseLayers = [:]
        for strip in strips { strip.opacity = 0 }
        trailEmitter.birthRate = 0
        // Replacing cells also removes particles still alive in the emitter.
        trailEmitter.emitterCells = []; currentStyle = nil; head.opacity = 0
        CATransaction.commit()
    }

    private func makePulse(_ pulse: PlaybackEffectPulse, at point: CGPoint, style: PlaybackEffectStyle) -> CALayer {
        let node = CALayer(); node.bounds = CGRect(x: -160, y: -160, width: 320, height: 320); node.position = point
        node.actions = ["position": NSNull(), "opacity": NSNull()]
        let emitter = CAEmitterLayer(); emitter.bounds = node.bounds; emitter.position = .zero
        emitter.beginTime = CACurrentMediaTime()
        emitter.emitterPosition = .zero; emitter.emitterShape = .point; emitter.renderMode = .additive
        emitter.seed = UInt32(truncatingIfNeeded: pulse.id &* 7919)
        emitter.emitterCells = Self.cells(style: style, trail: false, direction: pulse.kind == .scroll ? pulse.direction : nil)
        node.addSublayer(emitter)
        let birth = CAKeyframeAnimation(keyPath: "birthRate"); birth.values = [1, 1, 0]; birth.keyTimes = [0, 0.9, 1]
        birth.duration = style == .vivid ? 0.045 : 0.035; birth.fillMode = .forwards; birth.isRemovedOnCompletion = false
        emitter.add(birth, forKey: "burst")
        let rings = style == .vivid ? 3 : 1
        for index in 0..<rings {
            let radius = pulse.kind == .click ? 62.0 + Double(index) * 18 : 35.0 + Double(index) * 12
            let gradient = CAGradientLayer(); gradient.type = .conic
            gradient.frame = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
            gradient.colors = (Self.colors + [Self.colors[0]]).map(\.cgColor)
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5); gradient.endPoint = CGPoint(x: 1, y: 1)
            let mask = CAShapeLayer(); mask.frame = gradient.bounds; mask.fillColor = nil
            mask.path = CGPath(ellipseIn: gradient.bounds.insetBy(dx: 5, dy: 5), transform: nil)
            mask.strokeColor = NSColor.white.cgColor; mask.lineWidth = style == .vivid ? 3.2 : 1.8
            if pulse.kind == .scroll { mask.lineDashPattern = [9, 5] }
            gradient.mask = mask; node.addSublayer(gradient)
            let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.12; scale.toValue = pulse.kind == .click ? 1.35 : 1.1
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = style == .vivid ? 1 : 0.65; fade.toValue = 0
            var animations: [CAAnimation] = [scale, fade]
            if pulse.kind == .scroll {
                let rotation = CABasicAnimation(keyPath: "transform.rotation.z"); rotation.fromValue = 0; rotation.toValue = Double.pi * 1.5
                animations.append(rotation)
            }
            let group = CAAnimationGroup(); group.animations = animations; group.duration = 0.72; group.beginTime = CACurrentMediaTime() + Double(index) * 0.055
            group.fillMode = .both; group.isRemovedOnCompletion = false
            gradient.add(group, forKey: "shockwave")
        }
        if pulse.kind == .scroll {
            for index in 0..<3 {
                let d = pulse.direction, n = CGPoint(x: -d.y, y: d.x)
                let arrow = CAShapeLayer(); arrow.fillColor = nil; arrow.lineWidth = 3; arrow.lineCap = .round; arrow.lineJoin = .round
                let path = CGMutablePath()
                path.move(to: CGPoint(x: -d.x * 9 + n.x * 8, y: -d.y * 9 + n.y * 8)); path.addLine(to: .zero)
                path.addLine(to: CGPoint(x: -d.x * 9 - n.x * 8, y: -d.y * 9 - n.y * 8))
                arrow.path = path; arrow.strokeColor = Self.colors[index * 2].cgColor
                arrow.shadowColor = arrow.strokeColor; arrow.shadowOpacity = 0.9; arrow.shadowRadius = 5
                let start = CGPoint(x: d.x * Double(index * 13), y: d.y * Double(index * 13)); arrow.position = start
                node.addSublayer(arrow)
                let travel = CABasicAnimation(keyPath: "position"); travel.fromValue = NSValue(point: start)
                travel.toValue = NSValue(point: CGPoint(x: start.x + d.x * 55, y: start.y + d.y * 55))
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
                let group = CAAnimationGroup(); group.animations = [travel, fade]; group.duration = 0.7
                group.fillMode = .forwards; group.isRemovedOnCompletion = false; arrow.add(group, forKey: "scroll")
            }
        } else {
            let flash = CAShapeLayer(); flash.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
            flash.fillColor = NSColor.white.cgColor; flash.shadowColor = NSColor.systemPink.cgColor; flash.shadowOpacity = 1; flash.shadowRadius = 16
            node.addSublayer(flash)
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.25
            fade.fillMode = .forwards; fade.isRemovedOnCompletion = false; flash.add(fade, forKey: "flash")
        }
        return node
    }

    private static func cells(style: PlaybackEffectStyle, trail: Bool, direction: CGPoint?) -> [CAEmitterCell] {
        colors.enumerated().flatMap { index, color in
            (0..<(trail ? 1 : 2)).map { variant in
                let cell = CAEmitterCell(); cell.contents = variant == 0 ? dotTexture : sparkTexture
                cell.color = color.cgColor
                cell.birthRate = trail ? (style == .vivid ? 18 : 6) : (style == .vivid ? 160 : 55)
                cell.lifetime = trail ? 0.45 : 0.8; cell.lifetimeRange = trail ? 0.1 : 0.12
                cell.velocity = trail ? 8 : direction == nil ? (style == .vivid ? 160 : 90) : 95
                cell.velocityRange = trail ? 14 : 65
                cell.emissionRange = direction == nil ? .pi * 2 : .pi * 0.65
                cell.emissionLongitude = direction.map { atan2($0.y, $0.x) } ?? Double(index) / 6 * .pi * 2
                cell.yAcceleration = trail ? 0 : direction == nil ? 75 : 0
                cell.scale = trail ? 0.18 : variant == 0 ? 0.3 : 0.48
                cell.scaleRange = 0.15; cell.scaleSpeed = -0.18
                cell.alphaSpeed = trail ? -2.2 : -1.2
                cell.spin = variant == 0 ? 0 : 2; cell.spinRange = variant == 0 ? 0 : 6
                return cell
            }
        }
    }
    private static func texture(star: Bool) -> CGImage {
        let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.6).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.25, 1])!
        context.drawRadialGradient(gradient, startCenter: CGPoint(x: 20, y: 20), startRadius: 0, endCenter: CGPoint(x: 20, y: 20), endRadius: 20, options: [])
        if star {
            context.setFillColor(NSColor.white.cgColor); context.move(to: CGPoint(x: 20, y: 3))
            for index in 1..<8 {
                let angle = Double(index) * .pi / 4 - .pi / 2, radius = index % 2 == 0 ? 17.0 : 4.0
                context.addLine(to: CGPoint(x: 20 + cos(angle) * radius, y: 20 + sin(angle) * radius))
            }
            context.closePath(); context.fillPath()
        }
        return context.makeImage()!
    }
}
