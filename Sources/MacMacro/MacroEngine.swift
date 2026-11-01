import AppKit
import ApplicationServices
import Combine
import MacroCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum MacroPhase: Equatable {
    case idle, countdown(recording: Bool, seconds: Int), recording, playing
    var isBusy: Bool { self != .idle }
}

@MainActor
final class MacroEngine: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var phase: MacroPhase = .idle
    @Published private(set) var isPositionEditing = false
    @Published private(set) var recording: MacroRecording?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var eventCount = 0
    @Published private(set) var liveClickCount = 0
    @Published private(set) var iteration = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var listenAllowed = false
    @Published private(set) var postAllowed = false
    @Published private(set) var notificationsAllowed = false
    @Published private(set) var screenCaptureAllowed = false
    @Published private(set) var isAutomationRunning = false
    @Published private(set) var automationName = ""
    @Published private(set) var automationLog: [String] = []
    @Published private(set) var runningWorkflowID: UUID?
    @Published private(set) var activeNodeID: UUID?
    @Published private(set) var completedNodeIDs = Set<UUID>()
    @Published private(set) var traversedEdgeIDs = Set<UUID>()
    @Published private(set) var interruptedNodeID: UUID?
    @Published private(set) var status = "마우스의 움직임을 담아보세요."
    @Published var repetitions = 3 {
        didSet { UserDefaults.standard.set(repetitions, forKey: "repetitionCount") }
    }
    @Published var error: String?
    @Published var recordingMode: RecordingMode = .allEvents {
        didSet { UserDefaults.standard.set(recordingMode.rawValue, forKey: "recordingMode") }
    }
    @Published var effectsSettings = PlaybackEffectSettings() {
        didSet {
            if let data = try? JSONEncoder().encode(effectsSettings) {
                UserDefaults.standard.set(data, forKey: "playbackEffects.v1")
            }
            effectsDisplay.configure(effectsSettings)
        }
    }

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var buffer: RecordingAccumulator?
    private var timeline: PlaybackTimeline?
    private var eventSource: CGEventSource?
    private var heldButtons = Set<UInt32>()
    private var startedAt: TimeInterval = 0
    private var playbackTimer: DispatchSourceTimer?
    private var refreshTimer: Timer?
    private var countdown: Task<Void, Never>?
    private let hud = StatusHUD()
    private let effectsDisplay = PlaybackEffectsDisplay()
    private var lastPermissionCheck: TimeInterval = 0
    private var sleepObservers: [NSObjectProtocol] = []
    private var isStopping = false
    private var automationTask: Task<Void, Never>?
    private var pendingAutomation: (AutomationWorkflow, [SavedMacro])?
    private var automationNeedsScreen = false
    var onRecordingSaved: ((MacroRecording) -> Void)?
    private let notificationCenter = UNUserNotificationCenter.current()
    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MouseMacro/last-recording.json")
    }

    override init() {
        super.init()
        if let saved = UserDefaults.standard.object(forKey: "repetitionCount") as? Int {
            repetitions = min(9_999, max(1, saved))
        }
        if let savedMode = UserDefaults.standard.string(forKey: "recordingMode"),
           let mode = RecordingMode(rawValue: savedMode) { recordingMode = mode }
        if let data = UserDefaults.standard.data(forKey: "playbackEffects.v1"),
           let settings = try? JSONDecoder().decode(PlaybackEffectSettings.self, from: data) { effectsSettings = settings }
        effectsDisplay.configure(effectsSettings)
        notificationCenter.delegate = self
        if let data = try? Data(contentsOf: cacheURL), data.count < 80_000_000,
           let loaded = try? JSONDecoder().decode(MacroRecording.self, from: data).validated() {
            recording = loaded
            status = "마지막 녹화를 불러왔습니다."
        }
        refreshPermissions()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop(reason: "화면 잠금 또는 잠자기로 매크로를 중지했습니다.", notify: true)
                }
            })
        }
    }

    func refreshPermissions() {
        listenAllowed = CGPreflightListenEventAccess()
        postAllowed = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        screenCaptureAllowed = CGPreflightScreenCaptureAccess()
        notificationCenter.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.notificationsAllowed = settings.authorizationStatus == .authorized
            }
        }
    }

    func requestListening() {
        _ = CGRequestListenEventAccess()
        openPrivacy("Privacy_ListenEvent")
        refreshPermissions()
    }

    func requestPosting() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
        refreshPermissions()
    }

    func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacy("Privacy_ScreenCapture")
        refreshPermissions()
    }

    func selectRecording(_ recording: MacroRecording) {
        guard !phase.isBusy else { return }
        self.recording = recording
        progress = 0
        persistRecording()
        status = "보관함의 매크로를 선택했습니다."
    }

    func prepareAutomation(_ workflow: AutomationWorkflow, macros: [SavedMacro]) {
        guard !phase.isBusy, !isPositionEditing else { return }
        refreshPermissions()
        do {
            _ = try workflow.validated(availableMacros: Set(macros.map(\.id)))
            guard listenAllowed, postAllowed else { throw AutomationError.invalid("입력 모니터링과 손쉬운 사용 권한을 먼저 허용해주세요.") }
            if workflow.usesImages, !screenCaptureAllowed { throw AutomationError.invalid("이미지 IF를 사용하려면 화면 기록 권한을 허용해주세요.") }
            let requiredMacros: Set<UUID>
            if let graph = workflow.graph {
                let reachable = graph.reachableIDs
                requiredMacros = Set(graph.nodes.filter { reachable.contains($0.id) && $0.kind == .macro }.compactMap { $0.step.macroID })
            } else { requiredMacros = workflow.referencedMacroIDs }
            for macro in macros where requiredMacros.contains(macro.id) {
                _ = try macro.recording.validated()
                try validateScreenCoordinates(macro.recording)
            }
            pendingAutomation = (workflow, macros)
            isAutomationRunning = true
            automationNeedsScreen = workflow.usesImages
            automationName = workflow.name
            automationLog = []
            runningWorkflowID = workflow.id
            activeNodeID = nil
            completedNodeIDs = []
            traversedEdgeIDs = []
            interruptedNodeID = nil
            beginCountdown(forRecording: false)
        } catch { self.error = error.localizedDescription }
    }

    private func validateScreenCoordinates(_ recording: MacroRecording) throws {
        guard recording.actions.allSatisfy({ action in
            NSScreen.screens.contains { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayBounds(number.uint32Value).insetBy(dx: -1, dy: -1).contains(CGPoint(x: action.x, y: action.y))
            }
        }) else { throw AutomationError.invalid("매크로 좌표가 현재 화면을 벗어납니다. 디스플레이 배치를 확인해주세요.") }
    }

    func requestNotifications() {
        Task {
            let settings = await notificationCenter.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await notificationCenter.requestAuthorization(options: [.alert, .sound])
                refreshPermissions()
            } else {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func openPrivacy(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)") {
            NSWorkspace.shared.open(url)
        }
    }

    func prepareRecording() {
        guard !phase.isBusy, !isPositionEditing else { return }
        refreshPermissions()
        guard listenAllowed else {
            error = "시스템 설정 → 개인정보 보호 및 보안 → 입력 모니터링에서 Mouse Macro를 허용해주세요."
            return
        }
        beginCountdown(forRecording: true)
    }

    func preparePlayback() {
        guard !phase.isBusy, !isPositionEditing, let recording else { return }
        refreshPermissions()
        guard listenAllowed, postAllowed else {
            error = "재생에는 입력 모니터링과 손쉬운 사용 권한이 모두 필요합니다. 입력 감지를 확인한 뒤에만 재생합니다."
            return
        }
        do { _ = try recording.validated() } catch { self.error = error.localizedDescription; return }
        guard recording.actions.allSatisfy({ action in
            NSScreen.screens.contains { screen in
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
                return CGDisplayBounds(id).insetBy(dx: -1, dy: -1).contains(CGPoint(x: action.x, y: action.y))
            }
        }) else {
            error = "녹화한 좌표 중 현재 화면을 벗어난 위치가 있습니다. 디스플레이 배치를 복원하거나 다시 녹화해주세요."
            return
        }
        repetitions = min(9_999, max(1, repetitions))
        beginCountdown(forRecording: false)
    }

    private func beginCountdown(forRecording: Bool) {
        effectsDisplay.stop()
        // Establish the complete keyboard + mouse listener before allowing playback.
        guard startMonitoring() else { pendingAutomation = nil; isAutomationRunning = false; automationNeedsScreen = false; return }
        elapsed = 0
        progress = 0
        iteration = 0
        phase = .countdown(recording: forRecording, seconds: 3)
        countdown = Task { [weak self] in
            for remaining in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.phase = .countdown(recording: forRecording, seconds: remaining)
                self.status = "\(remaining)초 후 \(forRecording ? "녹화를" : "재생을") 시작합니다."
                self.updateHUD()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.countdown = nil
            guard self.listenAllowed, forRecording || self.postAllowed,
                  let tap = self.tap, CGEvent.tapIsEnabled(tap: tap) else {
                self.stop(reason: "입력 감지 또는 권한을 확인할 수 없어 시작하지 않았습니다.", notify: true)
                return
            }
            self.startedAt = ProcessInfo.processInfo.systemUptime
            if forRecording {
                let point = CGEvent(source: nil)?.location ?? .zero
                self.buffer = RecordingAccumulator(x: point.x, y: point.y, mode: self.recordingMode)
                self.eventCount = 0
                self.liveClickCount = 0
                self.phase = .recording
                self.status = "\(self.recordingMode == .clicksOnly ? "클릭 위치만" : "전체 동작") 녹화 중 · Esc로 저장"
            } else {
                guard let source = MouseEventCodec.makeSource() else {
                    self.stop(reason: "재생 이벤트를 만들 수 없습니다.", notify: true)
                    return
                }
                self.eventSource = source
                self.effectsDisplay.begin(anchor: CGEvent(source: nil)?.location ?? .zero)
                if let (workflow, macros) = self.pendingAutomation {
                    self.pendingAutomation = nil
                    self.phase = .playing
                    self.iteration = 1
                    self.startAutomation(workflow, macros: macros)
                    self.updateHUD()
                    return
                }
                guard let recording = self.recording else { self.stop(); return }
                self.timeline = PlaybackTimeline(recording: recording, repetitions: self.repetitions)
                self.phase = .playing
                self.iteration = 1
                self.status = "재생 중 · 마우스나 키보드를 건드리면 멈춥니다."
                self.scheduleNext()
            }
            self.updateHUD()
        }
    }

    private func startMonitoring() -> Bool {
        stopMonitoring()
        let types = MouseEventCodec.mouseTypes + MouseEventCodec.keyboardTypes
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                let engine = Unmanaged<MacroEngine>.fromOpaque(info).takeUnretainedValue()
                engine.receive(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            error = "입력 감지를 시작할 수 없습니다. 입력 모니터링과 손쉬운 사용 권한을 확인하고 앱을 다시 실행해주세요."
            return false
        }
        tap = newTap
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    private func stopMonitoring() {
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tapSource = nil
        tap = nil
    }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop(reason: "입력 감지가 끊겨 안전하게 중지했습니다.", notify: true)
            return
        }
        guard !MouseEventCodec.isOwnEvent(event) else { return }
        if phase == .playing {
            let keyboard = MouseEventCodec.keyboardTypes.contains(type)
            stop(reason: "\(keyboard ? "키보드" : "마우스") 입력이 감지되어 매크로를 중지했습니다.", notify: true)
            return
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            stop(reason: phase == .recording ? "녹화를 저장했습니다." : "시작을 취소했습니다.")
            return
        }
        guard phase == .recording,
              let action = MouseEventCodec.action(from: event, time: ProcessInfo.processInfo.systemUptime - startedAt) else { return }
        // Clicks on our own controls are not part of a recorded macro.
        if action.kind == .down, isOwnControlClick(event) { return }
        buffer?.append(action)
        if (buffer?.actions.count ?? 0) >= MacroRecording.maxEvents {
            stop(reason: "녹화 이벤트 한도에 도달해 저장했습니다.", notify: true)
        }
    }

    private func isOwnControlClick(_ event: CGEvent) -> Bool {
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let targetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        if targetPID > 0 { return targetPID == ownPID }
        for field in [CGEventField.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                      .mouseEventWindowUnderMousePointer] {
            let number = event.getIntegerValueField(field)
            if number > 0 {
                return NSApp.windows.contains { $0.windowNumber == number && !$0.ignoresMouseEvents }
            }
        }
        // Session taps may arrive before target fields are annotated. Inspect the
        // frontmost window at the point, so an overlapping app still records clicks.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for window in windows {
            guard let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(event.location),
                  let owner = window[kCGWindowOwnerPID as String] as? Int else { continue }
            if owner == ownPID,
               let number = window[kCGWindowNumber as String] as? Int,
               NSApp.windows.contains(where: { $0.windowNumber == number && $0.ignoresMouseEvents }) { continue }
            return owner == ownPID
        }
        return false
    }

    private func scheduleNext() {
        guard phase == .playing, let deadline = timeline?.nextDeadline else {
            if phase == .playing { stop(reason: "\(repetitions)회 반복 재생을 완료했습니다.", notify: true, completed: true) }
            return
        }
        let delay = max(0, startedAt + deadline - ProcessInfo.processInfo.systemUptime)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + delay, leeway: .microseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.playNext() }
        }
        playbackTimer = timer
        timer.resume()
    }

    private func playNext() {
        playbackTimer?.cancel()
        playbackTimer = nil
        guard phase == .playing, let tap, CGEvent.tapIsEnabled(tap: tap),
              let source = eventSource else {
            stop(reason: "입력 감지를 확인할 수 없어 재생을 중지했습니다.", notify: true)
            return
        }
        if let action = timeline?.takeNext() {
            guard let events = MouseEventCodec.playbackEvents(from: action, mode: timeline?.recording.mode ?? .allEvents, source: source) else {
                stop(reason: "마우스 이벤트를 만들 수 없어 중지했습니다.", notify: true)
                return
            }
            if action.kind == .down { heldButtons.insert(action.button) }
            if action.kind == .up { heldButtons.remove(action.button) }
            for event in events { event.post(tap: .cghidEventTap) }
            effectsDisplay.posted(action, mode: timeline?.recording.mode ?? .allEvents)
        }
        let newIteration = min(repetitions, (timeline?.iteration ?? 0) + 1)
        if iteration != newIteration { iteration = newIteration }
        scheduleNext()
    }

    func stop(reason: String = "매크로를 중지했습니다.", notify: Bool = false, completed: Bool = false) {
        guard phase.isBusy, !isStopping else { return }
        isStopping = true
        if completed { effectsDisplay.finish() } else { effectsDisplay.stop() }
        let wasRecording = phase == .recording
        let wasAutomation = isAutomationRunning
        if wasAutomation, let activeNodeID {
            if completed { completedNodeIDs.insert(activeNodeID) }
            else { interruptedNodeID = activeNodeID }
        }
        activeNodeID = nil
        automationTask?.cancel()
        automationTask = nil
        pendingAutomation = nil
        isAutomationRunning = false
        automationNeedsScreen = false
        if wasRecording {
            eventCount = buffer?.eventCount ?? 0
            liveClickCount = buffer?.clickCount ?? 0
        }
        countdown?.cancel()
        countdown = nil
        playbackTimer?.cancel()
        playbackTimer = nil
        timeline?.cancel()
        if wasRecording, let buffer, buffer.hasRecordedActions {
            let result = buffer.finish(at: min(MacroRecording.maxDuration, ProcessInfo.processInfo.systemUptime - startedAt))
            do {
                recording = try result.validated()
                persistRecording()
                onRecordingSaved?(result)
            } catch { self.error = error.localizedDescription }
        }
        self.buffer = nil
        phase = .idle // Set idle before posting cleanup events.
        releaseButtons()
        stopMonitoring()
        timeline = nil
        eventSource = nil
        if completed { progress = 1; if !wasAutomation { iteration = repetitions } }
        if wasAutomation { appendAutomationLog(reason) }
        status = wasRecording && eventCount == 0 ? "기록된 동작이 없어 이전 녹화를 유지했습니다." : reason
        hud.show(title: completed ? "재생 완료" : wasRecording ? "녹화 완료" : "매크로 중지",
                 detail: status, symbol: completed ? "checkmark.circle.fill" : "stop.circle.fill",
                 color: completed ? .green : .orange, dismissAfter: 4)
        if notify { sendNotification(title: completed ? "반복 재생 완료" : "매크로 중지", body: reason) }
        isStopping = false
    }

    private func releaseButtons() {
        guard let source = eventSource else { heldButtons.removeAll(); return }
        let point = CGEvent(source: nil)?.location ?? .zero
        for button in heldButtons.sorted() {
            let action = MouseAction(time: 0, kind: .up, x: point.x, y: point.y, button: button)
            MouseEventCodec.event(from: action, source: source)?.post(tap: .cghidEventTap)
        }
        heldButtons.removeAll()
    }

    private func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPermissionCheck >= 1 {
            lastPermissionCheck = now
            refreshPermissions()
            if phase.isBusy, (!listenAllowed || (phase == .playing && !postAllowed)
                || (isAutomationRunning && automationNeedsScreen && !screenCaptureAllowed)) {
                stop(reason: "필요한 권한이 해제되어 매크로를 중지했습니다.", notify: true)
            }
        }
        if phase == .recording {
            elapsed = now - startedAt
            eventCount = buffer?.eventCount ?? 0
            liveClickCount = buffer?.clickCount ?? 0
            if elapsed >= MacroRecording.maxDuration {
                stop(reason: "최대 녹화 시간 30분에 도달해 저장했습니다.", notify: true)
            }
        } else if phase == .playing {
            elapsed = now - startedAt
            if !isAutomationRunning { progress = min(1, elapsed / max(0.001, timeline?.totalDuration ?? 1)) }
        }
        if phase.isBusy { updateHUD() }
    }

    private func updateHUD() {
        switch phase {
        case let .countdown(isRecording, seconds):
            hud.show(title: "\(seconds)초 후 \(isRecording ? "녹화" : "재생")", detail: "대상 화면으로 이동하세요 · Esc 취소",
                     symbol: "\(seconds).circle.fill", color: .indigo)
        case .recording:
            hud.show(title: "\(recordingMode == .clicksOnly ? "클릭 위치" : "마우스") 녹화 중 · \(Self.timeString(elapsed))", detail: "Esc를 누르면 녹화를 저장합니다",
                     symbol: "record.circle.fill", color: .red)
        case .playing:
            hud.show(title: isAutomationRunning ? automationName : "\(iteration) / \(repetitions)회 재생 중", detail: isAutomationRunning ? status : "마우스·키보드 입력 시 즉시 중지",
                     symbol: "play.circle.fill", color: .indigo)
        case .idle: break
        }
    }

    private func sendNotification(title: String, body: String) {
        guard notificationsAllowed else { NSSound.beep(); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        notificationCenter.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func persistRecording() {
        guard let recording else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recording).write(to: cacheURL, options: .atomic)
        } catch { self.error = "녹화 자동 저장에 실패했습니다: \(error.localizedDescription)" }
    }

    func exportRecording() {
        guard !phase.isBusy, let recording else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mouseMacro]
        panel.nameFieldStringValue = "마우스 녹화.mousemacro"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recording).write(to: url, options: .atomic)
            status = "녹화 파일을 저장했습니다."
        } catch { self.error = error.localizedDescription }
    }

    func importRecording() {
        guard !phase.isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mouseMacro, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < 80_000_000 else { throw RecordingError.invalidRecording }
            recording = try JSONDecoder().decode(MacroRecording.self, from: Data(contentsOf: url)).validated()
            progress = 0
            persistRecording()
            if let recording { onRecordingSaved?(recording) }
            status = "녹화 파일을 불러왔습니다."
        } catch { self.error = error.localizedDescription }
    }

    private func appendAutomationLog(_ message: String) {
        automationLog.append("\(Date().formatted(date: .omitted, time: .standard))  \(message)")
        if automationLog.count > 200 { automationLog.removeFirst(automationLog.count - 200) }
    }

    private func startAutomation(_ workflow: AutomationWorkflow, macros: [SavedMacro]) {
        let snapshot = Dictionary(uniqueKeysWithValues: macros.map { ($0.id, $0) })
        appendAutomationLog("‘\(workflow.name)’ 시작")
        automationTask = Task { [weak self] in
            guard let self else { return }
            let runner = AutomationExecutor(play: { id, count in
                guard let item = snapshot[id] else { throw AutomationError.invalid("매크로를 찾을 수 없습니다.") }
                self.appendAutomationLog("매크로 ‘\(item.name)’ · \(count)회")
                try await self.playAutomationMacro(item.recording, repetitions: count)
            }, detect: { condition in
                try await ScreenImageService.waitForImage(condition)
            }, click: { match in
                try self.requireAutomationSession()
                let down = MouseAction(time: 0, kind: .down, x: match.x + match.width / 2, y: match.y + match.height / 2)
                try self.postAutomationAction(down, mode: .clicksOnly)
                try await Task.sleep(for: .milliseconds(50))
                var up = down; up.kind = .up
                try self.postAutomationAction(up, mode: .clicksOnly)
            }, report: { message, iteration in
                self.status = message
                self.iteration = iteration
                self.progress = Double(iteration - 1) / Double(workflow.repetitions)
                self.appendAutomationLog(message)
                self.updateHUD()
            }, onNode: { id, newIteration in
                if self.iteration != newIteration {
                    self.completedNodeIDs = []
                    self.traversedEdgeIDs = []
                } else if let previous = self.activeNodeID { self.completedNodeIDs.insert(previous) }
                self.activeNodeID = id
            }, onEdge: { id in
                self.traversedEdgeIDs.insert(id)
            })
            do {
                try await runner.run(workflow, availableMacros: Set(snapshot.keys))
                try self.requireAutomationSession()
                self.automationTask = nil
                self.stop(reason: "‘\(workflow.name)’ 자동화를 완료했습니다.", notify: true, completed: true)
            } catch is CancellationError {
                // stop() already cancels the task and releases held buttons.
            } catch {
                guard !Task.isCancelled, self.isAutomationRunning else { return }
                self.error = error.localizedDescription
                self.automationTask = nil
                self.stop(reason: "자동화 중지: \(error.localizedDescription)", notify: true)
            }
        }
    }

    private func requireAutomationSession() throws {
        try Task.checkCancellation()
        guard phase == .playing, isAutomationRunning,
              let tap, CGEvent.tapIsEnabled(tap: tap), AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw AutomationError.invalid("입력 감지 또는 재생 권한을 확인할 수 없습니다.")
        }
    }

    private func postAutomationAction(_ action: MouseAction, mode: RecordingMode) throws {
        try requireAutomationSession()
        guard let source = eventSource,
              let events = MouseEventCodec.playbackEvents(from: action, mode: mode, source: source) else {
            throw AutomationError.invalid("재생할 마우스 이벤트를 만들 수 없습니다.")
        }
        if action.kind == .down { heldButtons.insert(action.button) }
        if action.kind == .up { heldButtons.remove(action.button) }
        for event in events { event.post(tap: .cghidEventTap) }
        effectsDisplay.posted(action, mode: mode)
    }

    private func playAutomationMacro(_ recording: MacroRecording, repetitions: Int) async throws {
        try validateScreenCoordinates(recording)
        var schedule = PlaybackTimeline(recording: recording, repetitions: repetitions)
        let start = ProcessInfo.processInfo.systemUptime
        while let deadline = schedule.nextDeadline {
            try requireAutomationSession()
            let delay = start + deadline - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            try requireAutomationSession()
            if let action = schedule.takeNext() { try postAutomationAction(action, mode: recording.mode) }
            await Task.yield() // Deliver pending real input even when replay has fallen behind.
        }
    }

    func beginPositionEditing() -> Bool {
        guard !phase.isBusy, !isPositionEditing else { return false }
        effectsDisplay.stop()
        isPositionEditing = true; return true
    }
    func endPositionEditing() { isPositionEditing = false }

    func previewPlaybackEffects() {
        guard !phase.isBusy, !isPositionEditing else { return }
        effectsDisplay.preview()
    }

    func shutdown() {
        stop()
        effectsDisplay.shutdown()
        refreshTimer?.invalidate()
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        hud.hide()
    }

    static func timeString(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
    }
}

extension UTType {
    static let mouseMacro = UTType(exportedAs: "ing.miel.mousemacro.recording", conformingTo: .json)
}
