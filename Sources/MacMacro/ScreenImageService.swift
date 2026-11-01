import AppKit
import ImageIO
import MacroCore
import ScreenCaptureKit

struct CapturedScreen: Identifiable, @unchecked Sendable {
    let id = UUID()
    let image: CGImage
    let bounds: CGRect
    let displayID: CGDirectDisplayID
}

enum ScreenImageService {
    static func capture(displayID: CGDirectDisplayID?) async throws -> CapturedScreen {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else {
            throw AutomationError.invalid("이미지 감지에는 화면 기록 권한이 필요합니다. 자동화 편집기에서 권한을 허용해주세요.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let id = displayID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw AutomationError.invalid("검색할 디스플레이가 연결되어 있지 않습니다. IF의 화면 설정을 확인해주세요.")
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = CGDisplayPixelsWide(id)
        config.height = CGDisplayPixelsHigh(id)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        return CapturedScreen(image: image, bounds: CGDisplayBounds(id), displayID: id)
    }

    static func decodeImage(_ data: Data) throws -> CGImage {
        guard data.count <= 10_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 3, height >= 3, width <= 4_096, height <= 4_096,
              width * height <= 8_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AutomationError.invalid("이미지는 가로·세로 3~4,096픽셀, 총 800만 픽셀·10MB 이하여야 합니다.")
        }
        return image
    }

    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              data.count <= 10_000_000 else { throw AutomationError.invalid("선택한 이미지가 너무 큽니다. 더 작은 영역을 선택해주세요.") }
        return data
    }

    static func gray(_ image: CGImage, scale: Double) throws -> GrayImage {
        let width = max(3, Int((Double(image.width) * scale).rounded()))
        let height = max(3, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let success = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw AutomationError.invalid("이미지를 분석할 수 없습니다.") }
        return try GrayImage(width: width, height: height, pixels: bytes.map { Float($0) / 255 })
    }

    static func match(_ condition: ImageCondition, frame: CapturedScreen) async throws -> ImageMatch? {
        let worker = Task.detached(priority: .userInitiated) { () throws -> ImageMatch? in
            let template = try decodeImage(condition.templatePNG)
            let bounds = frame.bounds
            let requested = condition.region.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? bounds
            let region = requested.intersection(bounds)
            guard !region.isNull, region.width > 0, region.height > 0 else {
                throw AutomationError.invalid("검색 영역이 선택한 화면과 겹치지 않습니다.")
            }
            let pixelX = Double(frame.image.width) / bounds.width
            let pixelY = Double(frame.image.height) / bounds.height
            let cropRect = CGRect(x: (region.minX - bounds.minX) * pixelX, y: (region.minY - bounds.minY) * pixelY,
                                  width: region.width * pixelX, height: region.height * pixelY).integral
            guard let cropped = frame.image.cropping(to: cropRect) else { throw AutomationError.invalid("검색 영역을 잘라낼 수 없습니다.") }
            // Use one common scale for the screenshot and its pixel-sized template.
            let scale = min(1, 1_600 / Double(max(cropped.width, cropped.height)))
            let image = try gray(cropped, scale: scale)
            let pattern = try gray(template, scale: scale)
            try Task.checkCancellation()
            guard let result = try TemplateMatcher.find(template: pattern, in: image),
                  result.score >= condition.similarity else { return nil }
            let scaleX = Double(cropped.width) / Double(image.width)
            let scaleY = Double(cropped.height) / Double(image.height)
            return ImageMatch(x: bounds.minX + (cropRect.minX + Double(result.x) * scaleX) / pixelX,
                              y: bounds.minY + (cropRect.minY + Double(result.y) * scaleY) / pixelY,
                              width: Double(template.width) / pixelX, height: Double(template.height) / pixelY,
                              score: result.score)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func waitForImage(_ condition: ImageCondition) async throws -> ImageMatch? {
        _ = try decodeImage(condition.templatePNG)
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            try Task.checkCancellation()
            let frame = try await capture(displayID: condition.displayID)
            let result = try await match(condition, frame: frame)
            try Task.checkCancellation()
            if result != nil { return result }
            let remaining = condition.timeout - (ProcessInfo.processInfo.systemUptime - start)
            if remaining <= 0 { return nil }
            try await Task.sleep(for: .seconds(min(condition.pollInterval, remaining)))
        }
    }
}
