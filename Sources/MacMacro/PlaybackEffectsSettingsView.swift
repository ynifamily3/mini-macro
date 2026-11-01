import AppKit
import MacroCore
import QuartzCore
import SwiftUI

struct PlaybackEffectsSettingsView: View {
    @EnvironmentObject var engine: MacroEngine
    private var unavailable: Bool { engine.phase.isBusy || engine.isPositionEditing }
    private var previewSettings: PlaybackEffectSettings {
        var settings = engine.effectsSettings
        if unavailable { settings.enabled = false }
        return settings
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("재생에 색을 더하세요").font(.title2.bold())
                    Text("매크로가 실행하는 동작에만 이펙트가 나타납니다.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("재생 이펙트", isOn: $engine.effectsSettings.enabled)
                    .toggleStyle(.switch).labelsHidden().accessibilityLabel("재생 이펙트 켜기")
            }
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.055, green: 0.065, blue: 0.105))
                EffectsDemoView(settings: previewSettings).clipShape(RoundedRectangle(cornerRadius: 16))
                Text(previewSettings.enabled ? "이동 → 클릭 → 스크롤" : "이펙트 꺼짐")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65)).padding(16)
            }
            .frame(height: 200).accessibilityLabel("재생 이펙트 애니메이션 미리보기")
            HStack {
                Text("스타일").font(.headline)
                Spacer()
                Picker("이펙트 스타일", selection: $engine.effectsSettings.style) {
                    Text("은은하게").tag(PlaybackEffectStyle.soft)
                    Text("화려하게").tag(PlaybackEffectStyle.vivid)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }.disabled(!engine.effectsSettings.enabled)
            VStack(spacing: 14) {
                effectRow("클릭", detail: "퍼져 나가는 별빛 파티클과 무지개 링", symbol: "sparkles", binding: $engine.effectsSettings.clicks)
                effectRow("이동 · 드래그", detail: "마우스 경로를 따라 흐르는 무지개 궤적", symbol: "rainbow", binding: $engine.effectsSettings.movement)
                effectRow("스크롤", detail: "방향을 보여주는 회전 링과 빛의 화살표", symbol: "arrow.up.and.down", binding: $engine.effectsSettings.scrolling)
            }.disabled(!engine.effectsSettings.enabled)
            HStack {
                Text("미리보기는 마우스를 움직이거나 클릭하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("화면에서 미리보기", systemImage: "play.rectangle") { engine.previewPlaybackEffects() }
                    .disabled(!engine.effectsSettings.enabled)
            }
        }
        .padding(26).frame(width: 570).disabled(unavailable)
    }
    private func effectRow(_ title: String, detail: String, symbol: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.purple).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

private struct EffectsDemoView: NSViewRepresentable {
    var settings: PlaybackEffectSettings
    func makeNSView(context: Context) -> EffectsDemoSurface { EffectsDemoSurface() }
    func updateNSView(_ view: EffectsDemoSurface, context: Context) { view.configure(settings) }
    static func dismantleNSView(_ view: EffectsDemoSurface, coordinator: ()) { view.shutdown() }
}

/// The embedded preview shares the real renderer and never invokes MacroEngine playback.
private final class EffectsDemoSurface: NSView {
    private let surface = PlaybackEffectsSurface(frame: .zero,
        transform: RecordingScreenTransform(screenFrame: .zero, primaryScreenTop: 0))
    private var settings = PlaybackEffectSettings()
    private var timeline = PlaybackEffectTimeline()
    private var demo = PlaybackEffectDemo(rect: .zero)
    private var startedAt = 0.0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    override init(frame: NSRect) {
        super.init(frame: frame); addSubview(surface)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            })
        }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        if surface.frame != bounds { surface.frame = bounds; reset() }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateActivity() }
    func configure(_ settings: PlaybackEffectSettings) {
        if self.settings != settings { self.settings = settings; reset() }
        updateActivity()
    }
    func shutdown() {
        timer?.invalidate(); timer = nil; surface.clear()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
    }
    private func reset() {
        timeline.clear(); surface.clear(); startedAt = CACurrentMediaTime()
        demo = PlaybackEffectDemo(rect: bounds.insetBy(dx: 65, dy: 35))
    }
    private func updateActivity() {
        let active = settings.enabled && window?.isVisible == true && window?.isMiniaturized == false
        if active, timer == nil {
            reset()
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        } else if !active { timer?.invalidate(); timer = nil; surface.clear() }
    }
    private func tick() {
        guard window?.isVisible == true, window?.isMiniaturized == false else { updateActivity(); return }
        let now = CACurrentMediaTime()
        if now - startedAt > PlaybackEffectDemo.duration + 0.7 { reset() }
        for event in demo.sample(at: now - startedAt) { timeline.record(event, at: now, settings: settings) }
        timeline.prune(at: now); surface.render(timeline, settings: settings, at: now)
    }
}
