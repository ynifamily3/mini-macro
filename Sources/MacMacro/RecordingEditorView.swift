import MacroCore
import SwiftUI

private extension RecordingStepKind {
    var label: String {
        switch self { case .click: "클릭"; case .move: "이동"; case .wait: "시간 지연"; case .down: "버튼 누름"; case .up: "버튼 해제"; case .drag: "드래그 이동"; case .scroll: "스크롤" }
    }
    var symbol: String {
        switch self { case .click: "cursorarrow.click"; case .move: "cursorarrow.motionlines"; case .wait: "clock"; case .down: "arrow.down.circle"; case .up: "arrow.up.circle"; case .drag: "hand.draw"; case .scroll: "arrow.up.and.down" }
    }
    var color: Color { self == .wait ? .orange : self == .click ? .indigo : .teal }
}

struct RecordingEditorView: View {
    let macroID: UUID
    @EnvironmentObject private var store: AutomationStore
    @EnvironmentObject private var engine: MacroEngine
    @Environment(\.dismiss) private var dismiss
    @State private var original: SavedMacro?
    @State private var edit = RecordingEdit()
    @State private var baseline = RecordingEdit()
    @State private var name = "새 매크로"
    @State private var baselineName = "새 매크로"
    @State private var selected: UUID?
    @State private var loaded = false
    @State private var discard = false
    @State private var error: String?
    @State private var saved = false
    @State private var validationMessage: String?
    @State private var totalDuration: TimeInterval = 0
    @State private var page = 0
    @StateObject private var positionOverlay = PositionOverlay()
    private let pageSize = 200

    private var dirty: Bool { name != baselineName || edit != baseline }
    private var selectedIndex: Int? { edit.steps.firstIndex { $0.id == selected } }
    private var visibleSteps: [(index: Int, step: RecordingStep)] {
        let start = min(edit.steps.count, page * pageSize)
        return (start..<min(edit.steps.count, start + pageSize)).map { ($0, edit.steps[$0]) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("녹화 동작 편집").font(.caption).foregroundStyle(.secondary)
                    TextField("매크로 이름", text: $name).textFieldStyle(.plain).font(.title3.bold())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(edit.steps.count)개 항목 · \(totalDuration.formatted(.number.precision(.fractionLength(0...3))))초").monospacedDigit()
                    Text(saved && !dirty ? "저장됨" : dirty ? "저장하지 않은 변경사항" : "좌표와 시간 간격을 편집하세요").foregroundStyle(.secondary)
                }.font(.caption)
            }.padding(20).disabled(engine.phase.isBusy)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        ForEach([RecordingStepKind.click, .move, .wait], id: \.self) { kind in
                            Button { add(kind) } label: { Label(kind.label, systemImage: kind.symbol) }
                        }
                        Menu("더 추가") {
                            ForEach([RecordingStepKind.down, .up, .drag, .scroll], id: \.self) { kind in Button(kind.label) { add(kind) } }
                        }.fixedSize()
                        Spacer()
                        Button("화면에서 배치", systemImage: "viewfinder") { placeOnScreen() }
                            .disabled(positionOverlay.isShowing || edit.positionIndices.isEmpty)
                    }.padding(12)
                    Divider()
                    List(selection: $selected) {
                        ForEach(visibleSteps, id: \.step.id) { index, step in
                            HStack(spacing: 12) {
                                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 36, alignment: .trailing)
                                Image(systemName: step.kind.symbol).foregroundStyle(step.kind.color).frame(width: 24)
                                Text(step.kind.label).font(.system(size: 12, weight: .semibold)).frame(width: 82, alignment: .leading)
                                Text(summary(step)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }.padding(.vertical, 7).contentShape(Rectangle()).tag(step.id)
                        }
                        .onMove { source, target in
                            edit.steps.move(fromOffsets: IndexSet(source.map { $0 + page * pageSize }), toOffset: target + page * pageSize); saved = false
                        }
                    }.listStyle(.inset)
                    HStack(spacing: 12) {
                        Button { move(-1) } label: { Image(systemName: "arrow.up") }.help("위로 이동").disabled(selectedIndex == nil || selectedIndex == 0)
                        Button { move(1) } label: { Image(systemName: "arrow.down") }.help("아래로 이동").disabled(selectedIndex == nil || selectedIndex == edit.steps.count - 1)
                        Button("복제") { duplicate() }.disabled(selectedIndex == nil)
                        Spacer()
                        if edit.steps.count > pageSize {
                            Button { page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                            Text("\(page + 1) / \((edit.steps.count + pageSize - 1) / pageSize)").font(.caption.monospacedDigit())
                            Button { page += 1 } label: { Image(systemName: "chevron.right") }.disabled((page + 1) * pageSize >= edit.steps.count)
                        }
                        Button("항목 삭제", systemImage: "trash", role: .destructive) { remove() }.disabled(selectedIndex == nil)
                    }.padding(12)
                }
                Divider()
                inspector.frame(width: 280)
            }.disabled(engine.phase.isBusy)
            Divider()
            HStack(spacing: 14) {
                Text(validationMessage ?? "저장하면 이 매크로를 사용하는 자동화에도 반영됩니다.")
                    .font(.caption).foregroundStyle(validationMessage == nil ? Color.secondary : .orange).lineLimit(2)
                Spacer()
                Button("닫기") { close() }.keyboardShortcut(.cancelAction)
                Button("저장") { save() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command).disabled(engine.phase.isBusy || validationMessage != nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(16)
        }
        .frame(minWidth: 940, idealWidth: 1_060, minHeight: 640, idealHeight: 740)
        .preferredColorScheme(.light)
        .interactiveDismissDisabled(dirty)
        .onAppear(perform: load)
        .onDisappear { positionOverlay.editorDidDisappear() }
        .onChange(of: edit) { _, _ in validate() }
        .confirmationDialog("저장하지 않은 변경사항을 버릴까요?", isPresented: $discard) {
            Button("변경사항 버리고 닫기", role: .destructive) { dismiss() }
            Button("계속 편집", role: .cancel) { }
        }
        .alert("저장할 수 없습니다", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("확인", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var inspector: some View {
        if let index = selectedIndex {
            let step = edit.steps[index]
            let binding = Binding<RecordingStep>(get: { edit.steps.first { $0.id == step.id } ?? step }, set: { value in
                guard let current = edit.steps.firstIndex(where: { $0.id == step.id }) else { return }
                edit.steps[current] = value
            })
            Form {
                Section("\(index + 1)번 항목") {
                    Picker("동작", selection: binding.kind) {
                        ForEach(RecordingStepKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                if step.kind == .wait {
                    Section("시간 지연") { number("대기 (초)", value: binding.seconds) }
                } else {
                    Section("화면 좌표") {
                        number("X", value: binding.x)
                        number("Y", value: binding.y)
                        Text("녹화할 때와 같은 화면 배치를 사용하세요.").font(.caption).foregroundStyle(.secondary)
                    }
                    if [.click, .down, .up, .drag].contains(step.kind) {
                        Section("마우스 버튼") {
                            Picker("버튼", selection: binding.button) {
                                Text("왼쪽").tag(UInt32(0)); Text("오른쪽").tag(UInt32(1)); Text("가운데").tag(UInt32(2))
                                ForEach(3..<32, id: \.self) { Text("버튼 \($0 + 1)").tag(UInt32($0)) }
                            }
                            Stepper("연속 클릭: \(step.clickCount)", value: binding.clickCount, in: 0...3)
                            if step.kind == .click { number("누르는 시간 (초)", value: binding.seconds) }
                        }
                    }
                    if step.kind == .scroll {
                        Section("스크롤") {
                            TextField("세로", value: binding.scroll.vertical, format: .number).textFieldStyle(.roundedBorder)
                            TextField("가로", value: binding.scroll.horizontal, format: .number).textFieldStyle(.roundedBorder)
                            if step.scroll.continuous {
                                number("세로 픽셀", value: binding.scroll.pointVertical)
                                number("가로 픽셀", value: binding.scroll.pointHorizontal)
                            }
                        }
                    }
                }
            }.formStyle(.grouped)
        } else {
            ContentUnavailableView("항목을 선택하세요", systemImage: "slider.horizontal.3",
                description: Text("클릭·이동·시간 지연을 추가하거나 목록의 항목을 선택해 수정하세요."))
        }
    }

    private func number(_ label: String, value: Binding<Double>) -> some View {
        RecordingNumberField(label: label, value: value).id("\(selected?.uuidString ?? "")-\(label)")
    }
    private func placeOnScreen() {
        guard engine.beginPositionEditing() else { return }
        do {
            try positionOverlay.present(edit: edit, selected: selected) { result, selectedID in
                engine.endPositionEditing()
                if let result {
                    edit = result; selected = selectedID; saved = false
                    if let index = selectedIndex { page = index / pageSize }
                }
            }
        } catch { engine.endPositionEditing(); self.error = error.localizedDescription }
    }
    private func summary(_ step: RecordingStep) -> String {
        if step.kind == .wait { return "\(step.seconds.formatted())초" }
        let position = "(\(step.x.formatted()), \(step.y.formatted()))"
        if step.kind == .click { return "\(position) · \(step.button == 0 ? "왼쪽" : step.button == 1 ? "오른쪽" : "버튼 \(step.button + 1)")" }
        if step.kind == .scroll { return "\(position) · 세로 \(step.scroll.vertical), 가로 \(step.scroll.horizontal)" }
        return position
    }
    private func load() {
        guard !loaded else { return }
        original = store.macros.first { $0.id == macroID }
        if let original {
            name = original.name
            do { edit = try RecordingEdit(recording: original.recording) } catch { self.error = error.localizedDescription }
        }
        baseline = edit; baselineName = name; selected = edit.steps.first?.id; loaded = true; validate()
    }
    private func validate() {
        totalDuration = edit.duration
        do { _ = try edit.recording(); validationMessage = nil } catch { validationMessage = error.localizedDescription }
        page = min(page, max(0, (edit.steps.count - 1) / pageSize))
    }
    private func add(_ kind: RecordingStepKind) {
        var step = RecordingStep(kind: kind)
        if let current = selectedIndex, edit.steps[current].kind != .wait { step.x = edit.steps[current].x; step.y = edit.steps[current].y }
        let index = selectedIndex.map { $0 + 1 } ?? edit.steps.count
        edit.steps.insert(step, at: index); selected = step.id; page = index / pageSize; saved = false
    }
    private func move(_ delta: Int) {
        guard let index = selectedIndex, edit.steps.indices.contains(index + delta) else { return }
        edit.steps.swapAt(index, index + delta); page = (index + delta) / pageSize; saved = false
    }
    private func duplicate() {
        guard let index = selectedIndex else { return }
        var step = edit.steps[index]; step.id = UUID()
        edit.steps.insert(step, at: index + 1); selected = step.id; page = (index + 1) / pageSize; saved = false
    }
    private func remove() {
        guard let index = selectedIndex else { return }
        edit.steps.remove(at: index)
        selected = edit.steps.isEmpty ? nil : edit.steps[min(index, edit.steps.count - 1)].id; saved = false
    }
    private func close() { if dirty { discard = true } else { dismiss() } }
    private func save() {
        guard !engine.phase.isBusy else { return }
        do {
            let recording: MacroRecording
            if let original, edit == baseline { recording = original.recording }
            else { recording = try edit.recording() }
            let item = try store.saveEditedMacro(SavedMacro(id: macroID, name: name, recording: recording), replacing: original)
            if engine.recording == original?.recording || engine.recording == nil { engine.selectRecording(recording) }
            original = item; name = item.name; baselineName = name; baseline = edit; saved = true
        } catch { self.error = error.localizedDescription }
    }
}

private struct RecordingNumberField: View {
    let label: String
    @Binding var value: Double
    @State private var text = ""
    var body: some View {
        TextField(label, text: $text).textFieldStyle(.roundedBorder)
            .onAppear { text = String(value) }
            .onChange(of: text) { _, raw in
                if let parsed = Double(raw), parsed.isFinite { value = parsed }
                else { value = .infinity }
            }
    }
}
