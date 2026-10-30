// Screenshot Rake: Custodian Cashew the squirrel rakes stray screenshots off your desktop
// and hauls them, a few at a time, into a "Leaf Pile" folder.

import AppKit
import ImageIO
import QuartzCore

// MARK: - Options

struct Options {
    var dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    var speed = 1.0
    var limit: Int?
    var once = false
    var dryRun = false
    var mess: Int?
    var unrake = false
}

func usage() -> Never {
    print("""
    usage: ./rake [options]
      --dir PATH     folder to rake (default: ~/Desktop)
      --speed X      animation speed multiplier (default: 1)
      --limit N      rake at most N screenshots
      --once         rake once and quit instead of staying in the menu bar
      --dry-run      play the animation without moving any files
      --mess N       create N fake screenshots in the folder, then exit
      --unrake       move everything out of Leaf Pile and scatter it, then exit
    """)
    exit(0)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func value() -> String {
        guard !args.isEmpty else { usage() }
        return args.removeFirst()
    }
    while !args.isEmpty {
        switch args.removeFirst() {
        case "--dir": o.dir = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath)
        case "--speed": o.speed = max(0.1, Double(value()) ?? 1)
        case "--limit": o.limit = Int(value())
        case "--once": o.once = true
        case "--dry-run": o.dryRun = true
        case "--mess": o.mess = Int(value()) ?? 12
        case "--unrake": o.unrake = true
        default: usage()
        }
    }
    return o
}

let opts = parseOptions()
let fm = FileManager.default
let pileName = "Leaf Pile"
let pileURL = opts.dir.appendingPathComponent(pileName)
let isDesktop = opts.dir.standardizedFileURL.path
    == fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").standardizedFileURL.path

// MARK: - Finder (desktop icon positions)

enum Finder {
    @discardableResult
    static func run(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Icon centers of everything on the desktop, in top-left-origin screen points.
    static func positions() -> [String: CGPoint] {
        let script = """
        set out to ""
        tell application "Finder"
            repeat with i in (get items of desktop)
                set p to desktop position of i
                set out to out & (name of i) & tab & (item 1 of p) & tab & (item 2 of p) & linefeed
            end repeat
        end tell
        return out
        """
        var result: [String: CGPoint] = [:]
        for line in (run(script) ?? "").split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) else { continue }
            result[String(parts[0])] = CGPoint(x: x, y: y)
        }
        return result
    }

    @discardableResult
    static func setPosition(_ name: String, _ p: CGPoint) -> Bool {
        run("tell application \"Finder\" to set desktop position of item \(quoted(name)) of desktop to {\(Int(p.x)), \(Int(p.y))}") != nil
    }
}

// MARK: - Files

let screenshotPrefixes: [String] = {
    var p = ["screenshot", "screen shot", "cleanshot"]
    if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "name"), !custom.isEmpty {
        p.append(custom.lowercased())
    }
    return p
}()
let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

func findScreenshots() -> [URL] {
    let urls = (try? fm.contentsOfDirectory(at: opts.dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return urls.filter { u in
        let n = u.lastPathComponent.lowercased()
        return imageExts.contains(u.pathExtension.lowercased()) && screenshotPrefixes.contains { n.hasPrefix($0) }
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func pileContents() -> [URL] {
    (try? fm.contentsOfDirectory(at: pileURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
}

// MARK: - Settings (menu bar choices, remembered between launches)

enum BatchMode: String, CaseIterable {
    case randomFew, oldest10, all

    var title: String {
        switch self {
        case .randomFew: return "Randomly a few"
        case .oldest10: return "Oldest 10"
        case .all: return "All"
        }
    }
}

enum Settings {
    static let defaults = UserDefaults.standard
    static let repeatChoices: [(hours: Double, title: String)] = [
        (0, "Off"), (6, "Every 6 hours"), (12, "Every 12 hours"), (24, "Every day"), (168, "Every week"),
    ]

    static var batch: BatchMode {
        get { BatchMode(rawValue: defaults.string(forKey: "batch") ?? "") ?? .all }
        set { defaults.set(newValue.rawValue, forKey: "batch") }
    }
    /// 0 means off.
    static var repeatHours: Double {
        get { defaults.double(forKey: "repeatHours") }
        set { defaults.set(newValue, forKey: "repeatHours") }
    }
    static var lastRake: Date? {
        get { defaults.object(forKey: "lastRake") as? Date }
        set { defaults.set(newValue, forKey: "lastRake") }
    }
    static var nextRake: Date? {
        guard repeatHours > 0 else { return nil }
        return (lastRake ?? Date()).addingTimeInterval(repeatHours * 3600)
    }
}

/// The screenshots to rake this run, per the batch setting.
func pickScreenshots() -> [URL] {
    var urls = findScreenshots()
    switch Settings.batch {
    case .randomFew:
        urls = Array(urls.shuffled().prefix(Int.random(in: 3...5)))
    case .oldest10:
        func created(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast }
        urls = Array(urls.sorted { created($0) < created($1) }.prefix(10))
    case .all:
        break
    }
    return Array(urls.prefix(opts.limit ?? Int.max))
}

func thumbnail(_ url: URL, maxPixels: Int = 240) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let o: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
}

func uniqueURL(_ url: URL) -> URL {
    guard fm.fileExists(atPath: url.path) else { return url }
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    var n = 2
    while true {
        let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        n += 1
    }
}

// MARK: - Drawing helpers

struct SeededRNG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let leafColors = [
    rgb(0.85, 0.36, 0.12), rgb(0.93, 0.62, 0.15), rgb(0.72, 0.18, 0.12),
    rgb(0.58, 0.32, 0.12), rgb(0.95, 0.76, 0.26),
]

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var length: CGFloat { hypot(x, y) }
    var normalized: CGPoint { let l = max(length, 0.0001); return CGPoint(x: x / l, y: y / l) }
    func distance(to p: CGPoint) -> CGFloat { (self - p).length }
}

func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { a + (b - a) * t }

func leafPath(_ size: CGFloat, maple: Bool) -> CGPath {
    let p = CGMutablePath()
    if maple {
        for i in 0..<10 {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let r = i % 2 == 0 ? size : size * 0.5
            let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
    } else {
        p.move(to: CGPoint(x: 0, y: -size))
        p.addQuadCurve(to: CGPoint(x: 0, y: size), control: CGPoint(x: size * 0.95, y: 0))
        p.addQuadCurve(to: CGPoint(x: 0, y: -size), control: CGPoint(x: -size * 0.95, y: 0))
    }
    return p
}

func drawLeaf(_ ctx: CGContext, at p: CGPoint, size: CGFloat, rot: CGFloat, color: CGColor, maple: Bool, alpha: CGFloat = 1) {
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y)
    ctx.rotate(by: rot)
    ctx.setAlpha(alpha)
    ctx.addPath(leafPath(size, maple: maple))
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.setStrokeColor(rgb(0.35, 0.18, 0.08, 0.55))
    ctx.setLineWidth(max(0.8, size * 0.08))
    ctx.move(to: CGPoint(x: 0, y: -size * 0.6))
    ctx.addLine(to: CGPoint(x: 0, y: size * 1.25))
    ctx.strokePath()
    ctx.restoreGState()
}

func cardSize(_ img: CGImage?, maxSide: CGFloat) -> CGSize {
    guard let img, img.width > 0, img.height > 0 else { return CGSize(width: maxSide, height: maxSide * 0.65) }
    let aspect = CGFloat(img.width) / CGFloat(img.height)
    return aspect >= 1 ? CGSize(width: maxSide, height: maxSide / aspect) : CGSize(width: maxSide * aspect, height: maxSide)
}

/// A photo with a white border, centered at `center`. Works in a flipped (y-down) context.
func drawCard(_ ctx: CGContext, _ img: CGImage?, center: CGPoint, size: CGSize, rot: CGFloat = 0, alpha: CGFloat = 1) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: rot)
    ctx.setAlpha(alpha)
    let r = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: rgb(0, 0, 0, 0.3))
    ctx.setFillColor(.white)
    ctx.fill(r)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    let inset = max(1.5, size.width * 0.05)
    let inner = r.insetBy(dx: inset, dy: inset)
    if let img {
        ctx.saveGState()
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: inner)
        ctx.restoreGState()
    } else {
        ctx.setFillColor(rgb(0.62, 0.78, 0.92))
        ctx.fill(inner)
    }
    ctx.restoreGState()
}

func makePileIcon() -> NSImage {
    NSImage(size: NSSize(width: 512, height: 512), flipped: true) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        var rng = SeededRNG(s: 7)
        func leaves(_ count: Int, minDepth: Double) {
            for _ in 0..<count {
                let u = Double.random(in: -1...1, using: &rng)
                let top = 440 - (1 - u * u) * 250
                let y = top + Double.random(in: minDepth...1, using: &rng) * (445 - top)
                drawLeaf(ctx, at: CGPoint(x: 256 + u * 215, y: y),
                         size: .random(in: 26...40, using: &rng), rot: .random(in: 0...(2 * .pi), using: &rng),
                         color: leafColors.randomElement(using: &rng)!, maple: Bool.random(using: &rng))
            }
        }
        ctx.setFillColor(rgb(0, 0, 0, 0.16))
        ctx.fillEllipse(in: CGRect(x: 36, y: 420, width: 440, height: 56))
        leaves(150, minDepth: 0)
        for (center, rot) in [(CGPoint(x: 190, y: 250), -0.35), (CGPoint(x: 320, y: 235), 0.28)] {
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: rot)
            let r = CGRect(x: -80, y: -56, width: 160, height: 112)
            ctx.setFillColor(.white)
            ctx.fill(r)
            ctx.setFillColor(rgb(0.62, 0.78, 0.92))
            ctx.fill(r.insetBy(dx: 9, dy: 9))
            ctx.setFillColor(rgb(0.95, 0.95, 0.97))
            ctx.fill(CGRect(x: -64, y: -40, width: 128, height: 18))
            ctx.restoreGState()
        }
        leaves(110, minDepth: 0.35)
        return true
    }
}

// MARK: - Sprites

/// Illustrated squirrel frames cut from art/sprite-sheet.png. Every frame shares one
/// canvas, with the feet at `anchor`.
enum Sprites {
    static let names = ["walk1", "walk2", "rake1", "rake2", "carry1", "carry2", "idle", "cheer"]
    static let anchor = CGPoint(x: 257, y: 365)
    /// Sprite pixels per squirrel unit.
    static let unit: CGFloat = 0.30

    static let dir: URL? = {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return [
            exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("art/frames"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("art/frames"),
        ].first { fm.fileExists(atPath: $0.appendingPathComponent("idle.png").path) }
    }()

    static let frames: [String: CGImage] = {
        guard let dir else { return [:] }
        var result: [String: CGImage] = [:]
        for name in names {
            let url = dir.appendingPathComponent("\(name).png")
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                result[name] = img
            }
        }
        return result
    }()
}

// MARK: - Fake screenshots (--mess)

func makeFakeScreenshot(_ rng: inout SystemRandomNumberGenerator) -> Data? {
    let w = 1440, h = 900
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    let ctx = gctx.cgContext
    let bgs = [rgb(0.93, 0.89, 0.84), rgb(0.86, 0.91, 0.95), rgb(0.90, 0.93, 0.87), rgb(0.95, 0.88, 0.90)]
    ctx.setFillColor(bgs.randomElement(using: &rng)!)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let win = CGRect(x: 140, y: 90, width: 1160, height: 720)
    ctx.setFillColor(.white)
    ctx.fill(win)
    ctx.setFillColor(rgb(0.92, 0.92, 0.93))
    ctx.fill(CGRect(x: win.minX, y: win.maxY - 44, width: win.width, height: 44))
    for (i, c) in [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.79, 0.25)].enumerated() {
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: win.minX + 18 + CGFloat(i) * 22, y: win.maxY - 29, width: 14, height: 14))
    }
    let accent = [rgb(0.35, 0.55, 0.95), rgb(0.95, 0.55, 0.30), rgb(0.40, 0.75, 0.55), rgb(0.70, 0.45, 0.85)].randomElement(using: &rng)!
    ctx.setFillColor(accent)
    ctx.fill(CGRect(x: win.minX + 40, y: win.maxY - 130, width: .random(in: 300...600, using: &rng), height: 40))
    var y = win.maxY - 180
    while y > win.minY + 260 {
        ctx.setFillColor(rgb(0.80, 0.80, 0.82))
        ctx.fill(CGRect(x: win.minX + 40, y: y, width: .random(in: 400...1000, using: &rng), height: 14))
        y -= 30
    }
    ctx.setFillColor(accent.copy(alpha: 0.35)!)
    for i in 0..<3 {
        ctx.fill(CGRect(x: win.minX + 40 + CGFloat(i) * 365, y: win.minY + 40, width: 335, height: 190))
    }
    gctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

func randomScatterSpot(screen: CGSize, avoid: [CGPoint]) -> CGPoint {
    var best = CGPoint(x: screen.width / 2, y: screen.height / 2)
    for _ in 0..<80 {
        let p = CGPoint(x: .random(in: 120...(screen.width - 120)), y: .random(in: 130...(screen.height - 170)))
        best = p
        if avoid.allSatisfy({ $0.distance(to: p) > 110 }) { return p }
    }
    return best
}

func runMess(_ count: Int, screen: CGSize) {
    var rng = SystemRandomNumberGenerator()
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    let day = df.string(from: Date())
    var names: [String] = []
    for _ in 0..<count {
        let hour = Int.random(in: 1...12), min = Int.random(in: 0...59), sec = Int.random(in: 0...59)
        let ampm = Bool.random() ? "AM" : "PM"
        let name = "Screenshot \(day) at \(hour).\(String(format: "%02d", min)).\(String(format: "%02d", sec)) \(ampm).png"
        let url = uniqueURL(opts.dir.appendingPathComponent(name))
        guard let data = makeFakeScreenshot(&rng), (try? data.write(to: url)) != nil else { continue }
        names.append(url.lastPathComponent)
    }
    print("Made \(names.count) fake screenshots in \(opts.dir.path)")
    if isDesktop { scatterOnDesktop(names, screen: screen) }
}

func scatterOnDesktop(_ names: [String], screen: CGSize) {
    guard !names.isEmpty else { return }
    var taken = Array(Finder.positions().filter { !names.contains($0.key) }.values)
    usleep(800_000)
    for name in names {
        let p = randomScatterSpot(screen: screen, avoid: taken)
        taken.append(p)
        for _ in 0..<10 where !Finder.setPosition(name, p) { usleep(200_000) }
    }
}

func runUnrake(screen: CGSize) {
    var names: [String] = []
    for u in pileContents() {
        let dest = uniqueURL(opts.dir.appendingPathComponent(u.lastPathComponent))
        if (try? fm.moveItem(at: u, to: dest)) != nil { names.append(dest.lastPathComponent) }
    }
    print("Unraked \(names.count) files back into \(opts.dir.path)")
    if isDesktop { scatterOnDesktop(names, screen: screen) }
}

// MARK: - Scene objects

final class Item {
    let url: URL
    let name: String
    var pos: CGPoint
    let thumb: CGImage?
    var onGround = true
    var beingRaked = false
    var jiggle: CGFloat = 0

    init(url: URL, pos: CGPoint) {
        self.url = url
        self.name = url.lastPathComponent
        self.pos = pos
        self.thumb = thumbnail(url)
    }
}

struct Flyer {
    var img: CGImage?
    var from: CGPoint
    var to: () -> CGPoint
    var fromSize: CGSize
    var toSize: CGSize
    var t: Double
    var dur: Double
    var arc: CGFloat
    var rot: CGFloat
    var onArrive: () -> Void
}

struct Leaf {
    var p: CGPoint
    var v: CGPoint
    var rot: CGFloat
    var vr: CGFloat
    var age: Double = 0
    var life: Double
    var size: CGFloat
    var color: CGColor
    var maple: Bool
    var drift: Bool
    var sway: Double
}

struct FloatText {
    var text: String
    var p: CGPoint
    var t: Double = 0
}

enum Pose { case drag, rake, carry, idle, cheer }

enum Action {
    case walkTo(CGPoint)
    case approach(Item)
    case rake(Item)
    case walkToPile
    case dump
    case say(String, Double)
    case cheer
    case exit
}

// MARK: - Stage

final class Stage: NSView {
    override var isFlipped: Bool { true }

    let S: CGFloat = 1.15
    let walkSpeed: CGFloat = 280
    let rakeDuration = 1.4

    var W: CGFloat { bounds.width }
    var H: CGFloat { bounds.height }

    let pileIcon = makePileIcon()
    var pile = CGPoint.zero
    var pileIsOnDesktop = false

    var items: [Item] = []
    var actions: [Action] = []
    var current: Action?
    var actionT = 0.0
    var actionFlag = false
    var walkTarget = CGPoint.zero
    var dumpDuration = 0.0

    var pos = CGPoint.zero
    var facing: CGFloat = 1
    var pose = Pose.drag
    var moving = false
    var walkPhase = 0.0
    var rakePhase = 0.0
    var hop: CGFloat = 0
    var displayFacing: CGFloat = 1
    var squash: CGFloat = 0
    var squashVel: CGFloat = 0
    var squashTarget: CGFloat = 0
    var carried: [(img: CGImage?, rot: CGFloat)] = []
    var bubble: String?

    var flyers: [Flyer] = []
    var leaves: [Leaf] = []
    var texts: [FloatText] = []
    var leafEmit = 0.0
    var ambientEmit = 0.0

    var time = 0.0
    var last = CACurrentMediaTime()
    var timer: Timer?
    var active = false
    var raked = 0
    var refreshing = false

    // MARK: Setup

    func start() {
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        let schedule = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.checkSchedule() }
        RunLoop.main.add(schedule, forMode: .common)
        beginRun()
    }

    func checkSchedule() {
        guard !active, let next = Settings.nextRake, Date() >= next else { return }
        if findScreenshots().isEmpty {
            Settings.lastRake = Date()
        } else {
            beginRun()
        }
    }

    func setupPile() {
        let spot = CGPoint(x: 110, y: H - 190)
        var created = false
        if !fm.fileExists(atPath: pileURL.path) && !opts.dryRun {
            created = (try? fm.createDirectory(at: pileURL, withIntermediateDirectories: true)) != nil
        }
        let exists = fm.fileExists(atPath: pileURL.path)
        if exists { NSWorkspace.shared.setIcon(pileIcon, forFile: pileURL.path, options: []) }
        pile = spot
        pileIsOnDesktop = isDesktop && exists
        guard pileIsOnDesktop else { return }
        if created {
            for _ in 0..<15 {
                if Finder.setPosition(pileName, spot) { break }
                usleep(200_000)
            }
        } else if let p = Finder.positions()[pileName] {
            pile = p
        }
    }

    func beginRun() {
        guard !active else { return }
        setupPile()
        let urls = pickScreenshots()
        let positions = isDesktop ? Finder.positions() : [:]
        var taken = [pile]
        items = urls.map { url in
            let p = positions[url.lastPathComponent] ?? randomScatterSpot(screen: bounds.size, avoid: taken)
            taken.append(p)
            return Item(url: url, pos: p)
        }
        raked = 0
        plan()
        active = true
        last = CACurrentMediaTime()
    }

    func plan() {
        let fromLeft = pile.x < W / 2
        pos = CGPoint(x: fromLeft ? -70 : W + 70, y: min(pile.y + 34, H - 40))
        facing = fromLeft ? 1 : -1
        let entry = CGPoint(x: fromLeft ? 140 : W - 140, y: pos.y)
        actions = [.walkTo(entry)]
        if items.isEmpty {
            actions += [.say("No screenshots to rake!", 2), .exit]
            return
        }
        actions.append(.say("Rake time! \(items.count) screenshot\(items.count == 1 ? "" : "s")", 1.6))
        var remaining = items
        var sim = entry
        while !remaining.isEmpty {
            let n = min(Int.random(in: 3...5), remaining.count)
            for _ in 0..<n {
                let i = remaining.indices.min { remaining[$0].pos.distance(to: sim) < remaining[$1].pos.distance(to: sim) }!
                let item = remaining.remove(at: i)
                actions += [.approach(item), .rake(item)]
                sim = item.pos
            }
            actions += [.walkToPile, .dump]
            sim = pile
        }
        actions += [.cheer, .say("All raked!", 1.6), .exit]
    }

    func standPoint(_ c: CGPoint) -> CGPoint {
        let off: CGFloat = 58 * S
        var side: CGFloat = pos.x <= c.x ? -1 : 1
        if c.x + side * off < 30 { side = 1 }
        if c.x + side * off > W - 30 { side = -1 }
        return CGPoint(x: c.x + side * off, y: min(c.y + 30, H - 10))
    }

    /// Where the carried stack sits, in squirrel units relative to the feet:
    /// over the photos in the paws while carrying, balanced on the cap while raking.
    var stackAnchor: CGPoint {
        pose == .carry || pose == .cheer ? CGPoint(x: 11, y: -40) : CGPoint(x: 13, y: -104)
    }

    /// World position of the top of the carried stack.
    var handPoint: CGPoint {
        let a = stackAnchor
        return CGPoint(x: pos.x + facing * a.x * S, y: pos.y - hop + (a.y - CGFloat(carried.count) * 2.5) * S)
    }

    // MARK: Files

    func moveFile(_ item: Item) {
        raked += 1
        guard !opts.dryRun else { return }
        do {
            try fm.moveItem(at: item.url, to: uniqueURL(pileURL.appendingPathComponent(item.name)))
        } catch {
            print("Couldn't move \(item.name): \(error.localizedDescription)")
        }
        refreshPositions()
    }

    /// Finder may re-flow icons after a file leaves (e.g. "Sort By" is on), so re-read positions in the background.
    func refreshPositions() {
        guard isDesktop, !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let positions = Finder.positions()
            DispatchQueue.main.async {
                self.refreshing = false
                for item in self.items where item.onGround && !item.beingRaked {
                    if let p = positions[item.name] { item.pos = p }
                }
                if let p = positions[pileName] { self.pile = p }
            }
        }
    }

    // MARK: Loop

    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - last, 1.0 / 20) * opts.speed
        last = now
        guard active || !leaves.isEmpty || !flyers.isEmpty || !texts.isEmpty else { return }
        time += dt
        if active {
            stepActions(dt)
            stepBody(dt)
        }
        stepEffects(dt)
        needsDisplay = true
    }

    func stepActions(_ dt: Double) {
        if current == nil {
            guard !actions.isEmpty else { return }
            current = actions.removeFirst()
            actionT = 0
            actionFlag = false
            bubble = nil
        }
        guard let action = current else { return }
        actionT += dt
        moving = false
        squashTarget = 0
        var done = false

        switch action {
        case .walkTo(let p):
            pose = carried.isEmpty ? .drag : .carry
            done = walk(to: p, dt)

        case .approach(let item):
            if !actionFlag { walkTarget = standPoint(item.pos); actionFlag = true }
            pose = carried.isEmpty ? .drag : .carry
            done = walk(to: walkTarget, dt)

        case .rake(let item):
            pose = .rake
            facing = item.pos.x >= pos.x ? 1 : -1
            item.beingRaked = true
            rakePhase += dt * 9.5
            item.jiggle = CGFloat(sin(rakePhase * 1.3)) * 3
            leafEmit -= dt
            if leafEmit <= 0 && actionT < rakeDuration - 0.3 {
                leafEmit = 0.045
                let R = (sin(rakePhase) > 0 ? 42 : 27) * S
                burst(at: CGPoint(x: pos.x + facing * R, y: pos.y - 4), count: 1, spread: facing)
            }
            if actionT >= rakeDuration - 0.8 && actionT < rakeDuration - 0.45 { squashTarget = -0.1 }
            if !actionFlag && actionT >= rakeDuration - 0.45 {
                actionFlag = true
                squashVel += 2.4
                item.onGround = false
                item.beingRaked = false
                moveFile(item)
                let rot = CGFloat.random(in: -0.25...0.25)
                flyers.append(Flyer(img: item.thumb, from: item.pos, to: { [unowned self] in self.handPoint },
                                    fromSize: cardSize(item.thumb, maxSide: 60), toSize: cardSize(item.thumb, maxSide: 23 * S),
                                    t: 0, dur: 0.4, arc: 50, rot: rot) { [unowned self] in
                    self.carried.append((item.thumb, rot))
                })
            }
            done = actionT >= rakeDuration

        case .walkToPile:
            if !actionFlag { walkTarget = standPoint(pile); actionFlag = true }
            pose = .carry
            done = walk(to: walkTarget, dt)

        case .dump:
            pose = .carry
            facing = pile.x >= pos.x ? 1 : -1
            if !actionFlag { squashTarget = -0.08 }
            if !actionFlag && actionT >= 0.15 {
                actionFlag = true
                squashVel += 2.2
                let cards = carried
                let start = handPoint
                carried = []
                for (i, card) in cards.enumerated() {
                    let last = i == cards.count - 1
                    let from = start - CGPoint(x: 0, y: CGFloat(i) * 4 * S)
                    flyers.append(Flyer(img: card.img, from: from, to: { [unowned self] in self.pile },
                                        fromSize: cardSize(card.img, maxSide: 23 * S), toSize: cardSize(card.img, maxSide: 16),
                                        t: -Double(i) * 0.09, dur: 0.5, arc: 90, rot: card.rot) { [unowned self] in
                        self.burst(at: self.pile, count: 5, spread: 0)
                        if last {
                            self.burst(at: self.pile, count: 18, spread: 0)
                            self.texts.append(FloatText(text: "+\(cards.count)", p: self.pile - CGPoint(x: 0, y: 40)))
                        }
                    })
                }
                dumpDuration = 0.15 + Double(cards.count) * 0.09 + 0.6
            }
            done = actionFlag && actionT >= dumpDuration

        case .say(let text, let duration):
            pose = .idle
            bubble = text
            done = actionT >= duration
            if done { bubble = nil }

        case .cheer:
            pose = .cheer
            if !actionFlag {
                actionFlag = true
                burst(at: pos - CGPoint(x: 0, y: 60 * S), count: 14, spread: 0)
            }
            hop = CGFloat(abs(sin(actionT * .pi / 0.45))) * 24
            squashTarget = hop < 5 ? -0.12 : 0.07
            done = actionT >= 1.35
            if done { hop = 0 }

        case .exit:
            let target = CGPoint(x: pos.x < W / 2 ? -90 : W + 90, y: pos.y)
            pose = .drag
            done = walk(to: target, dt)
            if done { finishRun() }
        }

        if done { current = nil }
    }

    func walk(to target: CGPoint, _ dt: Double) -> Bool {
        let d = target - pos
        let dist = d.length
        let stepLen = walkSpeed * CGFloat(dt)
        if abs(d.x) > 2 { facing = d.x > 0 ? 1 : -1 }
        if dist <= stepLen { pos = target; return true }
        moving = true
        walkPhase += dt * 14
        pos = pos + d.normalized * stepLen
        return false
    }

    func finishRun() {
        active = false
        Settings.lastRake = Date()
        let verb = opts.dryRun ? "Would have raked" : "Raked"
        print("\(verb) \(raked) screenshot\(raked == 1 ? "" : "s") into \(pileURL.path)")
        if opts.once {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
        }
    }

    // MARK: Effects

    func burst(at p: CGPoint, count: Int, spread: CGFloat) {
        for _ in 0..<count {
            let vx = spread == 0 ? CGFloat.random(in: -160...160) : spread * .random(in: 30...170)
            leaves.append(Leaf(p: p, v: CGPoint(x: vx, y: -.random(in: 130...300)),
                               rot: .random(in: 0...(2 * .pi)), vr: .random(in: -9...9),
                               life: .random(in: 0.9...1.5), size: .random(in: 4.5...8),
                               color: leafColors.randomElement()!, maple: .random(), drift: false, sway: 0))
        }
    }

    func stepEffects(_ dt: Double) {
        let fdt = CGFloat(dt)
        if active {
            ambientEmit -= dt
            if ambientEmit <= 0 {
                ambientEmit = .random(in: 0.5...1.1)
                leaves.append(Leaf(p: CGPoint(x: .random(in: 0...W), y: -20), v: CGPoint(x: .random(in: -20...20), y: .random(in: 45...85)),
                                   rot: .random(in: 0...(2 * .pi)), vr: .random(in: -2...2), life: 60,
                                   size: .random(in: 7...12), color: leafColors.randomElement()!, maple: .random(),
                                   drift: true, sway: .random(in: 0...(2 * .pi))))
            }
        }
        for i in leaves.indices {
            leaves[i].age += dt
            if leaves[i].drift {
                leaves[i].p.x += (leaves[i].v.x + CGFloat(sin(time * 1.4 + leaves[i].sway)) * 35) * fdt
                leaves[i].p.y += leaves[i].v.y * fdt
            } else {
                leaves[i].v.y += 560 * fdt
                leaves[i].v.x *= CGFloat(pow(0.4, dt))
                leaves[i].p = leaves[i].p + leaves[i].v * fdt
            }
            leaves[i].rot += leaves[i].vr * fdt
        }
        leaves.removeAll { $0.age > $0.life || $0.p.y > H + 30 }

        var arrived: [() -> Void] = []
        for i in flyers.indices {
            flyers[i].t += dt
            if flyers[i].t >= flyers[i].dur { arrived.append(flyers[i].onArrive) }
        }
        flyers.removeAll { $0.t >= $0.dur }
        arrived.forEach { $0() }

        for i in texts.indices { texts[i].t += dt }
        texts.removeAll { $0.t > 1.3 }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        guard active || !leaves.isEmpty || !flyers.isEmpty || !texts.isEmpty else { return }

        if !pileIsOnDesktop {
            pileIcon.draw(in: NSRect(x: pile.x - 32, y: pile.y - 32, width: 64, height: 64), from: .zero,
                          operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawLabel(pileName, at: CGPoint(x: pile.x, y: pile.y + 36))
        }
        for item in items where item.onGround {
            if isDesktop && !item.beingRaked { continue }
            let jig = item.beingRaked ? item.jiggle : 0
            drawCard(ctx, item.thumb, center: item.pos + CGPoint(x: jig, y: 0), size: cardSize(item.thumb, maxSide: 60), rot: jig * 0.02)
            if !isDesktop { drawLabel(item.name, at: CGPoint(x: item.pos.x, y: item.pos.y + 36)) }
        }

        if active { drawSquirrel(ctx) }

        for f in flyers where f.t > 0 {
            let u = CGFloat(min(1, f.t / f.dur))
            let e = u * u * (3 - 2 * u)
            var p = lerp(f.from, f.to(), e)
            p.y -= sin(.pi * u) * f.arc
            let size = CGSize(width: f.fromSize.width + (f.toSize.width - f.fromSize.width) * e,
                              height: f.fromSize.height + (f.toSize.height - f.fromSize.height) * e)
            drawCard(ctx, f.img, center: p, size: size, rot: f.rot * e + sin(.pi * u) * 0.5)
        }

        for l in leaves {
            let fade = l.drift ? 0.75 : CGFloat(min(1, (l.life - l.age) / 0.4))
            drawLeaf(ctx, at: l.p, size: l.size, rot: l.rot, color: l.color, maple: l.maple, alpha: fade)
        }

        for t in texts {
            let font = roundedFont(22, .heavy)
            let a = CGFloat(1 - max(0, t.t - 0.8) / 0.5)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            let s = NSAttributedString(string: t.text, attributes: [
                .font: font, .foregroundColor: NSColor(cgColor: leafColors[1])!.withAlphaComponent(a), .shadow: shadow,
            ])
            let size = s.size()
            s.draw(at: CGPoint(x: t.p.x - size.width / 2, y: t.p.y - CGFloat(t.t) * 40))
        }

        if active, let text = bubble { drawBubble(ctx, text) }
    }

    func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }

    func drawLabel(_ text: String, at p: CGPoint) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
            .shadow: shadow, .paragraphStyle: style,
        ])
        s.draw(in: CGRect(x: p.x - 50, y: p.y, width: 100, height: 30))
    }

    func drawBubble(_ ctx: CGContext, _ text: String) {
        let s = NSAttributedString(string: text, attributes: [
            .font: roundedFont(15, .semibold), .foregroundColor: NSColor(cgColor: rgb(0.30, 0.17, 0.08))!,
        ])
        let size = s.size()
        let w = size.width + 26, h = size.height + 14
        var x = pos.x - w / 2
        x = min(max(8, x), W - w - 8)
        let y = max(8, pos.y - hop - 128 * S - h)
        let r = CGRect(x: x, y: y, width: w, height: h)
        let tipX = min(max(r.minX + 16, pos.x + facing * 12), r.maxX - 16)
        let path = CGMutablePath()
        path.addRoundedRect(in: r, cornerWidth: 12, cornerHeight: 12)
        path.move(to: CGPoint(x: tipX - 8, y: r.maxY - 1))
        path.addLine(to: CGPoint(x: tipX, y: r.maxY + 10))
        path.addLine(to: CGPoint(x: tipX + 8, y: r.maxY - 1))
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: rgb(0, 0, 0, 0.25))
        ctx.addPath(path)
        ctx.setFillColor(rgb(1, 0.98, 0.94))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(rgb(0.55, 0.32, 0.15))
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        s.draw(at: CGPoint(x: r.minX + 13, y: r.minY + 7))
    }

    // MARK: Squirrel

    /// Springs for squash & stretch and for turning around.
    func stepBody(_ dt: Double) {
        let fdt = CGFloat(dt)
        displayFacing += (facing - displayFacing) * CGFloat(min(1, dt * 16))
        squashVel += (180 * (squashTarget - squash) - 11 * squashVel) * fdt
        squash += squashVel * fdt
    }

    var currentFrame: String {
        let stepA = sin(walkPhase) > 0
        switch pose {
        case .rake: return sin(rakePhase) > 0 ? "rake1" : "rake2"
        case .cheer: return "cheer"
        case .idle: return "idle"
        case .carry: return moving && !stepA ? "carry2" : "carry1"
        case .drag: return moving ? (stepA ? "walk1" : "walk2") : "idle"
        }
    }

    func drawSquirrel(_ ctx: CGContext) {
        let shadowW = (64 - hop * 0.8) * S
        ctx.setFillColor(rgb(0, 0, 0, 0.16))
        ctx.fillEllipse(in: CGRect(x: pos.x - shadowW / 2, y: pos.y - 5, width: shadowW, height: 10))
        guard let img = Sprites.frames[currentFrame] else { return }

        let walkSquash: CGFloat = moving ? -0.03 * CGFloat(cos(walkPhase * 2)) : 0
        let sq = max(0.8, 1 + squash + walkSquash)
        let bob: CGFloat = moving ? -CGFloat(abs(sin(walkPhase))) * 3 * S : 0
        let k = S * Sprites.unit
        ctx.saveGState()
        ctx.translateBy(x: pos.x, y: pos.y - hop + bob)
        ctx.scaleBy(x: displayFacing * k / sqrt(sq), y: -k * sq)
        ctx.interpolationQuality = .high
        let h = CGFloat(img.height)
        ctx.draw(img, in: CGRect(x: -Sprites.anchor.x, y: Sprites.anchor.y - h, width: CGFloat(img.width), height: h))
        ctx.restoreGState()

        let a = stackAnchor
        for (i, card) in carried.enumerated() {
            let c = CGPoint(x: pos.x + displayFacing * a.x * S, y: pos.y - hop + bob + (a.y - CGFloat(i) * 2.5) * S)
            drawCard(ctx, card.img, center: c, size: cardSize(card.img, maxSide: 23 * S), rot: card.rot * 0.5)
        }
    }
}

// MARK: - Menu bar

final class MenuController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let stage: Stage

    init(stage: Stage) {
        self.stage = stage
        super.init()
        if let img = Sprites.frames["idle"] {
            let h: CGFloat = 22
            item.button?.image = NSImage(cgImage: img, size: NSSize(width: h * CGFloat(img.width) / CGFloat(img.height), height: h))
        } else {
            item.button?.title = "Rake"
        }
        item.button?.toolTip = "Screenshot Rake"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, stage.active ? "Custodian Cashew is raking…" : "Send Custodian Cashew Now", #selector(rakeNow), enabled: !stage.active)
        menu.addItem(.separator())

        let batchMenu = NSMenu()
        for mode in BatchMode.allCases {
            let i = add(batchMenu, mode.title, #selector(setBatch(_:)))
            i.representedObject = mode.rawValue
            i.state = Settings.batch == mode ? .on : .off
        }
        menu.addItem(withTitle: "Batch Size", action: nil, keyEquivalent: "").submenu = batchMenu

        let repeatMenu = NSMenu()
        for choice in Settings.repeatChoices {
            let i = add(repeatMenu, choice.title, #selector(setRepeat(_:)))
            i.representedObject = choice.hours
            i.state = Settings.repeatHours == choice.hours ? .on : .off
        }
        menu.addItem(withTitle: "Repeat", action: nil, keyEquivalent: "").submenu = repeatMenu
        if let next = Settings.nextRake {
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .short
            f.timeStyle = .short
            add(menu, "Next rake: \(f.string(from: next))", nil, enabled: false)
        }
        menu.addItem(.separator())

        let count = pileContents().count
        add(menu, "Open Leaf Pile", #selector(openPile), enabled: fm.fileExists(atPath: pileURL.path))
        add(menu, count > 0 ? "Clear Leaf Pile (\(count))…" : "Clear Leaf Pile…", #selector(clearPile), enabled: count > 0 && !opts.dryRun)
        menu.addItem(.separator())
        add(menu, "Quit Screenshot Rake", #selector(quit))
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.isEnabled = enabled
        menu.addItem(i)
        return i
    }

    @objc func rakeNow() { stage.beginRun() }

    @objc func setBatch(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = BatchMode(rawValue: raw) { Settings.batch = mode }
    }

    @objc func setRepeat(_ sender: NSMenuItem) {
        guard let hours = sender.representedObject as? Double else { return }
        Settings.repeatHours = hours
        Settings.lastRake = Date()
    }

    @objc func openPile() { NSWorkspace.shared.open(pileURL) }

    @objc func clearPile() {
        let files = pileContents()
        guard !files.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear Leaf Pile?"
        alert.informativeText = "This moves \(files.count) item\(files.count == 1 ? "" : "s") in Leaf Pile to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for f in files {
            do { try fm.trashItem(at: f, resultingItemURL: nil) } catch { print("Couldn't trash \(f.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screenFrame = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

if let n = opts.mess {
    runMess(n, screen: screenFrame.size)
    exit(0)
}
if opts.unrake {
    runUnrake(screen: screenFrame.size)
    exit(0)
}

guard Sprites.frames.count == Sprites.names.count else {
    print("Missing squirrel frames: expected art/frames next to the rake script")
    exit(1)
}

let window = NSWindow(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
window.isOpaque = false
window.backgroundColor = .clear
window.hasShadow = false
window.ignoresMouseEvents = true
window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
let stage = Stage(frame: NSRect(origin: .zero, size: screenFrame.size))
window.contentView = stage
window.setFrame(screenFrame, display: false)
window.orderFrontRegardless()
let menuController = opts.once ? nil : MenuController(stage: stage)
stage.start()
app.run()
