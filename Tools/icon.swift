// Renders the PushFight app icon (1024x1024 PNG).
// Concept: an ivory square (with the red anchor) pushing a walnut round piece
// off the right edge — the entire game in one image, in the app's palette.
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

func drawShadow(_ path: NSBezierPath) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 42, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    color(0x10141F).setFill()
    path.fill()
    ctx.restoreGState()
}

// Background: deep navy gradient.
NSGradient(colors: [color(0x27314B), color(0x0E121C)])!
    .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)

// Rails top and bottom — the board, abstracted.
for railY: CGFloat in [836, 162] {
    let rail = NSBezierPath(roundedRect: NSRect(x: -40, y: railY, width: 1104, height: 26), xRadius: 13, yRadius: 13)
    color(0x8A93AB).setFill()
    rail.fill()
}

// Walnut round piece: pushed, clipping the right edge of the icon.
let roundPiece = NSBezierPath(ovalIn: NSRect(x: 700, y: 337, width: 346, height: 346))
drawShadow(roundPiece)
NSGradient(colors: [color(0x74513A), color(0x3F2A1B)])!.draw(in: roundPiece, angle: -65)
color(0x2A1B10).setStroke()
roundPiece.lineWidth = 16
roundPiece.stroke()

// Motion chevrons.
color(0xFFFFFF, 0.9).setStroke()
for offset in [CGFloat(0), 92] {
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 528 + offset, y: 430))
    chevron.line(to: NSPoint(x: 574 + offset, y: 510))
    chevron.line(to: NSPoint(x: 528 + offset, y: 590))
    chevron.lineWidth = 30
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.stroke()
}

// Ivory square piece: the pusher.
let squareRect = NSRect(x: 96, y: 322, width: 376, height: 376)
let squarePiece = NSBezierPath(roundedRect: squareRect, xRadius: 84, yRadius: 84)
drawShadow(squarePiece)
NSGradient(colors: [color(0xFDFBF4), color(0xD5CDBA)])!.draw(in: squarePiece, angle: -65)
color(0xB8AF99).setStroke()
squarePiece.lineWidth = 16
squarePiece.stroke()

// Red anchor badge pinned to the pusher's top-right corner.
let badgeCenter = NSPoint(x: squareRect.maxX - 30, y: squareRect.maxY - 30)
let badgeRadius: CGFloat = 108
let badge = NSBezierPath(ovalIn: NSRect(
    x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
    width: badgeRadius * 2, height: badgeRadius * 2
))
drawShadow(badge)
NSGradient(colors: [color(0xEC6560), color(0xC93E3A)])!.draw(in: badge, angle: -70)

// Anchor glyph, drawn by hand (ring, shaft, crossbar, bowl).
let ax = badgeCenter.x
let ay = badgeCenter.y
NSColor.white.setStroke()

let ring = NSBezierPath(ovalIn: NSRect(x: ax - 21, y: ay + 26, width: 42, height: 42))
ring.lineWidth = 15
ring.stroke()

let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: ax, y: ay + 26))
shaft.line(to: NSPoint(x: ax, y: ay - 62))
shaft.lineWidth = 15
shaft.lineCapStyle = .round
shaft.stroke()

let crossbar = NSBezierPath()
crossbar.move(to: NSPoint(x: ax - 36, y: ay + 2))
crossbar.line(to: NSPoint(x: ax + 36, y: ay + 2))
crossbar.lineWidth = 15
crossbar.lineCapStyle = .round
crossbar.stroke()

let bowl = NSBezierPath()
bowl.appendArc(withCenter: NSPoint(x: ax, y: ay - 14), radius: 48, startAngle: 205, endAngle: 335)
bowl.lineWidth = 15
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
