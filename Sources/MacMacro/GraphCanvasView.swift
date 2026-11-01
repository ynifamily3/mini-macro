import MacroCore
import SwiftUI

struct GraphAddRequest {
    let id = UUID()
    let kind: GraphNodeKind
    var macroID: UUID? = nil
    var canvasPoint: CGPoint? = nil
}

private struct WireSource: Equatable { let node: UUID; let outlet: GraphOutlet }

struct GraphCanvasView: View {
    @Binding var graph: AutomationGraph
    @Binding var selectedNode: UUID?
    @Binding var selectedEdge: UUID?
    let workflowID: UUID
    let addRequest: GraphAddRequest?
    var inspectSelection: () -> Void = { }
    @EnvironmentObject var store: AutomationStore
    @EnvironmentObject var engine: MacroEngine
    @State private var pending: WireSource?
    @State private var wireEnd: CGPoint?
    @State private var draggingID: UUID?
    @State private var nodeTranslation = CGSize.zero
    @State private var panTranslation = CGSize.zero
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    private var editable: Bool { !engine.phase.isBusy }
    private var camera: GraphViewport {
        var v = graph.viewport; v.x += panTranslation.width; v.y += panTranslation.height; return v
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(red: 0.967, green: 0.973, blue: 0.984)
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true; selectedNode = nil; selectedEdge = nil; pending = nil; wireEnd = nil }
                    .gesture(DragGesture(minimumDistance: 3)
                        .onChanged { if editable { focused = true; panTranslation = $0.translation } }
                        .onEnded { _ in
                            guard editable else { panTranslation = .zero; return }
                            var v = camera; v.initialized = true; graph.viewport = bounded(v); panTranslation = .zero
                        })
                grid(size: proxy.size).allowsHitTesting(false)
                ForEach(graph.edges) { edge in edgeView(edge) }
                if let pending, let start = portPoint(pending.node, outlet: pending.outlet), let end = wireEnd {
                    GraphWireShape(start: start, end: end).stroke(pending.outlet.color, style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                        .allowsHitTesting(false)
                }
                ForEach(graph.nodes) { node in
                    GraphNodeCard(node: node, subtitle: subtitle(node), selected: selectedNode == node.id,
                        active: hasTrace && engine.activeNodeID == node.id,
                        completed: hasTrace && engine.completedNodeIDs.contains(node.id),
                        interrupted: hasTrace && engine.interruptedNodeID == node.id,
                        pendingOutlet: pending?.node == node.id ? pending?.outlet : nil,
                        input: { if let pending { connect(pending, to: node.id) } else { select(node.id) } },
                        output: { outlet in guard editable else { return }; select(node.id, inspect: false); pending = WireSource(node: node.id, outlet: outlet); wireEnd = nil },
                        wireChanged: { outlet, point in
                            guard editable else { return }; focused = true; pending = WireSource(node: node.id, outlet: outlet); wireEnd = point
                        }, wireEnded: { outlet, point in
                            guard editable else { return }
                            let source = WireSource(node: node.id, outlet: outlet)
                            if let target = target(at: point, excluding: node.id) { connect(source, to: target) }
                            pending = nil; wireEnd = nil
                        }, moved: { translation, ended in move(node.id, translation: translation, ended: ended) },
                        tapped: { select(node.id) }, duplicate: { duplicate(node.id) }, remove: { removeNode(node.id) })
                        .scaleEffect(camera.zoom)
                        .position(nodeCenter(node))
                        .zIndex(draggingID == node.id ? 3 : 1)
                }
                VStack {
                    HStack {
                        Text(pending == nil ? "출력 → 입력으로 연결" : "입력 포트를 선택하세요")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Button { guard editable else { return }; graph = graph.arranged(); fit(proxy.size) } label: {
                            Label("자동 정렬", systemImage: "square.grid.3x2")
                        }.disabled(!editable)
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        HStack(spacing: 9) {
                            Button { zoom(1 / 1.2, around: CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)) } label: { Image(systemName: "minus") }.help("축소")
                            Text("\(Int(camera.zoom * 100))%").font(.system(size: 10, design: .monospaced)).frame(width: 34)
                            Button { zoom(1.2, around: CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)) } label: { Image(systemName: "plus") }.help("확대")
                            Divider().frame(height: 14)
                            Button { fit(proxy.size) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("화면에 맞추기")
                        }.buttonStyle(.borderless).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black.opacity(0.07)))
                        Spacer()
                        Text(pending == nil ? "빈 곳 드래그·휠로 이동   ⌘휠·핀치로 확대" : "입력 포트에 놓거나 클릭하세요 · Esc 취소")
                            .font(.system(size: 10)).foregroundStyle(.secondary).padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).allowsHitTesting(false)
                    }
                }.padding(16).zIndex(10)
            }
            .coordinateSpace(name: "graphCanvas")
            .background(CanvasWheelObserver(enabled: editable, pan: { delta in
                var v = graph.viewport; v.x += delta.width; v.y += delta.height; v.initialized = true; graph.viewport = bounded(v)
            }, zoom: { factor, point in zoom(factor, around: point) }))
            .clipped()
            .overlay(Rectangle().stroke(dropTargeted ? .indigo : .clear, lineWidth: 3).allowsHitTesting(false))
            .focusable().focusEffectDisabled().focused($focused)
            .onDeleteCommand { deleteSelection() }
            .onExitCommand { pending = nil; wireEnd = nil }
            .onChange(of: engine.phase.isBusy) { _, busy in
                if busy { focused = false; pending = nil; wireEnd = nil; draggingID = nil; nodeTranslation = .zero; panTranslation = .zero }
            }
            .onChange(of: addRequest?.id) { _, _ in
                if let request = addRequest { add(request.kind, macroID: request.macroID, at: request.canvasPoint ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)) }
            }
            .onChange(of: proxy.size) { _, size in keepSelectionVisible(size) }
            .onAppear { if !graph.viewport.initialized { fit(proxy.size) } }
            .dropDestination(for: String.self, action: { values, point in
                guard editable, let value = values.first else { return false }
                if value.hasPrefix("macmacro-node:"), let kind = GraphNodeKind(rawValue: String(value.dropFirst("macmacro-node:".count))), kind != .start {
                    add(kind, macroID: nil, at: point); return true
                }
                if value.hasPrefix("macmacro-macro:"), let id = UUID(uuidString: String(value.dropFirst("macmacro-macro:".count))), store.macros.contains(where: { $0.id == id }) {
                    add(.macro, macroID: id, at: point); return true
                }
                return false
            }, isTargeted: { dropTargeted = $0 })
        }
    }

    private var hasTrace: Bool { engine.runningWorkflowID == workflowID }

    private func grid(size: CGSize) -> some View {
        Canvas { context, _ in
            let spacing = max(8, 24 * camera.zoom)
            let ox = camera.x.truncatingRemainder(dividingBy: spacing), oy = camera.y.truncatingRemainder(dividingBy: spacing)
            for x in stride(from: ox, through: size.width, by: spacing) {
                for y in stride(from: oy, through: size.height, by: spacing) {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.indigo.opacity(0.17)))
                }
            }
        }
    }

    @ViewBuilder private func edgeView(_ edge: GraphEdge) -> some View {
        if let start = portPoint(edge.source, outlet: edge.outlet), let end = inputPoint(edge.target) {
            let traveled = hasTrace && engine.traversedEdgeIDs.contains(edge.id)
            let color = selectedEdge == edge.id ? Color.blue : traveled ? edge.outlet.color : edge.outlet.color.opacity(0.42)
            GraphWireShape(start: start, end: end).stroke(color, style: StrokeStyle(lineWidth: selectedEdge == edge.id || traveled ? 3.5 : 2, lineCap: .round)).allowsHitTesting(false)
            GraphWireShape(start: start, end: end, hitWidth: 18).fill(.clear)
                .contentShape(GraphWireShape(start: start, end: end, hitWidth: 18))
                .onTapGesture { focused = true; selectedNode = nil; selectedEdge = edge.id; pending = nil; inspectSelection() }
            Path { p in p.move(to: end); p.addLine(to: CGPoint(x: end.x - 9, y: end.y - 4)); p.addLine(to: CGPoint(x: end.x - 9, y: end.y + 4)); p.closeSubpath() }
                .fill(color).allowsHitTesting(false)
        }
    }

    private func displayedOrigin(_ node: GraphNode) -> CGPoint {
        CGPoint(x: node.x + (draggingID == node.id ? nodeTranslation.width : 0), y: node.y + (draggingID == node.id ? nodeTranslation.height : 0))
    }
    private func nodeCenter(_ node: GraphNode) -> CGPoint {
        let p = displayedOrigin(node)
        return camera.screenPoint(CGPoint(x: p.x + GraphMetrics.width / 2, y: p.y + GraphMetrics.height / 2))
    }
    private func inputPoint(_ id: UUID) -> CGPoint? {
        guard let node = graph.nodes.first(where: { $0.id == id }) else { return nil }
        let p = displayedOrigin(node); return camera.screenPoint(CGPoint(x: p.x, y: p.y + GraphMetrics.height / 2))
    }
    private func portPoint(_ id: UUID, outlet: GraphOutlet) -> CGPoint? {
        guard let node = graph.nodes.first(where: { $0.id == id }) else { return nil }
        let p = displayedOrigin(node); return camera.screenPoint(CGPoint(x: p.x + GraphMetrics.width, y: p.y + GraphMetrics.outletY(outlet)))
    }
    private func target(at point: CGPoint, excluding: UUID) -> UUID? {
        for node in graph.nodes.reversed() where node.id != excluding && node.kind != .start {
            guard let input = inputPoint(node.id) else { continue }
            let p = camera.screenPoint(displayedOrigin(node))
            let rect = CGRect(x: p.x, y: p.y, width: GraphMetrics.width * camera.zoom, height: GraphMetrics.height * camera.zoom)
            if hypot(point.x - input.x, point.y - input.y) < 28 || rect.contains(point) { return node.id }
        }
        return nil
    }
    private func connect(_ source: WireSource, to id: UUID) {
        guard editable else { return }
        do { try graph.connect(source: source.node, outlet: source.outlet, target: id) }
        catch { store.error = error.localizedDescription }
        pending = nil; wireEnd = nil
    }
    private func select(_ id: UUID, inspect: Bool = true) {
        selectedNode = id; selectedEdge = nil; if editable { focused = true }; if inspect { inspectSelection() }
    }
    private func move(_ id: UUID, translation: CGSize, ended: Bool) {
        guard editable else { return }
        select(id, inspect: false); draggingID = id
        nodeTranslation = CGSize(width: translation.width / camera.zoom, height: translation.height / camera.zoom)
        if ended {
            if let i = graph.nodes.firstIndex(where: { $0.id == id }) {
                graph.nodes[i].x = min(500_000, max(-500_000, graph.nodes[i].x + nodeTranslation.width))
                graph.nodes[i].y = min(500_000, max(-500_000, graph.nodes[i].y + nodeTranslation.height))
            }
            draggingID = nil; nodeTranslation = .zero
        }
    }
    private func add(_ kind: GraphNodeKind, macroID: UUID?, at point: CGPoint) {
        guard editable, graph.nodes.count < 1_002 else { return }
        let world = camera.worldPoint(point)
        var node = GraphNode(kind: kind, x: world.x - GraphMetrics.width / 2, y: world.y - GraphMetrics.height / 2)
        node.x = min(500_000, max(-500_000, node.x)); node.y = min(500_000, max(-500_000, node.y))
        if kind == .macro { node.step.macroID = macroID ?? store.macros.first?.id }
        graph.nodes.append(node); select(node.id)
    }
    private func duplicate(_ id: UUID) {
        guard editable, graph.nodes.count < 1_002, var node = graph.nodes.first(where: { $0.id == id }), node.kind != .start else { return }
        node.id = UUID(); node.step.id = node.id; node.x += 36; node.y += 36
        node.x = min(500_000, node.x); node.y = min(500_000, node.y)
        graph.nodes.append(node); select(node.id)
    }
    private func removeNode(_ id: UUID) {
        guard editable else { return }; graph.removeNode(id)
        if selectedNode == id { selectedNode = nil }; selectedEdge = nil; pending = nil
    }
    private func deleteSelection() {
        guard editable else { return }
        if let id = selectedEdge { graph.edges.removeAll { $0.id == id }; selectedEdge = nil }
        else if let id = selectedNode { removeNode(id) }
    }
    private func zoom(_ factor: Double, around point: CGPoint) {
        guard editable else { return }; graph.viewport = graph.viewport.zoomed(by: factor, around: point)
    }
    private func fit(_ size: CGSize) {
        guard !graph.nodes.isEmpty, size.width > 0, size.height > 0 else { return }
        let minX = graph.nodes.map(\.x).min()!, maxX = graph.nodes.map(\.x).max()! + GraphMetrics.width
        let minY = graph.nodes.map(\.y).min()!, maxY = graph.nodes.map(\.y).max()! + GraphMetrics.height
        var v = graph.viewport
        v.zoom = min(1.1, max(0.2, min((size.width - 80) / (maxX - minX), (size.height - 100) / (maxY - minY))))
        v.x = (size.width - (maxX - minX) * v.zoom) / 2 - minX * v.zoom
        v.y = (size.height - (maxY - minY) * v.zoom) / 2 - minY * v.zoom
        v.initialized = true; graph.viewport = bounded(v)
    }
    private func keepSelectionVisible(_ size: CGSize) {
        guard editable, draggingID == nil, panTranslation == .zero,
              let id = selectedNode, let node = graph.nodes.first(where: { $0.id == id }) else { return }
        let point = nodeCenter(node)
        let px = min(size.width / 2, GraphMetrics.width * camera.zoom / 2 + 28)
        let py = min(size.height / 2, GraphMetrics.height * camera.zoom / 2 + 28)
        let x = min(size.width - px, max(px, point.x)), y = min(size.height - py, max(py, point.y))
        guard abs(x - point.x) > 1 || abs(y - point.y) > 1 else { return }
        var v = graph.viewport; v.x += x - point.x; v.y += y - point.y; graph.viewport = bounded(v)
    }
    private func bounded(_ value: GraphViewport) -> GraphViewport {
        var value = value; value.x = min(1_000_000, max(-1_000_000, value.x)); value.y = min(1_000_000, max(-1_000_000, value.y)); return value
    }
    private func subtitle(_ node: GraphNode) -> String {
        switch node.kind {
        case .macro: store.macros.first(where: { $0.id == node.step.macroID })?.name ?? "매크로를 선택하세요"
        case .wait: "\(node.step.waitSeconds.formatted())초 기다리기"
        case .imageIf: node.step.condition.templatePNG.isEmpty ? "찾을 이미지를 등록하세요" : node.step.condition.imageName
        default: node.kind.explanation
        }
    }
}
