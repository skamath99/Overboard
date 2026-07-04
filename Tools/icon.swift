// Renders the Overboard! app icon (1024x1024 PNG): a single ivory square
// piece wearing the red anchor, on the app's navy background.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawShadow(_ path: NSBezierPath, blur: CGFloat = 60, dy: CGFloat = -24) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: blur, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    color(0x10141F).setFill()
    path.fill()
    ctx.restoreGState()
}

// Background: deep navy gradient.
NSGradient(colors: [color(0x2B3550), color(0x0E121C)])!
    .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)

// The ivory square piece, front and center.
let pieceRect = NSRect(x: 202, y: 202, width: 620, height: 620)
let piece = NSBezierPath(roundedRect: pieceRect, xRadius: 136, yRadius: 136)
drawShadow(piece)
NSGradient(colors: [color(0xFDFBF4), color(0xD5CDBA)])!.draw(in: piece, angle: -65)
color(0xB8AF99).setStroke()
piece.lineWidth = 22
piece.stroke()

// Red anchor badge on the piece's top-right corner.
let badgeCenter = NSPoint(x: pieceRect.maxX - 52, y: pieceRect.maxY - 52)
let badgeRadius: CGFloat = 158
let badge = NSBezierPath(ovalIn: NSRect(
    x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
    width: badgeRadius * 2, height: badgeRadius * 2
))
drawShadow(badge, blur: 40, dy: -14)
NSGradient(colors: [color(0xEC6560), color(0xC93E3A)])!.draw(in: badge, angle: -70)

// Anchor glyph, drawn by hand (ring, shaft, crossbar, bowl).
let ax = badgeCenter.x
let ay = badgeCenter.y
let s: CGFloat = 1.5
NSColor.white.setStroke()

let ring = NSBezierPath(ovalIn: NSRect(x: ax - 21 * s, y: ay + 26 * s, width: 42 * s, height: 42 * s))
ring.lineWidth = 15 * s
ring.stroke()

let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: ax, y: ay + 26 * s))
shaft.line(to: NSPoint(x: ax, y: ay - 62 * s))
shaft.lineWidth = 15 * s
shaft.lineCapStyle = .round
shaft.stroke()

let crossbar = NSBezierPath()
crossbar.move(to: NSPoint(x: ax - 36 * s, y: ay + 2 * s))
crossbar.line(to: NSPoint(x: ax + 36 * s, y: ay + 2 * s))
crossbar.lineWidth = 15 * s
crossbar.lineCapStyle = .round
crossbar.stroke()

let bowl = NSBezierPath()
bowl.appendArc(withCenter: NSPoint(x: ax, y: ay - 14 * s), radius: 48 * s, startAngle: 205, endAngle: 335)
bowl.lineWidth = 15 * s
bowl.lineCapStyle = .round
bowl.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fatalError("PNG encode failed") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
