import AppKit

// 生成 1024x1024 的应用图标

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let canvas: CGFloat = 1024

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

let inset: CGFloat = 58
let rect = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let rounded = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)

NSGraphicsContext.current?.saveGraphicsState()
rounded.addClip()

let gradient = NSGradient(starting: NSColor(srgbRed: 0.32, green: 0.52, blue: 1.0, alpha: 1),
                          ending: NSColor(srgbRed: 0.55, green: 0.22, blue: 0.88, alpha: 1))!
gradient.draw(in: rect, angle: -68)

// 顶部高光
let highlight = NSBezierPath(ovalIn: NSRect(x: rect.minX - 140, y: rect.maxY - 460,
                                            width: rect.width + 280, height: 560))
NSColor.white.withAlphaComponent(0.13).setFill()
highlight.fill()

NSGraphicsContext.current?.restoreGraphicsState()

// 白色垃圾桶
if let base = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: nil),
   let symbol = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)) {
    let symbolSize = symbol.size
    let tinted = NSImage(size: symbolSize)
    tinted.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbolSize))
    NSColor.white.set()
    NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
    tinted.unlockFocus()

    let targetWidth: CGFloat = 470
    let scale = targetWidth / symbolSize.width
    let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
    let origin = NSPoint(x: (canvas - drawSize.width) / 2, y: (canvas - drawSize.height) / 2 + 6)
    tinted.draw(in: NSRect(origin: origin, size: drawSize))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("图标生成失败\n".data(using: .utf8)!)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: output))
    print("图标已生成：\(output)")
} catch {
    FileHandle.standardError.write("写入失败：\(error)\n".data(using: .utf8)!)
    exit(1)
}
