import MacroCore
import SwiftUI

extension GraphNodeKind {
    var label: String {
        switch self { case .start: "시작"; case .macro: "매크로 실행"; case .wait: "대기"; case .imageIf: "이미지 IF"; case .end: "종료"; case .finish: "전체 종료" }
    }
    var symbol: String {
        switch self { case .start: "play.fill"; case .macro: "cursorarrow.click"; case .wait: "clock"; case .imageIf: "arrow.triangle.branch"; case .end: "checkmark"; case .finish: "stop.fill" }
    }
    var color: Color {
        switch self { case .start: .teal; case .macro: .indigo; case .wait: .orange; case .imageIf: .purple; case .end: .green; case .finish: .gray }
    }
    var explanation: String {
        switch self {
        case .start: "시작에서 연결된 노드를 따라 실행합니다."
        case .macro: "보관함의 녹화를 선택해 실행합니다."
        case .wait: "설정한 시간만큼 기다립니다."
        case .imageIf: "이미지 발견 여부에 따라 두 경로로 나눕니다."
        case .end: "한 회를 마칩니다. 남은 전체 반복이 있으면 시작으로 돌아갑니다."
        case .finish: "남은 전체 반복까지 포함해 자동화를 즉시 마칩니다."
        }
    }
}

extension GraphOutlet {
    var label: String { switch self { case .next: "다음"; case .found: "발견"; case .notFound: "시간 초과" } }
    var color: Color { switch self { case .next: .indigo; case .found: .green; case .notFound: .orange } }
}

enum GraphMetrics {
    static let width = 220.0
    static let height = 144.0
    static func outletY(_ outlet: GraphOutlet) -> Double { switch outlet { case .next: 72; case .found: 63; case .notFound: 113 } }
}

struct GraphNodeCard: View {
    let node: GraphNode
    let subtitle: String
    let selected: Bool
    let active: Bool
    let completed: Bool
    let interrupted: Bool
    let pendingOutlet: GraphOutlet?
    let input: () -> Void
    let output: (GraphOutlet) -> Void
    let wireChanged: (GraphOutlet, CGPoint) -> Void
    let wireEnded: (GraphOutlet, CGPoint) -> Void
    let moved: (CGSize, Bool) -> Void
    let tapped: () -> Void
    let duplicate: () -> Void
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 15).fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(border, lineWidth: active || selected ? 2.5 : 1.2))
                .shadow(color: active ? .indigo.opacity(0.25) : .black.opacity(0.06), radius: active ? 12 : 4, y: 2)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: node.kind.symbol).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(node.kind.color).frame(width: 31, height: 31)
                        .background(node.kind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    Text(node.title.isEmpty ? node.kind.label : node.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if active { ProgressView().controlSize(.mini) }
                    else if interrupted { Image(systemName: "pause.circle.fill").foregroundStyle(.orange) }
                    else if completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: node.kind == .imageIf ? 130 : .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Text(node.kind == .macro ? "\(node.step.repetitions)회 실행" : node.kind.label.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(node.kind.color.opacity(0.7))
            }.padding(16)
            if node.kind != .start {
                Button(action: input) {
                    Circle().fill(.white).overlay(Circle().stroke(Color.gray.opacity(0.8), lineWidth: 2.5)).frame(width: 13, height: 13)
                        .frame(width: 28, height: 28).contentShape(Circle())
                }.buttonStyle(.plain).position(x: 0, y: GraphMetrics.height / 2)
                    .help("입력 포트 · 출력에서 끌어 연결").accessibilityLabel("\(node.kind.label) 입력 포트")
            }
            ForEach(node.kind.outlets, id: \.self) { outlet in
                if node.kind == .imageIf {
                    Text(outlet.label).font(.system(size: 9, weight: .semibold)).foregroundStyle(outlet.color)
                        .frame(width: 58, alignment: .trailing).position(x: GraphMetrics.width - 42, y: GraphMetrics.outletY(outlet))
                }
                Circle().fill(pendingOutlet == outlet ? outlet.color : .white)
                    .overlay(Circle().stroke(outlet.color, lineWidth: 2.5))
                    .frame(width: 13, height: 13).frame(width: 28, height: 28).contentShape(Circle())
                    .onTapGesture { output(outlet) }
                    .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("graphCanvas"))
                        .onChanged { wireChanged(outlet, $0.location) }
                        .onEnded { wireEnded(outlet, $0.location) })
                    .position(x: GraphMetrics.width, y: GraphMetrics.outletY(outlet))
                    .help("\(outlet.label) 출력 · 드래그하거나 클릭 후 입력 포트를 선택")
                    .accessibilityLabel("\(node.kind.label) \(outlet.label) 출력 포트")
            }
        }
        .frame(width: GraphMetrics.width, height: GraphMetrics.height)
        .contentShape(Rectangle().inset(by: -14))
        .onTapGesture(perform: tapped)
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("graphCanvas"))
            .onChanged { moved($0.translation, false) }.onEnded { moved($0.translation, true) })
        .contextMenu {
            Button("노드 복제", action: duplicate).disabled(node.kind == .start)
            Button("노드 삭제", role: .destructive, action: remove).disabled(node.kind == .start)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.title.isEmpty ? node.kind.label : node.title) 노드")
    }

    private var border: Color { active ? .indigo : interrupted ? .orange : selected ? .indigo : completed ? .green.opacity(0.7) : .gray.opacity(0.25) }
}

struct GraphWireShape: Shape {
    let start: CGPoint
    let end: CGPoint
    var hitWidth: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bend = max(55, min(180, abs(end.x - start.x) * 0.45))
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        return hitWidth > 0 ? path.strokedPath(StrokeStyle(lineWidth: hitWidth, lineCap: .round)) : path
    }
}
