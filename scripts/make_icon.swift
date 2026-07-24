// Renders the Mutter app icon: soft teal rounded square with a white
// waveform. Run: swift scripts/make_icon.swift <output-1024.png>
import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "mutter-1024.png"

let canvas = CGFloat(1024)
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Standard macOS icon grid: 824×824 squircle centered on 1024 canvas.
let inset = (canvas - 824) / 2
let squircle = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: 824, height: 824),
    xRadius: 186, yRadius: 186)

let gradient = NSGradient(
    starting: NSColor(red: 0.30, green: 0.68, blue: 0.64, alpha: 1),
    ending: NSColor(red: 0.09, green: 0.36, blue: 0.34, alpha: 1))!
gradient.draw(in: squircle, angle: -90)

// Soft top glow that fades out — no hard edges.
NSGraphicsContext.current?.saveGraphicsState()
squircle.addClip()
let glow = NSGradient(
    starting: NSColor.white.withAlphaComponent(0.16),
    ending: NSColor.white.withAlphaComponent(0))!
glow.draw(
    in: NSRect(x: inset, y: canvas / 2, width: 824, height: 412 + inset),
    angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()

// Waveform: five rounded bars, gently varied heights.
let heights: [CGFloat] = [170, 320, 460, 320, 170]
let barWidth = CGFloat(72)
let spacing = CGFloat(38)
let totalWidth = barWidth * 5 + spacing * 4
var x = (canvas - totalWidth) / 2
NSColor(white: 1, alpha: 0.96).setFill()
for height in heights {
    let bar = NSBezierPath(
        roundedRect: NSRect(
            x: x, y: (canvas - height) / 2, width: barWidth, height: height),
        xRadius: barWidth / 2, yRadius: barWidth / 2)
    bar.fill()
    x += barWidth + spacing
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    fatalError("Could not render icon")
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
