import MacroCore
import SwiftUI

struct WorkspaceAlerts: ViewModifier {
    @EnvironmentObject var engine: MacroEngine
    @EnvironmentObject var store: AutomationStore
    func body(content: Content) -> some View {
        content.alert("확인이 필요합니다", isPresented: Binding(
            get: { engine.error != nil || store.error != nil },
            set: { if !$0 { engine.error = nil; store.error = nil } }
        )) {
            Button("확인", role: .cancel) { engine.error = nil; store.error = nil }
        } message: { Text(engine.error ?? store.error ?? "") }
    }
}

struct LibraryView: View {
    @EnvironmentObject var store: AutomationStore
    @EnvironmentObject var engine: MacroEngine
    @Environment(\.openWindow) var openWindow
    @State private var selected: UUID?
    @State private var deleting: SavedMacro?

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                ForEach(store.macros) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name).font(.headline).lineLimit(1)
                        Text("\(item.recording.clickCount)회 클릭 · \(MacroEngine.timeString(item.recording.duration))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(item.id)
                }
            }
            .navigationTitle("매크로 보관함")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } label: { Label("새 녹화", systemImage: "record.circle") }
                    Spacer()
                    Button(action: engine.importRecording) { Image(systemName: "square.and.arrow.down") }.help("녹화 파일 가져오기")
                        .disabled(engine.phase.isBusy)
                }.padding(12)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250)
        } detail: {
            if let item = store.macros.first(where: { $0.id == selected }) {
                MacroLibraryDetail(item: item, deleting: { deleting = item }).id(item.id)
            } else {
                ContentUnavailableView("녹화한 매크로를 보관하세요", systemImage: "rectangle.stack",
                    description: Text("녹화를 끝내거나 파일을 가져오면 자동으로 추가됩니다."))
            }
        }
        .toolbar { Button("자동화 편집기") { openWindow(id: "automation") } }
        .onAppear { if selected == nil { selected = store.macros.first?.id } }
        .onChange(of: store.macros.map(\.id)) { _, ids in if selected == nil || !ids.contains(selected!) { selected = ids.first } }
        .confirmationDialog("매크로를 휴지통으로 옮길까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("휴지통으로 이동", role: .destructive) { if let deleting { store.deleteMacro(deleting.id) }; deleting = nil }
        }
        .modifier(WorkspaceAlerts())
        .frame(minWidth: 760, minHeight: 540)
    }
}

private struct MacroLibraryDetail: View {
    @EnvironmentObject var store: AutomationStore
    @EnvironmentObject var engine: MacroEngine
    @Environment(\.openWindow) var openWindow
    let item: SavedMacro
    let deleting: () -> Void
    @State private var name: String

    init(item: SavedMacro, deleting: @escaping () -> Void) {
        self.item = item; self.deleting = deleting; _name = State(initialValue: item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("저장된 매크로").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("매크로 이름", text: $name).font(.title2.bold()).textFieldStyle(.roundedBorder)
                    .onSubmit { store.renameMacro(item.id, name: name) }
                Button("이름 저장") { store.renameMacro(item.id, name: name) }
            }.disabled(engine.phase.isBusy)
            PathPreview(recording: item.recording, isRecording: false, mode: item.recording.mode).frame(height: 180)
            HStack(spacing: 24) {
                Label(item.recording.mode == .clicksOnly ? "클릭 위치만" : "전체 동작", systemImage: "computermouse")
                Text("\(item.recording.clickCount)회 클릭")
                Text(MacroEngine.timeString(item.recording.duration)).monospacedDigit()
            }.font(.subheadline).foregroundStyle(.secondary)
            Text("녹화: \(item.recording.createdAt.formatted())").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("녹화 화면에서 열기") { engine.selectRecording(item.recording); openWindow(id: "main") }
                Button("파일로 내보내기") { engine.selectRecording(item.recording); engine.exportRecording() }
                Spacer()
                Button(role: .destructive, action: deleting) { Image(systemName: "trash") }.help("휴지통으로 이동")
            }.disabled(engine.phase.isBusy)
            Spacer()
            Text("자동화 편집기에서 이 매크로를 여러 번 사용하거나 다른 매크로와 이어붙일 수 있습니다.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(28)
    }
}
