import Accelerate
import Foundation

public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [Float]
    public init(width: Int, height: Int, pixels: [Float]) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 32_000_000, pixels.count == width * height,
              pixels.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw AutomationError.invalid("이미지 데이터가 올바르지 않습니다.")
        }
        self.width = width; self.height = height; self.pixels = pixels
    }

    private init(width: Int, height: Int, validPixels: [Float]) {
        self.width = width; self.height = height; pixels = validPixels
    }

    func reduced(by factor: Int) -> Self {
        guard factor > 1 else { return self }
        let w = width / factor, h = height / factor
        var result = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                for dy in 0..<factor {
                    for dx in 0..<factor { sum += pixels[(y * factor + dy) * width + x * factor + dx] }
                }
                result[y * w + x] = sum / Float(factor * factor)
            }
        }
        return Self(width: w, height: h, validPixels: result)
    }
}

public struct PixelMatch: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var score: Double
}

public enum TemplateMatcher {
    /// Zero-mean normalized cross correlation. Coarse candidates are refined at
    /// original resolution; flat templates are rejected instead of matching everything.
    public static func find(template: GrayImage, in image: GrayImage) throws -> PixelMatch? {
        guard template.width >= 3, template.height >= 3 else {
            throw AutomationError.invalid("찾을 이미지는 가로·세로 3픽셀 이상이어야 합니다.")
        }
        guard template.width <= image.width, template.height <= image.height else { return nil }
        let original = try Correlator(template: template, image: image)
        var factor = min(8, min(template.width, template.height) / 6)
        factor = max(1, factor)
        var coarse: Correlator? = nil
        while factor > 1 {
            coarse = try? Correlator(template: template.reduced(by: factor), image: image.reduced(by: factor))
            if coarse != nil { break }
            factor /= 2
        }
        guard factor > 1, let coarse else {
            return try original.candidates(limit: 1).first
        }
        let candidates = try coarse.candidates(limit: 12)
        var best: PixelMatch? = nil
        for candidate in candidates {
            try Task.checkCancellation()
            let x = candidate.x * factor, y = candidate.y * factor
            let x0 = max(0, x - factor), x1 = min(image.width - template.width, x + factor)
            let y0 = max(0, y - factor), y1 = min(image.height - template.height, y + factor)
            guard x0 <= x1, y0 <= y1 else { continue }
            for yy in y0...y1 {
                try Task.checkCancellation()
                for xx in x0...x1 {
                    let score = original.score(x: xx, y: yy)
                    if best == nil || score > best!.score { best = PixelMatch(x: xx, y: yy, score: score) }
                }
            }
        }
        return best
    }

    private struct Correlator {
        let template: GrayImage
        let image: GrayImage
        let centered: [Float]
        let templateEnergy: Double
        let sum: [Double]
        let square: [Double]
        let stride: Int

        init(template: GrayImage, image: GrayImage) throws {
            self.template = template; self.image = image
            let mean = template.pixels.reduce(0, +) / Float(template.pixels.count)
            centered = template.pixels.map { $0 - mean }
            templateEnergy = centered.reduce(0.0) { $0 + Double($1 * $1) }
            guard templateEnergy / Double(centered.count) > 0.000_001 else {
                throw AutomationError.invalid("단색 이미지 대신 글자나 무늬가 포함된 이미지를 선택해주세요.")
            }
            stride = image.width + 1
            var sums = [Double](repeating: 0, count: stride * (image.height + 1))
            var squares = sums
            for y in 0..<image.height {
                if y % 32 == 0 { try Task.checkCancellation() }
                var row = 0.0, rowSquare = 0.0
                for x in 0..<image.width {
                    let p = Double(image.pixels[y * image.width + x])
                    row += p; rowSquare += p * p
                    let i = (y + 1) * stride + x + 1
                    sums[i] = sums[i - stride] + row
                    squares[i] = squares[i - stride] + rowSquare
                }
            }
            sum = sums; square = squares
        }

        func score(x: Int, y: Int) -> Double {
            let a = y * stride + x, b = a + template.width
            let c = (y + template.height) * stride + x, d = c + template.width
            let s = sum[d] - sum[b] - sum[c] + sum[a]
            let energy = square[d] - square[b] - square[c] + square[a] - s * s / Double(centered.count)
            guard energy > 0.000_000_1 else { return 0 }
            var numerator: Float = 0
            centered.withUnsafeBufferPointer { t in
                image.pixels.withUnsafeBufferPointer { source in
                    for row in 0..<template.height {
                        var dot: Float = 0
                        vDSP_dotpr(t.baseAddress! + row * template.width, 1,
                                   source.baseAddress! + (y + row) * image.width + x, 1,
                                   &dot, vDSP_Length(template.width))
                        numerator += dot
                    }
                }
            }
            return min(1, max(0, Double(numerator) / sqrt(templateEnergy * energy)))
        }

        func candidates(limit: Int) throws -> [PixelMatch] {
            var result: [PixelMatch] = []
            for y in 0...(image.height - template.height) {
                try Task.checkCancellation()
                for x in 0...(image.width - template.width) {
                    let value = score(x: x, y: y)
                    if result.count < limit || value > result.last!.score {
                        result.append(PixelMatch(x: x, y: y, score: value))
                        result.sort { $0.score > $1.score }
                        if result.count > limit { result.removeLast() }
                    }
                }
            }
            return result
        }
    }
}
