// SPDX-License-Identifier: MPL-2.0
import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor(calibratedRed: 0.08, green: 0.19, blue: 0.33, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: CGFloat(pixels) * 0.045, dy: CGFloat(pixels) * 0.045), xRadius: CGFloat(pixels) * 0.21, yRadius: CGFloat(pixels) * 0.21).fill()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: CGFloat(pixels) * 0.245, dy: CGFloat(pixels) * 0.245))
        ring.lineWidth = CGFloat(pixels) * 0.075
        NSColor.white.setStroke(); ring.stroke()
        let ray = NSBezierPath()
        ray.move(to: NSPoint(x: CGFloat(pixels) * 0.5, y: CGFloat(pixels) * 0.5))
        ray.line(to: NSPoint(x: CGFloat(pixels) * 0.785, y: CGFloat(pixels) * 0.215))
        ray.lineWidth = CGFloat(pixels) * 0.075; ray.lineCapStyle = .round
        NSColor(calibratedRed: 0.28, green: 0.88, blue: 0.78, alpha: 1).setStroke(); ray.stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
