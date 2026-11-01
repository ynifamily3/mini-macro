import MacroCore
import SwiftUI

struct GraphInspectorView: View {
    @Binding var graph: AutomationGraph
    @Binding var selectedNode: UUID?
    @Binding var selectedEdge: UUID?
    @EnvironmentObject var store: AutomationStore
    @EnvironmentObject var engine: MacroEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let id = selectedNode, let node = graph.nodes.first(where: { $0.id == id }) {
                    HStack {
                        Image(systemName: node.kind.symbol).foregroundStyle(node.kind.color)
                        Text(node.kind.label).font(.headline)
                        Spacer()
                    }
                    Text(node.kind.explanation).font(.caption).foregroundStyle(.secondary)
                    TextField("노드 이름 (선택)", text: Binding(get: { graph.nodes.first(where: { $0.id == id })?.title ?? "" }, set: { value in
                        guard let i = graph.nodes.firstIndex(where: { $0.id == id }) else { return }; graph.nodes[i].title = String(value.prefix(80))
                    })).textFieldStyle(.roundedBorder)
                    Divider()
                    controls(node)
                    if !node.kind.outlets.isEmpty {
                        Divider()
                        Text("출력 연결").font(.caption.weight(.semibold))
                        ForEach(node.kind.outlets, id: \.self) { outlet in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(outlet.label, systemImage: "arrow.right.circle.fill").foregroundStyle(outlet.color).font(.caption)
                                Picker("\(outlet.label) 대상", selection: targetBinding(id, outlet)) {
                                    Text("연결 안 됨").tag(UUID?.none)
                                    ForEach(graph.nodes.filter { $0.id != id && $0.kind != .start }) { target in
                                        Text(title(target)).tag(Optional(target.id))
                                    }
                                }.labelsHidden().font(.caption)
                            }
                        }
                    }
                    if node.kind != .start {
                        Divider()
                        Button("노드 삭제", systemImage: "trash", role: .destructive) {
                            graph.removeNode(id); selectedNode = nil; selectedEdge = nil
                        }
                    }
                } else if let id = selectedEdge, let edge = graph.edges.first(where: { $0.id == id }) {
                    Label("연결선", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.headline)
                    Text("출력: \(edge.outlet.label)").foregroundStyle(edge.outlet.color)
                    if let source = graph.nodes.first(where: { $0.id == edge.source }), let target = graph.nodes.first(where: { $0.id == edge.target }) {
                        Text("\(title(source)) → \(title(target))").font(.callout)
                    }
                    Button("연결선 삭제", systemImage: "trash", role: .destructive) { graph.edges.removeAll { $0.id == id }; selectedEdge = nil }
                    Text("연결선을 바꾸려면 출력 포트에서 새 대상의 입력 포트로 다시 드래그하세요.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("노드 설정", systemImage: "slider.horizontal.3").font(.headline)
                    Text("캔버스에서 노드를 선택하면 설정이 표시됩니다.").font(.callout).foregroundStyle(.secondary)
                    Divider()
                    hint("1", "왼쪽의 노드를 캔버스로 끌어 놓으세요.")
                    hint("2", "오른쪽 출력 포트에서 다음 노드의 왼쪽 입력 포트로 연결하세요.")
                    hint("3", "IF의 발견·시간 초과 경로를 각각 연결하세요.")
                    hint("4", "종료 노드로 연결한 뒤 자동화를 실행하세요.")
                    Text("연결하지 않은 노드는 실행되지 않습니다. 반복은 전체 반복·매크로 반복 횟수로 설정합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }.background(.white).disabled(engine.phase.isBusy)
    }

    @ViewBuilder private func controls(_ node: GraphNode) -> some View {
        if let binding = stepBinding(node.id) {
            switch node.kind {
            case .macro:
                Picker("매크로", selection: binding.macroID) {
                    Text("선택하세요").tag(UUID?.none)
                    ForEach(store.macros) { item in Text(item.name).tag(Optional(item.id)) }
                }.font(.callout)
                Stepper("\(node.step.repetitions)회 실행", value: binding.repetitions, in: 1...9_999).font(.callout)
                if let item = store.macros.first(where: { $0.id == node.step.macroID }) {
                    Text("\(item.recording.clickCount)회 클릭 · \(MacroEngine.timeString(item.recording.duration))").font(.caption).foregroundStyle(.secondary)
                }
            case .wait:
                HStack { Text("대기 시간"); TextField("초", value: binding.waitSeconds, format: .number).textFieldStyle(.roundedBorder).frame(width: 76); Text("초") }.font(.callout)
                Text("0~3,600초").font(.caption).foregroundStyle(.secondary)
            case .imageIf: ImageConditionEditor(condition: binding.condition)
            case .start, .end, .finish: EmptyView()
            }
        }
    }

    private func title(_ node: GraphNode) -> String {
        let index = (graph.nodes.firstIndex(where: { $0.id == node.id }) ?? 0) + 1
        return node.title.isEmpty ? "\(node.kind.label) · \(index)" : node.title
    }
    private func stepBinding(_ id: UUID) -> Binding<AutomationStep>? {
        guard graph.nodes.contains(where: { $0.id == id }) else { return nil }
        return Binding(get: { graph.nodes.first(where: { $0.id == id })?.step ?? AutomationStep(kind: .wait) }, set: { step in
            guard let i = graph.nodes.firstIndex(where: { $0.id == id }) else { return }; graph.nodes[i].step = step
        })
    }
    private func targetBinding(_ id: UUID, _ outlet: GraphOutlet) -> Binding<UUID?> {
        Binding(get: { graph.edges.first(where: { $0.source == id && $0.outlet == outlet })?.target }, set: { target in
            if let target {
                do { try graph.connect(source: id, outlet: outlet, target: target) }
                catch { store.error = error.localizedDescription }
            } else { graph.edges.removeAll { $0.source == id && $0.outlet == outlet } }
        })
    }
    private func hint(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(number).font(.caption.bold()).foregroundStyle(.indigo).frame(width: 22, height: 22).background(.indigo.opacity(0.08), in: Circle())
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
