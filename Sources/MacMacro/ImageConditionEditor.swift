import AppKit
import MacroCore
import SwiftUI

private struct CropRequest: Identifiable {
    let id = UUID()
    let frame: CapturedScreen
    let forRegion: Bool
}

struct ImageConditionEditor: View {
    @Binding var condition: ImageCondition
    @EnvironmentObject var engine: MacroEngine
    @State private var cropRequest: CropRequest?
    @State private var working = false
    @State private var testResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let image = NSImage(data: condition.templatePNG) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else { Image(systemName: "photo.badge.plus").font(.title).foregroundStyle(.secondary) }
                }.frame(width: 68, height: 52).padding(4)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 8) {
                    Text(condition.imageName).font(.caption.weight(.medium)).lineLimit(1)
                    HStack {
                        Button("이미지 파일", action: importImage)
                        Button("화면에서 선택") { capture(forRegion: false) }
                    }
                    Text("화면 배율·크기·테마가 같아야 정확합니다.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.disabled(working)

            VStack(alignment: .leading, spacing: 10) {
                Picker("검색 화면", selection: $condition.displayID) {
                    Text("주 디스플레이").tag(UInt32?.none)
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                            Text("\(index + 1). \(screen.localizedName)").tag(Optional(number.uint32Value))
                        }
                    }
                }
                Button("일치 여부 테스트", action: test).disabled(working || condition.templatePNG.isEmpty)
            }.font(.caption)
            HStack(spacing: 10) {
                Text("유사도 \(Int(condition.similarity * 100))%")
                Slider(value: $condition.similarity, in: 0.5...1, step: 0.01)
            }.font(.caption).textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("최대 대기 (초)").foregroundStyle(.secondary)
                    TextField("0~300", value: $condition.timeout, format: .number)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("검색 간격 (초)").foregroundStyle(.secondary)
                    TextField("0.2~5", value: $condition.pollInterval, format: .number)
                }
            }.font(.caption).textFieldStyle(.roundedBorder)
            Toggle("발견한 이미지의 중심 클릭", isOn: $condition.clickWhenFound).toggleStyle(.checkbox).font(.caption)

            HStack {
                Toggle("검색 영역 지정", isOn: Binding(get: { condition.region != nil }, set: { enabled in
                    let bounds = CGDisplayBounds(condition.displayID ?? CGMainDisplayID())
                    condition.region = enabled ? SearchRegion(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height) : nil
                })).toggleStyle(.checkbox)
                Spacer()
            }.font(.caption)
            if condition.region != nil {
                Button("영역을 화면에서 선택") { capture(forRegion: true) }.font(.caption).disabled(working)
                HStack(spacing: 10) { regionField("X", \.x); regionField("Y", \.y) }.font(.caption)
                HStack(spacing: 10) { regionField("너비", \.width); regionField("높이", \.height) }.font(.caption)
            }
            if working { ProgressView().controlSize(.small) }
            if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .sheet(item: $cropRequest) { request in
            ScreenCropView(frame: request.frame, forRegion: request.forRegion) { pixels, global in
                do {
                    if request.forRegion {
                        condition.region = SearchRegion(x: global.minX, y: global.minY, width: global.width, height: global.height)
                    } else {
                        guard let cropped = request.frame.image.cropping(to: pixels) else { throw AutomationError.invalid("선택 영역을 읽을 수 없습니다.") }
                        let data = try ScreenImageService.png(cropped)
                        _ = try ScreenImageService.decodeImage(data)
                        condition.templatePNG = data
                        condition.imageName = "화면에서 선택한 이미지"
                    }
                    condition.displayID = request.frame.displayID
                    testResult = nil
                } catch { engine.error = error.localizedDescription }
                cropRequest = nil
            }
        }
    }

    private func regionField(_ title: String, _ key: WritableKeyPath<SearchRegion, Double>) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { condition.region?[keyPath: key] ?? 0 }, set: { value in
                guard var region = condition.region else { return }; region[keyPath: key] = value; condition.region = region
            }), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(minWidth: 42, maxWidth: 80)
        }
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 10_000_000 else { throw AutomationError.invalid("이미지는 10MB 이하여야 합니다.") }
            let image = try ScreenImageService.decodeImage(Data(contentsOf: url))
            condition.templatePNG = try ScreenImageService.png(image)
            condition.imageName = url.lastPathComponent
            testResult = nil
        } catch { engine.error = error.localizedDescription }
    }

    private func capture(forRegion: Bool) {
        working = true
        let id = condition.displayID
        Task {
            defer { working = false }
            do { cropRequest = CropRequest(frame: try await ScreenImageService.capture(displayID: id), forRegion: forRegion) }
            catch { engine.error = error.localizedDescription }
        }
    }

    private func test() {
        working = true
        let snapshot = condition
        Task {
            defer { working = false }
            do {
                guard snapshot.similarity.isFinite, (0.5...1).contains(snapshot.similarity) else { throw AutomationError.invalid("유사도를 확인해주세요.") }
                let frame = try await ScreenImageService.capture(displayID: snapshot.displayID)
                if let match = try await ScreenImageService.match(snapshot, frame: frame) {
                    testResult = "발견 · 유사도 \(Int(match.score * 100))% · 중심 (\(Int(match.x + match.width / 2)), \(Int(match.y + match.height / 2)))"
                } else { testResult = "현재 화면에서 조건을 만족하는 이미지를 찾지 못했습니다." }
            } catch { engine.error = error.localizedDescription }
        }
    }
}

private struct ScreenCropView: View {
    let frame: CapturedScreen
    let forRegion: Bool
    let selected: (CGRect, CGRect) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var selection: CGRect = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(forRegion ? "이미지를 검색할 영역을 드래그하세요" : "찾을 이미지를 드래그해서 선택하세요").font(.headline)
            Text("앱 자체의 창과 안내 오버레이는 캡처에서 제외됩니다.").font(.caption).foregroundStyle(.secondary)
            GeometryReader { proxy in
                let rect = fitRect(proxy.size)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.08)
                    Image(nsImage: NSImage(cgImage: frame.image, size: .zero)).resizable()
                        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    if !selection.isEmpty {
                        Rectangle().fill(.indigo.opacity(0.16)).overlay(Rectangle().stroke(.indigo, lineWidth: 2))
                            .frame(width: selection.width, height: selection.height).position(x: selection.midX, y: selection.midY)
                    }
                }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    let start = clamp(value.startLocation, rect), end = clamp(value.location, rect)
                    selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
                })
                HStack { Spacer(); VStack { Spacer(); Text("\(Int(selection.width)) × \(Int(selection.height))").font(.caption.monospacedDigit()).padding(6).background(.regularMaterial) } }
                    .allowsHitTesting(false)
            }.frame(width: 860, height: 500)
            HStack {
                Button("취소", role: .cancel) { dismiss() }
                Spacer()
                Button("선택 적용") {
                    let rect = fitRect(CGSize(width: 860, height: 500))
                    let nx = (selection.minX - rect.minX) / rect.width, ny = (selection.minY - rect.minY) / rect.height
                    let nw = selection.width / rect.width, nh = selection.height / rect.height
                    let pixels = CGRect(x: nx * Double(frame.image.width), y: ny * Double(frame.image.height),
                                        width: nw * Double(frame.image.width), height: nh * Double(frame.image.height)).integral
                    let global = CGRect(x: frame.bounds.minX + nx * frame.bounds.width, y: frame.bounds.minY + ny * frame.bounds.height,
                                        width: nw * frame.bounds.width, height: nh * frame.bounds.height)
                    selected(pixels, global)
                }.buttonStyle(.borderedProminent).disabled(selection.width < 3 || selection.height < 3)
            }
        }.padding(22)
    }

    private func fitRect(_ size: CGSize) -> CGRect {
        let scale = min(size.width / Double(frame.image.width), size.height / Double(frame.image.height))
        let w = Double(frame.image.width) * scale, h = Double(frame.image.height) * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func clamp(_ point: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: min(rect.maxX, max(rect.minX, point.x)), y: min(rect.maxY, max(rect.minY, point.y)))
    }
}
