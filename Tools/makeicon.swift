import Cocoa

// 生成 App 图标：圆角渐变底 + 白色 gamecontroller 符号，输出 1024x1024 PNG
// 用法：makeicon <输出路径.png>

let size = 1024
let side = CGFloat(size)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current = context

let full = NSRect(x: 0, y: 0, width: side, height: side)

// 圆角矩形裁切后画渐变
let clip = NSBezierPath(roundedRect: full, xRadius: 226, yRadius: 226)
clip.addClip()
let gradient = NSGradient(colors: [
    NSColor(red: 0.42, green: 0.31, blue: 0.99, alpha: 1.0),   // 紫
    NSColor(red: 0.20, green: 0.55, blue: 0.98, alpha: 1.0)    // 蓝
])!
gradient.draw(in: full, angle: -90)

// 顶部一点高光
let gloss = NSGradient(colors: [
    NSColor(white: 1.0, alpha: 0.16),
    NSColor(white: 1.0, alpha: 0.0)
])!
gloss.draw(in: NSRect(x: 0, y: side * 0.55, width: side, height: side * 0.45), angle: -90)

// 白色手柄符号
if let symbol = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 620, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white]))
    if let styled = symbol.withSymbolConfiguration(config) {
        styled.draw(in: NSRect(x: 218, y: 218, width: 588, height: 588))
    }
}

NSGraphicsContext.current = nil

let data = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! data.write(to: URL(fileURLWithPath: out))
print("已生成 \(out)")
