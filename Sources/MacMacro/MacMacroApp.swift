import AppKit
import SwiftUI

@main
struct MacMacroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Mouse Macro", id: "main") {
            MainWorkspaceRoot(delegate: delegate)
        }
        .defaultSize(width: 820, height: 860)
        .windowResizability(.contentMinSize)
        .commands { MacroCommands(engine: delegate.engine) }
        Window("매크로 보관함", id: "library") {
            LibraryView().environmentObject(delegate.engine).environmentObject(delegate.store)
        }.defaultSize(width: 900, height: 640)
        Window("자동화 편집기", id: "automation") {
            AutomationEditorView().environmentObject(delegate.engine).environmentObject(delegate.store)
        }.defaultSize(width: 1_340, height: 850)
        Window("재생 이펙트", id: "effects") {
            PlaybackEffectsSettingsView().environmentObject(delegate.engine)
        }.windowResizability(.contentSize)
        MenuBarExtra("Mouse Macro", systemImage: "cursorarrow.motionlines") {
            MenuBarControls().environmentObject(delegate.engine)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = MacroEngine()
    let store = AutomationStore()
    var reopenMainWindow: (() -> Void)?

    override init() {
        super.init()
        engine.onRecordingSaved = { [weak store] recording in _ = store?.addRecording(recording) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) { engine.shutdown(); store.flush() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if engine.isPositionEditing { return false }
        if !flag {
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) { window.makeKeyAndOrderFront(nil) }
            else { reopenMainWindow?() }
        }
        return true
    }
}

private struct MainWorkspaceRoot: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) var openWindow
    var body: some View {
        ContentView().environmentObject(delegate.engine).environmentObject(delegate.store)
            .onAppear { delegate.reopenMainWindow = { openWindow(id: "main") } }
    }
}

private struct MenuBarControls: View {
    @EnvironmentObject var engine: MacroEngine
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Text(engine.status)
        Divider()
        Button("녹화 시작", action: engine.prepareRecording).disabled(engine.phase.isBusy || !engine.listenAllowed)
        Button("반복 재생", action: engine.preparePlayback)
            .disabled(engine.phase.isBusy || engine.recording == nil || !engine.listenAllowed || !engine.postAllowed)
        Button("중지") { engine.stop() }.disabled(!engine.phase.isBusy)
        Divider()
        Button("창 열기") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("매크로 보관함") { openWindow(id: "library") }
        Button("자동화 편집기") { openWindow(id: "automation") }
        Button("재생 이펙트") { openWindow(id: "effects") }
        Button("종료") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

private struct MacroCommands: Commands {
    let engine: MacroEngine
    @Environment(\.openWindow) var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
        CommandMenu("매크로") {
            Button("녹화 시작", action: engine.prepareRecording).keyboardShortcut("r", modifiers: [.command, .shift])
            Button("반복 재생", action: engine.preparePlayback).keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("매크로 보관함") { openWindow(id: "library") }
            Button("자동화 편집기") { openWindow(id: "automation") }
            Button("재생 이펙트") { openWindow(id: "effects") }
            Divider()
            Button("중지") { engine.stop() }.keyboardShortcut(".", modifiers: .command)
        }
    }
}
