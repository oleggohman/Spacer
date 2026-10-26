// Draws the Spacer app icon and writes the PNGs of an .iconset folder.
//
// Usage: swift scripts/make-icon.swift <out-dir>
//
// The icon is described once, as vectors on a 1024 px canvas, and drawn again at each size, so
// the 16 px image is not a scaled copy of the 1024 px one. The colors are fixed here, because
// this script runs on its own and the icon keeps its own navy, separate from the app's palette.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The canvas the icon is designed on. Each PNG is drawn at scale = pixels / canvas.
let canvas: CGFloat = 1024

/// Apple's icon grid: the tile is 824 px, centered, so it has a 100 px margin.
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileCornerRadius: CGFloat = 185

/// The content inset inside the tile, and the gap between neighboring blocks.
let contentInset: CGFloat = 70
let blockGap: CGFloat = 14
let blockCornerRadius: CGFloat = 22

struct Rgb {
  var r: CGFloat
  var g: CGFloat
  var b: CGFloat

  init(r: CGFloat, g: CGFloat, b: CGFloat) {
    self.r = r
    self.g = g
    self.b = b
  }

  /// A color from a 0xRRGGBB value.
  static func hex(_ value: UInt32) -> Rgb {
    Rgb(
      r: CGFloat((value >> 16) & 0xff) / 255, g: CGFloat((value >> 8) & 0xff) / 255,
      b: CGFloat(value & 0xff) / 255)
  }

  /// This color moved toward `other` by `amount` (0 keeps this color, 1 gives `other`).
  func mixed(with other: Rgb, by amount: CGFloat) -> Rgb {
    Rgb(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
  }

  var cgColor: CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
  }
}

let navyTop = Rgb.hex(0x0e1e4d)  // icon navy (top)
let navyBottom = Rgb.hex(0x08122f)
let white = Rgb.hex(0xffffff)
let black = Rgb.hex(0x000000)

/// One treemap block: its color and its place in the 684 px content square (top-left origin,
/// before the inset). The six blocks tile that square exactly: a half-width block on the left
/// and a 2 x 3 arrangement of smaller blocks on the right.
struct Block {
  let color: Rgb
  let x: CGFloat
  let y: CGFloat
  let width: CGFloat
  let height: CGFloat
}

let blocks: [Block] = [
  Block(color: .hex(0x2fa8f7), x: 0, y: 0, width: 342, height: 684),  // blue, largest
  Block(color: .hex(0x5d77f9), x: 342, y: 0, width: 140, height: 300),  // purple
  Block(color: .hex(0xaf85f5), x: 482, y: 0, width: 202, height: 300),  // pink
  Block(color: .hex(0x22c3c9), x: 342, y: 300, width: 202, height: 200),  // map teal
  Block(color: .hex(0x3fbf7f), x: 544, y: 300, width: 140, height: 200),  // map green
  Block(color: .hex(0xf8a23a), x: 342, y: 500, width: 342, height: 184),  // orange
]

/// A continuous-corner rectangle. Each corner is a superellipse (exponent 5) rather than a
/// circular arc, which gives the smooth "squircle" outline of the macOS icon grid.
func squircle(_ rect: CGRect, radius r: CGFloat) -> CGPath {
  let exponent: CGFloat = 5
  let steps = 64
  // Each corner: its center, the direction it bulges toward, and the sweep of its angle.
  // Walking the four corners in order (right, top, left, bottom) keeps the outline closed.
  let corners: [(cx: CGFloat, cy: CGFloat, sx: CGFloat, sy: CGFloat, reversed: Bool)] = [
    (rect.maxX - r, rect.maxY - r, 1, 1, false),
    (rect.minX + r, rect.maxY - r, -1, 1, true),
    (rect.minX + r, rect.minY + r, -1, -1, false),
    (rect.maxX - r, rect.minY + r, 1, -1, true),
  ]
  let path = CGMutablePath()
  var first = true
  for corner in corners {
    for i in 0...steps {
      let t = CGFloat(corner.reversed ? steps - i : i) / CGFloat(steps) * (.pi / 2)
      let x = corner.cx + corner.sx * r * pow(abs(cos(t)), 2 / exponent)
      let y = corner.cy + corner.sy * r * pow(abs(sin(t)), 2 / exponent)
      if first {
        path.move(to: CGPoint(x: x, y: y))
        first = false
      } else {
        path.addLine(to: CGPoint(x: x, y: y))
      }
    }
  }
  path.closeSubpath()
  return path
}

/// Fills `path` with a linear gradient from the top-left corner of `rect` to the bottom-right.
/// Core Graphics has y up, so the top of the rect is its maxY.
func fillGradient(
  _ ctx: CGContext, path: CGPath, rect: CGRect, from start: Rgb, to end: Rgb
) {
  let colors = [start.cgColor, end.cgColor] as CFArray
  guard let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: nil) else { return }
  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()
  ctx.drawLinearGradient(
    gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  ctx.restoreGState()
}

/// Draws the whole icon at `pixels` x `pixels`.
func drawIcon(_ ctx: CGContext, pixels: Int) {
  let scale = CGFloat(pixels) / canvas
  ctx.scaleBy(x: scale, y: scale)

  // Tile with a drop shadow. Shadow offset and blur are not affected by the context scale,
  // so they are scaled by hand.
  let tile = squircle(tileRect, radius: tileCornerRadius)
  ctx.saveGState()
  ctx.setShadow(
    offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale,
    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
  ctx.addPath(tile)
  ctx.setFillColor(navyTop.cgColor)
  ctx.fillPath()
  ctx.restoreGState()

  // Navy gradient: lighter at the top, darker at the bottom.
  ctx.saveGState()
  ctx.addPath(tile)
  ctx.clip()
  let navyColors = [navyTop.cgColor, navyBottom.cgColor] as CFArray
  if let navy = CGGradient(colorsSpace: nil, colors: navyColors, locations: nil) {
    ctx.drawLinearGradient(
      navy, start: CGPoint(x: canvas / 2, y: tileRect.maxY),
      end: CGPoint(x: canvas / 2, y: tileRect.minY), options: [])
  }
  ctx.restoreGState()

  // Treemap blocks. The layout is top-left based, so each y is flipped into Core Graphics
  // space. The gap is split between neighbors: each block is inset by half of it.
  let origin = tileRect.minX + contentInset
  for block in blocks {
    let top = origin + block.y
    let rect = CGRect(
      x: origin + block.x + blockGap / 2,
      y: canvas - (top + block.height) + blockGap / 2,
      width: block.width - blockGap,
      height: block.height - blockGap)
    let path = CGPath(
      roundedRect: rect, cornerWidth: blockCornerRadius, cornerHeight: blockCornerRadius,
      transform: nil)
    // Cushion: lighter at the top-left, slightly darker at the bottom-right.
    fillGradient(
      ctx, path: path, rect: rect, from: block.color.mixed(with: white, by: 0.22),
      to: block.color.mixed(with: black, by: 0.12))
  }
}

/// Renders the icon at `pixels` square and writes it as a PNG.
func writePNG(pixels: Int, to url: URL) throws {
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  guard
    let ctx = CGContext(
      data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else {
    throw CocoaError(.fileWriteUnknown)
  }
  drawIcon(ctx, pixels: pixels)
  guard let image = ctx.makeImage(),
    let dest = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else {
    throw CocoaError(.fileWriteUnknown)
  }
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

// The standard .iconset names and their pixel sizes.
let iconsetSizes: [(name: String, pixels: Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <out-dir>\n".utf8))
  exit(2)
}
let outDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for size in iconsetSizes {
  try writePNG(pixels: size.pixels, to: outDir.appendingPathComponent(size.name))
}
print("Wrote \(iconsetSizes.count) PNGs to \(outDir.path)")
