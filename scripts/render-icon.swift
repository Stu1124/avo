#!/usr/bin/env swift
// Renders design/avo-icon.svg and design/avo-mark.svg into every raster the app ships:
//   Avo/Resources/Avo.icns
//   Avo/Resources/Assets.xcassets/AppIcon.appiconset/*.png
//   Avo/Resources/Assets.xcassets/MenuBarIcon.imageset/*.png  (template, 18 pt)
// Working files land in /tmp/avo-icon; nothing outside the repo is written back.
//
//   swift scripts/render-icon.swift
//
// NSImage decodes SVG natively on macOS 13+. If that ever stops working the script
// falls back to `qlmanage -t` and says so.
//
// Geometry lives in the SVGs. This script measures the glyph's ink bounds out of a
// rendered avo-mark.svg rather than repeating its numbers, so moving a point in the SVG
// does not silently break the menu bar crop.

import AppKit
import Foundation

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = URL(fileURLWithPath: "/tmp/avo-icon")
let iconset = work.appendingPathComponent("Avo.iconset")
let review = work.appendingPathComponent("review")
let fm = FileManager.default

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("render-icon: " + message + "\n").utf8))
    exit(1)
}

func makeDir(_ url: URL) {
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
}

@discardableResult
func run(_ launchPath: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    do {
        try p.run()
    } catch {
        // Reading terminationStatus on a Process that never launched traps, so bail here.
        die("could not launch \(launchPath): \(error)")
    }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - Loading

/// Loads an SVG as a resolution-independent NSImage. Returns the path that worked.
func loadVector(_ url: URL) -> (image: NSImage, path: String) {
    if let img = NSImage(contentsOf: url), img.size.width > 0 {
        // A vector rep scales cleanly; a bitmap rep does not. Both load, so check.
        let vector = img.representations.contains { !($0 is NSBitmapImageRep) }
        if vector { return (img, "NSImage(contentsOf:) vector") }
    }
    // Fallback: Quick Look renders the SVG to a 2048 px PNG we then downsample.
    let out = work.appendingPathComponent("ql")
    makeDir(out)
    _ = run("/usr/bin/qlmanage", ["-t", "-s", "2048", "-o", out.path, url.path])
    let png = out.appendingPathComponent(url.lastPathComponent + ".png")
    guard let img = NSImage(contentsOf: png) else { die("could not rasterize \(url.lastPathComponent)") }
    return (img, "qlmanage -t -s 2048")
}

// MARK: - Rasterizing

func blankRep(_ width: Int, _ height: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)
    else { die("could not allocate a \(width)x\(height) bitmap") }
    rep.size = NSSize(width: width, height: height)
    return rep
}

func blankRep(_ size: Int) -> NSBitmapImageRep { blankRep(size, size) }

func draw(into rep: NSBitmapImageRep, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    body()
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
}

/// Square render of a full 1024-grid artwork.
func square(_ image: NSImage, _ size: Int) -> NSBitmapImageRep {
    let rep = blankRep(size)
    draw(into: rep) {
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
    return rep
}

/// The glyph's ink bounds, in 1024-grid units, measured off a render of the artwork rather
/// than copied out of the SVG. Origin is the top left, y down, matching SVG coordinates.
func inkBounds(_ image: NSImage) -> CGRect {
    let n = 1024
    let rep = square(image, n)
    guard let data = rep.bitmapData else { die("could not read back the mark render") }
    let row = rep.bytesPerRow, spp = rep.samplesPerPixel
    var minX = n, minY = n, maxX = -1, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where data[y * row + x * spp + 3] > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { die("the mark render is empty") }
    return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                  width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
}

/// Glyph-only render fitted into `size` with `inset` of clear space on every side, then
/// flattened to black-with-alpha for a template image. `glyph` is the ink rect on the 1024 grid.
func templateGlyph(_ image: NSImage, _ size: Int, inset: CGFloat, glyph: CGRect) -> NSBitmapImageRep {
    let box = CGFloat(size) - 2 * inset
    let s = min(box / glyph.width, box / glyph.height)
    let rep = blankRep(size)
    draw(into: rep) {
        // The context is y-up; the glyph's ink rect is y-down, so its bottom edge sits at
        // 1024 - maxY of the grid.
        let originX = (CGFloat(size) - glyph.width * s) / 2 - glyph.minX * s
        let originY = (CGFloat(size) - glyph.height * s) / 2 - (1024 - glyph.maxY) * s
        image.draw(in: NSRect(x: originX, y: originY, width: 1024 * s, height: 1024 * s),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
    // Premultiplied RGBA: zeroing the colour channels leaves a pure-black mask.
    if let data = rep.bitmapData {
        let row = rep.bytesPerRow, spp = rep.samplesPerPixel
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = data + y * row + x * spp
                p[0] = 0; p[1] = 0; p[2] = 0
            }
        }
    }
    return rep
}

/// Nearest-neighbour magnification, so a 16 px render can be inspected as the pixels it is
/// rather than as whatever a smoothing resampler makes of them.
func zoom(_ rep: NSBitmapImageRep, _ factor: Int) -> NSBitmapImageRep {
    let w = rep.pixelsWide * factor, h = rep.pixelsHigh * factor
    let out = blankRep(w, h)
    guard let src = rep.bitmapData, let dst = out.bitmapData else { die("zoom: no bitmap data") }
    let sRow = rep.bytesPerRow, sSpp = rep.samplesPerPixel
    let dRow = out.bytesPerRow, dSpp = out.samplesPerPixel
    for y in 0..<h {
        for x in 0..<w {
            let s = src + (y / factor) * sRow + (x / factor) * sSpp
            let d = dst + y * dRow + x * dSpp
            for c in 0..<min(sSpp, dSpp) { d[c] = s[c] }
        }
    }
    return out
}

func write(_ rep: NSBitmapImageRep, to url: URL) {
    guard let png = rep.representation(using: .png, properties: [:]) else { die("PNG encode failed for \(url.lastPathComponent)") }
    do { try png.write(to: url) } catch { die("could not write \(url.path): \(error)") }
}

// MARK: - Run

try? fm.removeItem(at: work)
makeDir(iconset)
makeDir(review)

let icon = loadVector(repoRoot.appendingPathComponent("design/avo-icon.svg"))
let mark = loadVector(repoRoot.appendingPathComponent("design/avo-mark.svg"))
print("icon render path: \(icon.path)")
print("mark render path: \(mark.path)")

let glyphBounds = inkBounds(mark.image)
print("glyph ink bounds on the 1024 grid: \(Int(glyphBounds.minX)),\(Int(glyphBounds.minY)) "
      + "\(Int(glyphBounds.width))x\(Int(glyphBounds.height))")

// Simplified artwork for the slots where the master cannot survive: at 16 and 32 px the whole
// tile is 13 and 26 px across, and the master's strokes land on fractions of a pixel. The small
// artwork is the same mark drawn heavier and larger in the tile. Optional - if the file is not
// there, every slot renders the master.
let smallArtworkMaxSize = 16
let smallSVG = repoRoot.appendingPathComponent("design/avo-icon-small.svg")
let smallArtwork: NSImage? = fm.fileExists(atPath: smallSVG.path) ? loadVector(smallSVG).image : nil
if smallArtwork != nil { print("small artwork: design/avo-icon-small.svg for sizes <= \(smallArtworkMaxSize)") }

// .iconset -> .icns
// (iconset filename, asset-catalog filename, pixel size)
let iconVariants: [(String, String, Int)] = [
    ("icon_16x16.png", "icon_16x16@1x.png", 16),
    ("icon_16x16@2x.png", "icon_16x16@2x.png", 32),
    ("icon_32x32.png", "icon_32x32@1x.png", 32),
    ("icon_32x32@2x.png", "icon_32x32@2x.png", 64),
    ("icon_128x128.png", "icon_128x128@1x.png", 128),
    ("icon_128x128@2x.png", "icon_128x128@2x.png", 256),
    ("icon_256x256.png", "icon_256x256@1x.png", 256),
    ("icon_256x256@2x.png", "icon_256x256@2x.png", 512),
    ("icon_512x512.png", "icon_512x512@1x.png", 512),
    ("icon_512x512@2x.png", "icon_512x512@2x.png", 1024),
]

var cache: [Int: NSBitmapImageRep] = [:]
func iconRep(_ size: Int) -> NSBitmapImageRep {
    if let r = cache[size] { return r }
    let source = (size <= smallArtworkMaxSize ? smallArtwork : nil) ?? icon.image
    let r = square(source, size)
    cache[size] = r
    return r
}
// The asset catalog uses @1x/@2x filenames; the same pixels, different names.
let appicon = repoRoot.appendingPathComponent("Avo/Resources/Assets.xcassets/AppIcon.appiconset")
makeDir(appicon)
for (isetName, catalogName, size) in iconVariants {
    write(iconRep(size), to: iconset.appendingPathComponent(isetName))
    write(iconRep(size), to: appicon.appendingPathComponent(catalogName))
}

// Menu bar template, 18 pt. The status item is square, so a wide mark is limited by width,
// not height: 1 pt of clear space on every side is as much as it can afford and still put
// enough pixels across the three bars. templateGlyph centres it vertically in the square.
let menubar = repoRoot.appendingPathComponent("Avo/Resources/Assets.xcassets/MenuBarIcon.imageset")
makeDir(menubar)
let mb1 = templateGlyph(mark.image, 18, inset: 1, glyph: glyphBounds)
let mb2 = templateGlyph(mark.image, 36, inset: 2, glyph: glyphBounds)
write(mb1, to: menubar.appendingPathComponent("menubar-18.png"))
write(mb2, to: menubar.appendingPathComponent("menubar-18@2x.png"))

// Sizes to eyeball, exactly the pixels that ship. 64 is not an iconset size but is the
// cleanest read of the glyph.
for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(iconRep(size), to: review.appendingPathComponent("icon-\(size).png"))
}
write(zoom(iconRep(16), 20), to: review.appendingPathComponent("zoom-16.png"))
write(zoom(iconRep(32), 10), to: review.appendingPathComponent("zoom-32.png"))
write(zoom(iconRep(64), 5), to: review.appendingPathComponent("zoom-64.png"))
write(mb2, to: review.appendingPathComponent("menubar-36.png"))
write(zoom(mb1, 20), to: review.appendingPathComponent("zoom-mb18.png"))

// .icns
let icns = repoRoot.appendingPathComponent("Avo/Resources/Avo.icns")
if run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path]) != 0 {
    die("iconutil failed")
}
print("wrote \(icns.path)")
print("review PNGs in \(review.path)")
