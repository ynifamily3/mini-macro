import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let inset = CGFloat(pixels) * 0.055
        let rect = NSRect(x: inset, y: inset, width: CGFloat(pixels) - 2 * inset, height: CGFloat(pixels) - 2 * inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22)
        NSGradient(starting: NSColor(srgbRed: 0.45, green: 0.43, blue: 0.98, alpha: 1),
                   ending: NSColor(srgbRed: 0.28, green: 0.25, blue: 0.79, alpha: 1))!.draw(in: path, angle: -90)
        let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * 0.51, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let width = CGFloat(pixels) * 0.59
            let height = width * symbol.size.height / symbol.size.width
            symbol.draw(in: NSRect(x: (CGFloat(pixels) - width) / 2, y: (CGFloat(pixels) - height) / 2, width: width, height: height))
        }
        image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: folder.appendingPathComponent(name))
    }
}
