import MacroCore
import SwiftUI

private struct PaletteDrag {
    var kind: GraphNodeKind
    var point: CGPoint
}

private struct CanvasFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue(); if !next.isEmpty { value = next }
    }
}

struct AutomationEditorView: View {
    @EnvironmentObject var store: AutomationStore
    @EnvironmentObject var engine: MacroEngine
    @Environment(\.openWindow) var openWindow
    @State private var selectedWorkflow: UUID?
    @State private var selectedNode: UUID?
    @State private var selectedEdge: UUID?
    @State private var addRequest: GraphAddRequest?
    @State private var deleting = false
    @State private var showInspector = false
    @State private var showLog = false
    @State private var paletteDrag: PaletteDrag?
    @State private var canvasFrame = CGRect.zero

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 190)
                Divider()
                if let workflow = currentWorkflow, let graph = graphBinding(workflow.id) {
                    GraphCanvasView(graph: graph, selectedNode: $selectedNode, selectedEdge: $selectedEdge,
                                    workflowID: workflow.id, addRequest: addRequest, inspectSelection: { showInspector = true })
                        .id(workflow.id).frame(minWidth: 400)
                        .background(GeometryReader { proxy in Color.clear.preference(key: CanvasFrameKey.self, value: proxy.frame(in: .named("automationWorkspace"))) })
                        .overlay(Rectangle().stroke(paletteDrag.map { canvasFrame.contains($0.point) } == true ? Color.indigo : .clear, lineWidth: 3).allowsHitTesting(false))
                    if showInspector {
                        Divider()
                        GraphInspectorView(graph: graph, selectedNode: $selectedNode, selectedEdge: $selectedEdge).frame(width: 330)
                    }
                } else {
                    ContentUnavailableView("새 자동화를 만들어보세요", systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("왼쪽의 + 버튼으로 시작한 뒤 노드를 캔버스에 놓으세요."))
                        .frame(maxWidth: .infinity)
                }
            }
            .coordinateSpace(name: "automationWorkspace")
            .onPreferenceChange(CanvasFrameKey.self) { canvasFrame = $0 }
            .overlay(alignment: .topLeading) {
                if let drag = paletteDrag {
                    Label(drag.kind.label, systemImage: drag.kind.symbol)
                        .font(.system(size: 12, weight: .semibold)).padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(drag.kind.color))
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                        .position(drag.point).allowsHitTesting(false)
                }
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)
        .toolbar {
            Button("매크로 보관함", systemImage: "rectangle.stack") { openWindow(id: "library") }
            Button(engine.screenCaptureAllowed ? "화면 기록 설정" : "화면 기록 권한 허용", systemImage: "display", action: engine.requestScreenCapture)
                .disabled(engine.phase.isBusy)
        }
        .onAppear { if selectedWorkflow == nil { selectedWorkflow = store.workflows.first?.id } }
        .onChange(of: selectedWorkflow) { _, _ in selectedNode = nil; selectedEdge = nil; addRequest = nil; paletteDrag = nil }
        .onChange(of: engine.phase.isBusy) { _, busy in if busy { paletteDrag = nil } }
        .onChange(of: store.workflows.map(\.id)) { _, ids in
            if let selectedWorkflow, !ids.contains(selectedWorkflow) { self.selectedWorkflow = ids.first }
        }
        .confirmationDialog("이 자동화를 휴지통으로 옮길까요?", isPresented: $deleting) {
            Button("휴지통으로 이동", role: .destructive) {
                if let selectedWorkflow { store.deleteWorkflow(selectedWorkflow) }
            }
        }
        .modifier(WorkspaceAlerts())
        .frame(minWidth: 1_180, minHeight: 720)
    }

    private var currentWorkflow: AutomationWorkflow? { store.workflows.first { $0.id == selectedWorkflow } }
    private var readyMessage: String? {
        guard let workflow = currentWorkflow else { return nil }
        do { _ = try workflow.validated(availableMacros: Set(store.macros.map(\.id))); return nil }
        catch { return error.localizedDescription }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("노드로 연결하는 자동화").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                if let workflow = currentWorkflow {
                    TextField("자동화 이름", text: Binding(get: { currentWorkflow?.name ?? "" }, set: { name in
                        guard var value = store.workflows.first(where: { $0.id == workflow.id }) else { return }; value.name = name; store.update(value)
                    })).font(.system(size: 19, weight: .semibold)).textFieldStyle(.plain).disabled(engine.phase.isBusy)
                } else { Text("자동화 캔버스").font(.system(size: 19, weight: .semibold)) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let workflow = currentWorkflow {
                Stepper("전체 \(workflow.repetitions)회", value: Binding(get: { currentWorkflow?.repetitions ?? 1 }, set: { count in
                    guard var value = store.workflows.first(where: { $0.id == workflow.id }) else { return }; value.repetitions = count; store.update(value)
                }), in: 1...9_999).font(.caption).fixedSize().disabled(engine.phase.isBusy)
            }
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("설정 패널 표시")
            if engine.phase.isBusy {
                Button("전체 중지", systemImage: "stop.fill") { engine.stop() }.buttonStyle(.borderedProminent).tint(.orange)
            } else {
                Button("자동화 실행", systemImage: "play.fill") {
                    guard let currentWorkflow else { return }; store.flush(); engine.prepareAutomation(currentWorkflow, macros: store.macros)
                }.buttonStyle(.borderedProminent).disabled(currentWorkflow == nil)
            }
        }.padding(.horizontal, 20).padding(.vertical, 15)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("자동화").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { selectedWorkflow = store.createWorkflow() } label: { Image(systemName: "plus") }.help("새 자동화")
                Button { deleting = true } label: { Image(systemName: "trash") }.help("자동화 삭제").disabled(selectedWorkflow == nil)
            }.buttonStyle(.borderless).disabled(engine.phase.isBusy)
            Picker("자동화 선택", selection: $selectedWorkflow) {
                if store.workflows.isEmpty { Text("자동화 없음").tag(UUID?.none) }
                ForEach(store.workflows) { flow in Text(flow.name.isEmpty ? "이름 없는 자동화" : flow.name).tag(Optional(flow.id)) }
            }.labelsHidden().font(.caption).disabled(engine.phase.isBusy)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text("노드 추가").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(GraphNodeKind.allCases.filter { $0 != .start }, id: \.self) { kind in
                        paletteCard(kind.label, detail: kind == .finish ? "남은 반복까지 종료" : kind.explanation, symbol: kind.symbol, color: kind.color)
                            .contentShape(Rectangle())
                            .onTapGesture { addRequest = GraphAddRequest(kind: kind) }
                            .highPriorityGesture(paletteGesture(kind: kind))
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { addRequest = GraphAddRequest(kind: kind) }
                    }
                    Divider().padding(.vertical, 6)
                    HStack { Text("보관함 매크로").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary); Spacer(); Button { openWindow(id: "library") } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).help("보관함 열기") }
                    if store.macros.isEmpty { Text("녹화를 끝내면 여기에 나타납니다.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(store.macros) { item in
                        paletteCard(item.name, detail: "\(item.recording.clickCount)회 클릭 · \(MacroEngine.timeString(item.recording.duration))", symbol: "rectangle.stack", color: .indigo)
                            .contentShape(Rectangle())
                            .onTapGesture { addRequest = GraphAddRequest(kind: .macro, macroID: item.id) }
                            .highPriorityGesture(paletteGesture(kind: .macro, macroID: item.id))
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { addRequest = GraphAddRequest(kind: .macro, macroID: item.id) }
                    }
                }.disabled(currentWorkflow == nil || engine.phase.isBusy)
            }
            Text("클릭하거나 캔버스로 끌어 놓으세요.").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14).background(Color.white)
    }

    private func paletteGesture(kind: GraphNodeKind, macroID: UUID? = nil) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("automationWorkspace"))
            .onChanged { value in
                guard currentWorkflow != nil, !engine.phase.isBusy else { return }
                paletteDrag = PaletteDrag(kind: kind, point: value.location)
            }
            .onEnded { value in
                defer { paletteDrag = nil }
                guard currentWorkflow != nil, !engine.phase.isBusy, canvasFrame.contains(value.location) else { return }
                addRequest = GraphAddRequest(kind: kind, macroID: macroID,
                    canvasPoint: CGPoint(x: value.location.x - canvasFrame.minX, y: value.location.y - canvasFrame.minY))
            }
    }

    private func paletteCard(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(color).frame(width: 23, height: 25)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.1)))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { showLog.toggle() } label: { Label("실행 기록", systemImage: showLog ? "chevron.down" : "chevron.up") }.buttonStyle(.plain).font(.caption)
                Circle().fill(engine.isAutomationRunning ? Color.indigo : readyMessage == nil ? .green : .orange).frame(width: 6, height: 6)
                Text(engine.isAutomationRunning ? engine.status : readyMessage ?? "실행 준비됨 · 자동 저장")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("직접 입력하면 전체 중지").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if showLog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        if engine.automationLog.isEmpty { Text("실행하면 진행 과정이 표시됩니다.").foregroundStyle(.secondary) }
                        ForEach(Array(engine.automationLog.enumerated()), id: \.offset) { _, line in Text(line) }
                    }.font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(height: 90)
            }
        }.padding(.horizontal, 18).padding(.vertical, 11).background(.white)
    }

    private func graphBinding(_ id: UUID) -> Binding<AutomationGraph>? {
        guard store.workflows.first(where: { $0.id == id })?.graph != nil else { return nil }
        return Binding(get: { store.workflows.first(where: { $0.id == id })?.graph ?? AutomationGraph.draft() }, set: { graph in
            guard var workflow = store.workflows.first(where: { $0.id == id }) else { return }; workflow.graph = graph; store.update(workflow)
        })
    }
}
