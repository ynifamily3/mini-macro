import MacroCore
import SwiftUI

private let accent = Color(red: 0.34, green: 0.32, blue: 0.89)
private let ink = Color(red: 0.15, green: 0.16, blue: 0.22)

struct ContentView: View {
    @EnvironmentObject private var engine: MacroEngine
    @EnvironmentObject private var store: AutomationStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                permissions
                recordingCard
                playbackCard
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield").foregroundStyle(accent)
                    Text("마우스만 녹화합니다. 키보드 입력은 중지 감지에만 사용하며 저장하지 않습니다.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("LOCAL ONLY").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .padding(24)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.965, green: 0.965, blue: 0.98))
        .tint(accent)
        .preferredColorScheme(.light)
        .frame(minWidth: 740, minHeight: 740)
        .modifier(WorkspaceAlerts())
        .toolbar {
            Button("매크로 보관함", systemImage: "rectangle.stack") { openWindow(id: "library") }
            Button("자동화 편집기", systemImage: "arrow.triangle.branch") { openWindow(id: "automation") }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 13) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 27, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(accent.gradient, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mouse Macro").font(.system(size: 25, weight: .bold, design: .rounded)).foregroundStyle(ink)
                    Text("반복은 맡기고, 제어는 언제나 내 손에.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(engine.phase.isBusy ? accent : engine.listenAllowed && engine.postAllowed ? .green : .orange)
                    .frame(width: 6, height: 6)
                Text(phaseLabel).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white, in: Capsule())
        }
    }

    private var permissions: some View {
        HStack(spacing: 0) {
            permissionItem("입력 모니터링", detail: "녹화 · 입력 감지", allowed: engine.listenAllowed, action: engine.requestListening)
            Divider().frame(height: 34).padding(.horizontal, 16)
            permissionItem("손쉬운 사용", detail: "마우스 동작 재생", allowed: engine.postAllowed, action: engine.requestPosting)
            Divider().frame(height: 34).padding(.horizontal, 16)
            permissionItem("시스템 알림", detail: "선택 · 중지 결과 안내", allowed: engine.notificationsAllowed, action: engine.requestNotifications)
        }
        .padding(16)
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black.opacity(0.045)))
    }

    private func permissionItem(_ title: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(allowed ? Color.green : Color.orange).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink)
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 3)
            Button(allowed ? "설정" : "허용", action: action)
                .font(.system(size: 10, weight: .medium)).buttonStyle(.plain).foregroundStyle(accent)
                .disabled(engine.phase.isBusy)
        }.frame(maxWidth: .infinity)
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle(number: "01", title: "동작 녹화", subtitle: engine.recordingMode == .clicksOnly ? "클릭한 위치와 시간 간격만 저장" : "움직임, 클릭, 드래그, 스크롤을 그대로")
                Spacer()
                if engine.phase == .recording {
                    Button { engine.stop(reason: "녹화를 저장했습니다.") } label: {
                        Label("녹화 끝내기", systemImage: "stop.fill")
                    }.buttonStyle(ActionButtonStyle(color: .red))
                } else {
                    Button(action: engine.prepareRecording) {
                        Label(engine.recording == nil ? "녹화 시작" : "새로 녹화", systemImage: "record.circle")
                    }
                    .buttonStyle(ActionButtonStyle(color: accent))
                    .disabled(engine.phase.isBusy || !engine.listenAllowed)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
            HStack(spacing: 12) {
                Text("녹화 모드").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Picker("녹화 모드", selection: $engine.recordingMode) {
                    Text("전체 동작").tag(RecordingMode.allEvents)
                    Text("클릭 위치만").tag(RecordingMode.clicksOnly)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .frame(width: 202).disabled(engine.phase.isBusy)
                Text(engine.recordingMode == .clicksOnly ? "이동·드래그·스크롤은 저장하지 않아요." : "이동 경로와 모든 마우스 동작을 저장해요.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            PathPreview(recording: engine.recording, isRecording: engine.phase == .recording,
                        mode: engine.phase == .recording ? engine.recordingMode : engine.recording?.mode ?? engine.recordingMode)
                .equatable()
                .frame(height: 104)
            HStack(spacing: 12) {
                metric("녹화 시간", value: MacroEngine.timeString(engine.phase == .recording ? engine.elapsed : engine.recording?.duration ?? 0), unit: "", symbol: "clock")
                metric("마우스 클릭", value: "\(engine.phase == .recording ? engine.liveClickCount : engine.recording?.clickCount ?? 0)", unit: "회", symbol: "computermouse")
                metric("기록된 동작", value: "\(engine.phase == .recording ? engine.eventCount : engine.recording?.actions.count ?? 0)", unit: "개", symbol: "point.3.connected.trianglepath.dotted")
            }
            HStack {
                Image(systemName: "escape").font(.system(size: 11, weight: .medium))
                Text("녹화 종료 · 다른 앱에서도 Esc로 저장할 수 있어요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("동작 편집") {
                    guard let recording = engine.recording, let id = store.addRecording(recording) else { return }
                    store.recordingEditor = RecordingEditorRequest(id: id); openWindow(id: "library")
                }.disabled(engine.recording == nil || engine.phase.isBusy)
                Button("불러오기", action: engine.importRecording).disabled(engine.phase.isBusy)
                Text("·").foregroundStyle(.tertiary)
                Button("파일로 저장", action: engine.exportRecording).disabled(engine.recording == nil || engine.phase.isBusy)
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
        }
        .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.045)))
    }

    private var playbackCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                sectionTitle(number: "02", title: "반복 재생", subtitle: engine.recording?.mode == .clicksOnly ? "3초 뒤, 클릭한 좌표와 간격으로 재생합니다" : "3초 뒤, 원래 위치와 속도로 재생합니다")
                Spacer()
                HStack(spacing: 9) {
                    Text("반복").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("횟수", value: $engine.repetitions, format: .number.grouping(.never))
                        .textFieldStyle(.plain).multilineTextAlignment(.center)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .frame(width: 52).padding(.vertical, 9)
                        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityLabel("반복 횟수, 1부터 9999까지")
                        .onChange(of: engine.repetitions) { _, value in
                            engine.repetitions = min(9_999, max(1, value))
                        }
                        .disabled(engine.phase.isBusy)
                    Stepper("반복 횟수", value: $engine.repetitions, in: 1...9_999).labelsHidden()
                        .disabled(engine.phase.isBusy)
                    Text("회").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").foregroundStyle(accent).font(.system(size: 19))
                VStack(alignment: .leading, spacing: 5) {
                    Text("직접 조작하면, 즉시 멈춥니다.").font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
                    Text("재생 중 마우스를 움직이거나 버튼·키보드를 누르면 종료하고 알려드려요.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Toggle("재생 이펙트", isOn: $engine.effectsSettings.enabled)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                Spacer()
                Button("설정 · 미리보기", systemImage: "sparkles") { openWindow(id: "effects") }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(accent)
            }.disabled(engine.phase.isBusy || engine.isPositionEditing)

            if engine.phase == .playing {
                ProgressView(value: engine.progress).tint(accent)
                HStack {
                    Text(engine.isAutomationRunning ? "\(engine.automationName) · \(engine.iteration)회차" : "\(engine.iteration) / \(engine.repetitions)회 재생 중")
                    Spacer()
                    Text("\(Int(engine.progress * 100))%")
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                if engine.phase.isBusy {
                    Button { engine.stop() } label: {
                        Label("중지", systemImage: "stop.fill").frame(minWidth: 104)
                    }.buttonStyle(ActionButtonStyle(color: .orange))
                } else {
                    Button(action: engine.preparePlayback) {
                        Label("반복 재생", systemImage: "play.fill").frame(minWidth: 104)
                    }
                    .buttonStyle(ActionButtonStyle(color: accent))
                    .disabled(engine.recording == nil || !engine.listenAllowed || !engine.postAllowed)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    if let recording = engine.recording, !engine.phase.isBusy {
                        let total = Double(engine.repetitions) * recording.duration + Double(engine.repetitions - 1) * 0.35
                        Text("예상 \(MacroEngine.timeString(total)) · 반복 사이 0.35초")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.045)))
    }

    private func sectionTitle(number: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(accent).padding(.vertical, 5).padding(.horizontal, 6)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(ink)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, value: String, unit: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(accent.opacity(0.65)).font(.system(size: 17))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(ink)
                    Text(unit).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }.padding(10).frame(maxWidth: .infinity)
            .background(Color(red: 0.975, green: 0.975, blue: 0.985), in: RoundedRectangle(cornerRadius: 11))
    }

    private var phaseLabel: String {
        switch engine.phase {
        case .idle: return engine.listenAllowed && engine.postAllowed ? "준비됨" : "권한 필요"
        case .recording: return "녹화 중"
        case .playing: return engine.isAutomationRunning ? "자동화 실행 중" : "재생 중"
        case .countdown: return "시작 대기"
        }
    }
}

private struct ActionButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .foregroundStyle(enabled ? .white : Color.gray)
            .background(enabled ? color.opacity(configuration.isPressed ? 0.75 : 1) : Color.black.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct PathPreview: View, Equatable {
    let recording: MacroRecording?
    let isRecording: Bool
    let mode: RecordingMode

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13).fill(Color(red: 0.975, green: 0.977, blue: 0.991))
            Canvas { context, size in
                for x in stride(from: CGFloat(14), to: size.width, by: 20) {
                    for y in stride(from: CGFloat(14), to: size.height, by: 20) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(accent.opacity(0.12)))
                    }
                }
                guard let actions = recording?.actions, !actions.isEmpty, !isRecording else { return }
                let minX = actions.map(\.x).min()!, maxX = actions.map(\.x).max()!
                let minY = actions.map(\.y).min()!, maxY = actions.map(\.y).max()!
                let scale = min((size.width - 48) / max(1, maxX - minX), (size.height - 40) / max(1, maxY - minY))
                func point(_ action: MouseAction) -> CGPoint {
                    CGPoint(x: (size.width - (maxX - minX) * scale) / 2 + (action.x - minX) * scale,
                            y: (size.height - (maxY - minY) * scale) / 2 + (action.y - minY) * scale)
                }
                if mode == .allEvents {
                    var path = Path()
                    path.move(to: point(actions[0]))
                    let step = max(1, actions.count / 2_000)
                    for i in stride(from: 0, to: actions.count, by: step) { path.addLine(to: point(actions[i])) }
                    context.stroke(path, with: .color(accent.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                for action in actions.filter({ $0.kind == .down }).prefix(1_000) {
                    let p = point(action)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(accent))
                }
                let start = point(actions[0])
                context.fill(Path(ellipseIn: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8)), with: .color(.green))
            }
            if recording == nil || isRecording {
                VStack(spacing: 9) {
                    Image(systemName: mode == .clicksOnly ? "computermouse" : isRecording ? "waveform.path" : "cursorarrow.and.square.on.square.dashed")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(accent.opacity(0.6))
                    Text(isRecording ? (mode == .clicksOnly ? "클릭한 위치만 기록하고 있어요" : "마우스의 움직임을 기록하고 있어요") : (mode == .clicksOnly ? "클릭한 위치가 여기에 표시됩니다" : "녹화한 마우스 경로가 여기에 표시됩니다"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                VStack { HStack { Text(mode == .clicksOnly ? "CLICK POSITIONS" : "MOUSE PATH").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(accent.opacity(0.6)); Spacer() }; Spacer() }
                    .padding(13)
            }
        }.accessibilityLabel(mode == .clicksOnly ? "클릭 위치 미리보기" : "녹화한 마우스 경로 미리보기")
    }
}
