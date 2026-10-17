import AppKit
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let bounds = NSRect(x: 70, y: 70, width: 884, height: 884)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 200, yRadius: 200)
        NSColor(calibratedRed: 0.06, green: 0.38, blue: 0.36, alpha: 1).setFill(); shape.fill()
        shape.addClip()
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.59, blue: 0.53, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.31, blue: 0.32, alpha: 1))!
        gradient.draw(in: bounds, angle: -60)
        NSColor.white.setFill()
        let heights: [CGFloat] = [110, 230, 370, 500, 340, 220, 110]
        for (index, height) in heights.enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 236 + CGFloat(index) * 80, y: 512 - height / 2, width: 48, height: height), xRadius: 24, yRadius: 24).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
