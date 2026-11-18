// WinterIsComing — snow on your Mac desktop.
// Snow piles up on top of windows, the Dock and the bottom of the screen and flies off when you drag a
// window. Hover over the snow to roll snowballs, push them into each other, drag them with the mouse and
// stack three of them into a snowman. See README.md for the full list.
// Build: swiftc -O WinterIsComing.swift -o WinterIsComing
// Run:   ./WinterIsComing   (menu bar: pause / snow amount / performance profile / clear / quit)

import Cocoa
import SpriteKit
import ServiceManagement

// MARK: - Settings (feel free to tweak)

enum Cfg {
    static var targetFlakes = 260            // number of flakes falling at the same time
    static let colW: CGFloat = 3             // width of one column of the snow height map (px)
    static let windowPileMax: CGFloat = 16   // max snow height on top of a window
    static let groundPileMax: CGFloat = 34   // max snow height at the bottom of the screen
    static let gravity: CGFloat = 900        // gravity for snow sliding off
    static var pollInterval: CGFloat = 0.25   // shared window snapshot refresh interval (s)
    static let maxClumps = 900               // max number of falling snow clumps at once
    static let dockPileMax: CGFloat = 18     // max snow height on the Dock
    static let dockPad: CGFloat = 4          // extra width of the Dock pile on each side of the icon area
    static let dockTopOffset: CGFloat = -1   // lower it if the snow floats above the Dock, raise it if it sinks in
    static let fallSpeed: CGFloat = 1.5      // falling speed multiplier (1 = original, bigger = faster)
    static let flakesInFront = true          // some of the smallest flakes fall in front of windows, so they can reach the Dock
    static let inFrontFraction: CGFloat = 0.4 // share of the smallest layer that falls in front (0...1)
    static let ballStartRadius: CGFloat = 3  // a new snowball starts this small
    static let ballMaxRadius: CGFloat = 40   // and stops growing at this size
    static let maxBalls = 30                 // oldest resting snowballs are removed beyond this
    static let dockGain: CGFloat = 3.0       // snow landing on the Dock counts this many times more, so it builds up
}

// MARK: - Manual performance profiles

enum PerformanceProfile: String, CaseIterable {
    case batterySaver = "Battery Saver"
    case balanced = "Balanced"
    case highQuality = "High Quality"

    var flakes: Int {
        switch self {
        case .batterySaver: return 70
        case .balanced: return 180
        case .highQuality: return 500
        }
    }
    var framesPerSecond: Int {
        switch self {
        case .batterySaver: return 20
        case .balanced: return 30
        case .highQuality: return 45
        }
    }
    var windowPollInterval: CGFloat {
        switch self {
        case .batterySaver: return 0.50
        case .balanced: return 0.25
        case .highQuality: return 0.15
        }
    }
}

// MARK: - Persistent preferences

enum AppPreferences {
    static let defaults = UserDefaults.standard
    static let profileKey = "WinterIsComing.performanceProfile"
    static let amountKey = "WinterIsComing.snowAmount"
    static let reduceMotionKey = "WinterIsComing.reduceMotion"
}

// MARK: - Find the Dock (needs Accessibility permission)

@MainActor final class DockTracker {
    private var trusted = false
    private var warned = false
    var lastError = ""

    init() {
        // On first run macOS shows a prompt asking you to grant the permission
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    /// Frame of the Dock icon area (global macOS coordinates, origin top-left); nil if unavailable
    func frame() -> CGRect? {
        if !trusted {
            trusted = AXIsProcessTrusted()
            if !trusted {
                if !warned {
                    warned = true
                    print("❄︎ For snow on the Dock: System Settings → Privacy & Security → Accessibility, enable Terminal (or whichever app you run this from), then restart.")
                }
                lastError = "no Accessibility permission"
                return nil
            }
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            lastError = "Dock process not found"
            return nil
        }
        let axApp = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &childrenRef)
        guard err == .success, let children = childrenRef as? [AXUIElement] else {
            lastError = "could not read Dock children (AXError \(err.rawValue))"
            return nil
        }
        var roles: [String] = []
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? "?"
            roles.append(role)
            guard role == kAXListRole else { continue }
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let pv = posRef, let sv = sizeRef,
                  CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { continue }
            var pos = CGPoint.zero
            var sz = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sv as! AXValue, .cgSize, &sz)
            return CGRect(origin: pos, size: sz)
        }
        lastError = "no AXList among Dock children (roles: \(roles))"
        return nil
    }
}

// Three depth layers: far = small, faint, slow; near = big, bright, fast
struct Layer {
    let size: ClosedRange<CGFloat>
    let speed: ClosedRange<CGFloat>
    let alpha: ClosedRange<CGFloat>
    let sway: ClosedRange<CGFloat>
    let wind: CGFloat
    let z: CGFloat
}

let layers: [Layer] = [
    Layer(size: 1.8...3.0, speed: 22...38,  alpha: 0.30...0.50, sway: 5...10,  wind: 0.5, z: 1),
    Layer(size: 3.0...4.8, speed: 40...65,  alpha: 0.60...0.80, sway: 9...16,  wind: 0.8, z: 2),
    Layer(size: 4.8...7.5, speed: 70...105, alpha: 0.85...1.00, sway: 14...24, wind: 1.1, z: 7),
]

@inline(__always) func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b) }

// Soft round flake texture: solid center, fading edge
@MainActor func makeFlakeTexture() -> SKTexture {
    let s: CGFloat = 64
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1.0),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.6),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.45, 1]
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) else { return false }
        let c = CGPoint(x: s / 2, y: s / 2)
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
        return true
    }
    return SKTexture(image: img)
}

// Snowball body: lit from the top-left, bluish shade at the bottom-right (this part never rotates)
@MainActor func makeSnowballTexture() -> SKTexture {
    let s: CGFloat = 128
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addEllipse(in: CGRect(x: 1, y: 1, width: s - 2, height: s - 2))
        ctx.clip()
        let colors = [
            CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
            CGColor(red: 0.94, green: 0.96, blue: 1.00, alpha: 1),
            CGColor(red: 0.68, green: 0.75, blue: 0.88, alpha: 1),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.55, 1]
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) else { return false }
        ctx.drawRadialGradient(grad,
                               startCenter: CGPoint(x: s * 0.38, y: s * 0.64), startRadius: 0,
                               endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.55,
                               options: [.drawsAfterEndLocation])
        return true
    }
    return SKTexture(image: img)
}

// Little grey-blue specks on top of the body; this layer rotates so you can see the ball roll
@MainActor func makeSpeckTexture() -> SKTexture {
    let s: CGFloat = 128
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addEllipse(in: CGRect(x: 6, y: 6, width: s - 12, height: s - 12))
        ctx.clip()
        for _ in 0..<30 {
            let d = rnd(3, 8)
            ctx.setFillColor(CGColor(red: 0.66, green: 0.73, blue: 0.87, alpha: rnd(0.25, 0.55)))
            ctx.fillEllipse(in: CGRect(x: rnd(6, s - 14), y: rnd(6, s - 14), width: d, height: d))
        }
        return true
    }
    return SKTexture(image: img)
}

// MARK: - Snowman styles & randomized appearance

enum SnowmanKind: String, CaseIterable {
    case classicFrosty = "Classic Frosty"
    case cozyWinter = "Cozy Winter"
    case dapperGentleman = "Dapper Gentleman"
    case nordicExplorer = "Nordic Explorer"
    case playfulScamp = "Playful Scamp"
}

enum SnowmanExpression: String, CaseIterable {
    case cheerfulSmile = "Cheerful Smile"
    case wideGrin = "Wide Grin"
    case surprisedO = "Surprised O"
    case winking = "Winking"
    case jollyRosy = "Jolly Rosy"
}

enum SnowmanAccessory: String, CaseIterable {
    case none = "None"
    case pipe = "Pipe"
    case glasses = "Glasses"
    case earmuffs = "Earmuffs"
    case broomTwig = "Twig Broom"
}

struct SnowmanAppearance: Equatable {
    let kind: SnowmanKind
    let expression: SnowmanExpression
    let accessory: SnowmanAccessory
    let noseDirection: CGFloat
    let noseTilt: CGFloat
    let armAngleLeft: CGFloat
    let armAngleRight: CGFloat
    let primaryColor: NSColor
    let secondaryColor: NSColor

    static func random() -> SnowmanAppearance {
        let kind = SnowmanKind.allCases.randomElement() ?? .classicFrosty
        let expression = SnowmanExpression.allCases.randomElement() ?? .cheerfulSmile
        let accessory = SnowmanAccessory.allCases.randomElement() ?? .none
        let noseDir: CGFloat = Bool.random() ? 1.0 : -1.0
        let noseTilt = rnd(-0.10, 0.08)
        let armL = rnd(0.45, 0.90)
        let armR = rnd(0.45, 0.90)

        let palettes: [(NSColor, NSColor)] = [
            (NSColor(calibratedRed: 0.82, green: 0.16, blue: 0.18, alpha: 1),
             NSColor(calibratedRed: 0.95, green: 0.82, blue: 0.24, alpha: 1)),
            (NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.36, alpha: 1),
             NSColor(calibratedRed: 0.86, green: 0.24, blue: 0.22, alpha: 1)),
            (NSColor(calibratedRed: 0.20, green: 0.38, blue: 0.74, alpha: 1),
             NSColor(calibratedRed: 0.90, green: 0.94, blue: 1.00, alpha: 1)),
            (NSColor(calibratedRed: 0.56, green: 0.24, blue: 0.64, alpha: 1),
             NSColor(calibratedRed: 0.96, green: 0.76, blue: 0.28, alpha: 1)),
            (NSColor(calibratedRed: 0.86, green: 0.44, blue: 0.14, alpha: 1),
             NSColor(calibratedRed: 0.22, green: 0.30, blue: 0.44, alpha: 1))
        ]
        let palette = palettes.randomElement()!
        return SnowmanAppearance(
            kind: kind,
            expression: expression,
            accessory: accessory,
            noseDirection: noseDir,
            noseTilt: noseTilt,
            armAngleLeft: armL,
            armAngleRight: armR,
            primaryColor: palette.0,
            secondaryColor: palette.1
        )
    }
}

// MARK: - Visual wind simulation regimes

enum WindRegime: String, CaseIterable {
    case gentleBreeze = "Gentle Breeze"
    case moderateWind = "Moderate Wind"
    case strongGust = "Strong Gust"

    var amplitudeScale: CGFloat {
        switch self {
        case .gentleBreeze: return 0.45
        case .moderateWind: return 1.00
        case .strongGust:   return 2.15
        }
    }

    var steadyBiasRange: ClosedRange<CGFloat> {
        switch self {
        case .gentleBreeze: return -6...6
        case .moderateWind: return -18...18
        case .strongGust:   return -42...42
        }
    }

    var verticalLiftFactor: CGFloat {
        switch self {
        case .gentleBreeze: return 0.0
        case .moderateWind: return 0.08
        case .strongGust:   return 0.22
        }
    }

    var durationRange: ClosedRange<CGFloat> {
        switch self {
        case .gentleBreeze: return 10...18
        case .moderateWind: return 8...15
        case .strongGust:   return 4...8
        }
    }
}

// MARK: - Snowball

@MainActor final class Snowball {
    let node = SKNode()
    let body: SKSpriteNode
    let specks: SKSpriteNode
    var x: CGFloat = 0
    var y: CGFloat = 0
    var r: CGFloat = Cfg.ballStartRadius
    weak var pile: Pile?         // the surface it rests on (nil while falling, dragged or stacked)
    weak var below: Snowball?    // the ball it is stacked on (snowman), if any
    var falling = false
    var dragging = false
    var vel = CGVector.zero
    var decor: SKNode?           // snowman face / scarf / buttons drawn on this ball
    var snowmanAppearance: SnowmanAppearance?

    init(body bodyTex: SKTexture, specks speckTex: SKTexture) {
        body = SKSpriteNode(texture: bodyTex)
        specks = SKSpriteNode(texture: speckTex)
        specks.zPosition = 0.1
        specks.zRotation = rnd(0, 6.28)
        node.zPosition = 6.5
        node.addChild(body)
        node.addChild(specks)
    }

    func layout() {
        node.position = CGPoint(x: x, y: y)
        let d = CGSize(width: r * 2, height: r * 2)
        body.size = d
        specks.size = d
    }

    func drop(vel v: CGVector) {
        falling = true
        dragging = false
        pile = nil
        below = nil
        vel = v
    }
}

// MARK: - Flake

@MainActor final class Flake {
    let node: SKSpriteNode
    var vel = CGVector.zero
    var size: CGFloat = 4
    var swayAmp: CGFloat = 0
    var swayFreq: CGFloat = 1
    var phase: CGFloat = 0
    var windFactor: CGFloat = 1
    var inFront = false          // true = falls in front of windows (ignores them), lands on Dock / ground
    var isClump = false          // true = clump sliding off a surface (affected by gravity)
    var ignoreID = -1            // don't land right back on the surface it came from
    var ignoreUntil: CGFloat = 0

    init(texture: SKTexture) { node = SKSpriteNode(texture: texture) }
}

// MARK: - Snow pile (a height map drawn as a smooth white mound)

@MainActor final class Pile {
    var minX: CGFloat
    var topY: CGFloat
    let width: CGFloat
    let maxH: CGFloat
    var h: [CGFloat]
    var caps: [CGFloat]          // max height per column, tapering at both ends so it looks rounded
    var occ: [Bool]              // whether this column is hidden behind a window in front
    let body = SKShapeNode()
    let shade = SKShapeNode()
    var dirty = false

    init(minX: CGFloat, topY: CGFloat, width: CGFloat, maxH: CGFloat, parent: SKNode) {
        self.minX = minX
        self.topY = topY
        self.width = width
        self.maxH = maxH
        let n = max(1, Int((width / Cfg.colW).rounded(.up)))
        h = Array(repeating: 0, count: n)
        occ = Array(repeating: false, count: n)
        caps = (0..<n).map { i in
            let edgeDist = min(CGFloat(i) + 0.5, CGFloat(n - i) - 0.5) * Cfg.colW
            let t = min(1, edgeDist / (maxH * 2.2))
            return maxH * t.squareRoot()
        }
        body.fillColor = NSColor(calibratedWhite: 1, alpha: 0.97)
        body.strokeColor = .clear
        body.lineWidth = 0
        body.zPosition = 5
        // light blue-grey layer underneath, like a shadow
        shade.fillColor = NSColor(calibratedRed: 0.70, green: 0.78, blue: 0.92, alpha: 0.9)
        shade.strokeColor = .clear
        shade.lineWidth = 0
        shade.zPosition = 4
        shade.position = CGPoint(x: 0, y: -1.5)
        parent.addChild(shade)
        parent.addChild(body)
    }

    var count: Int { h.count }
    var total: CGFloat { h.reduce(0, +) }

    func col(at x: CGFloat) -> Int? {
        let c = Int((x - minX) / Cfg.colW)
        return (c >= 0 && c < count) ? c : nil
    }
    func colX(_ c: Int) -> CGFloat { minX + (CGFloat(c) + 0.5) * Cfg.colW }
    func surface(_ c: Int) -> CGFloat { topY + h[c] }

    func add(at c: Int, amount: CGFloat) {
        let spread: [(Int, CGFloat)] = [(0, 1), (-1, 0.75), (1, 0.75), (-2, 0.45), (2, 0.45), (-3, 0.2), (3, 0.2)]
        for (o, w) in spread {
            let i = c + o
            guard i >= 0, i < count, !occ[i] else { continue }
            h[i] = min(caps[i], h[i] + amount * w)
        }
        dirty = true
    }

    // let snow slump sideways where the slope is too steep
    func relax() -> Bool {
        guard count > 1 else { return false }
        var moved = false
        for i in 0..<(count - 1) where !occ[i] && !occ[i + 1] {
            let d = h[i] - h[i + 1]
            if abs(d) > 1.0 {
                let m = (abs(d) - 1.0) * 0.3 * (d > 0 ? 1 : -1)
                h[i] = max(0, min(caps[i], h[i] - m))
                h[i + 1] = max(0, min(caps[i + 1], h[i + 1] + m))
                if abs(m) > 0.02 { moved = true }
            }
        }
        return moved
    }

    func clear() {
        for i in 0..<count { h[i] = 0 }
        dirty = true
    }

    func redraw() {
        guard dirty else { return }
        dirty = relax()
        if total < 0.5 {
            body.path = nil
            shade.path = nil
            return
        }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: minX, y: topY))
        for c in 0..<count { p.addLine(to: CGPoint(x: colX(c), y: topY + h[c])) }
        p.addLine(to: CGPoint(x: minX + width, y: topY))
        p.closeSubpath()
        body.path = p
        shade.path = p
    }

    func remove() {
        body.removeFromParent()
        shade.removeFromParent()
    }
}

// MARK: - Scene

final class SnowScene: SKScene {
    var flakes: [Flake] = []
    var pool: [Flake] = []
    var piles: [Int: Pile] = [:]                 // window number -> snow on top of it
    var lastRect: [Int: CGRect] = [:]
    var order: [(id: Int, rect: CGRect)] = []    // windows from front to back
    var ground: Pile?
    var tex: SKTexture?
    var lastT: TimeInterval = 0
    var pollAcc: CGFloat = 0
    var t: CGFloat = 0
    let myPID = getpid()
    let world = SKNode()
    var dockTracker: DockTracker?
    let screenFrame: CGRect
    let isPrimaryDisplay: Bool
    var targetFlakes = Cfg.targetFlakes
    var maxClumps = Cfg.maxClumps
    static var cachedWindowInfo: [[String: Any]] = []
    static var windowInfoTimestamp: TimeInterval = 0
    var dockPile: Pile?
    var dockRect: CGRect?
    var dockAcc: CGFloat = 1
    var lastDockStatus = ""
    var balls: [Snowball] = []
    weak var activeBall: Snowball?
    var lastMouse = CGPoint.zero
    var ballTex: SKTexture?
    var dragBall: Snowball?
    var dragTarget = CGPoint.zero
    var dragOffset = CGPoint.zero
    var dragVel = CGVector.zero
    var speckTex: SKTexture?
    static let dockID = -2

    var windRegime: WindRegime = .moderateWind
    var windTimer: CGFloat = 10
    var currentWindScale: CGFloat = 1.0
    var targetWindScale: CGFloat = 1.0
    var currentWindBias: CGFloat = 0.0
    var targetWindBias: CGFloat = 0.0
    var currentWindLift: CGFloat = 0.0
    var targetWindLift: CGFloat = 0.0

    init(size: CGSize, screenFrame: CGRect, isPrimaryDisplay: Bool, targetFlakes: Int) {
        self.screenFrame = screenFrame
        self.isPrimaryDisplay = isPrimaryDisplay
        self.targetFlakes = max(8, targetFlakes)
        self.maxClumps = max(120, self.targetFlakes * 2)
        super.init(size: size)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func localMouseLocation() -> CGPoint {
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY)
    }

    func applyTargetFlakes(_ target: Int) {
        targetFlakes = max(8, target)
        maxClumps = max(120, targetFlakes * 2)
        var normalCount = flakes.reduce(0) { $0 + ($1.isClump ? 0 : 1) }
        var i = flakes.count - 1
        while normalCount > targetFlakes && i >= 0 {
            if !flakes[i].isClump {
                recycle(at: i)
                normalCount -= 1
            }
            i -= 1
        }
    }

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        tex = makeFlakeTexture()
        ballTex = makeSnowballTexture()
        speckTex = makeSpeckTexture()
        lastMouse = localMouseLocation()
        if isPrimaryDisplay { dockTracker = DockTracker() }
        addChild(world)
        resetGround()
        for _ in 0..<targetFlakes { spawnFlake(y: rnd(0, size.height)) }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard tex != nil else { return }
        resetGround()
    }

    func resetGround() {
        for b in balls where b.pile === ground { b.drop(vel: .zero) }
        ground?.remove()
        ground = Pile(minX: 0, topY: 0, width: size.width, maxH: Cfg.groundPileMax, parent: world)
    }

    func clearAll() {
        for p in piles.values { p.clear(); p.redraw() }
        dockPile?.clear()
        dockPile?.redraw()
        ground?.clear()
        ground?.redraw()
        for b in balls { b.node.removeFromParent() }
        balls.removeAll()
    }

    // MARK: Flake pool

    func obtain() -> Flake {
        let f = pool.popLast() ?? Flake(texture: tex!)
        world.addChild(f.node)
        flakes.append(f)
        return f
    }

    func recycle(at i: Int) {
        let f = flakes[i]
        f.node.removeFromParent()
        flakes.swapAt(i, flakes.count - 1)
        flakes.removeLast()
        pool.append(f)
    }

    func spawnFlake(y: CGFloat? = nil) {
        let f = obtain()
        let r = CGFloat.random(in: 0...1)
        let li = r < 0.40 ? 0 : (r < 0.68 ? 1 : 2)   // 40% far, 28% middle, 32% near
        let L = layers[li]
        f.inFront = Cfg.flakesInFront && li == 0 && CGFloat.random(in: 0...1) < Cfg.inFrontFraction
        f.isClump = false
        f.ignoreID = -1
        f.size = CGFloat.random(in: L.size)
        f.vel = CGVector(dx: 0, dy: -CGFloat.random(in: L.speed) * Cfg.fallSpeed)
        f.swayAmp = CGFloat.random(in: L.sway)
        f.swayFreq = rnd(0.6, 1.6)
        f.phase = rnd(0, 6.28)
        f.windFactor = L.wind
        f.node.alpha = CGFloat.random(in: L.alpha)
        f.node.size = CGSize(width: f.size * 2.2, height: f.size * 2.2)
        f.node.zPosition = L.z
        f.node.position = CGPoint(x: rnd(-40, size.width + 40), y: y ?? size.height + rnd(2, 30))
    }

    func spawnClump(at p: CGPoint, vel: CGVector, sourceID: Int) {
        let f = obtain()
        f.isClump = true
        f.inFront = false
        f.size = rnd(2.5, 5)
        f.vel = vel
        f.ignoreID = sourceID
        f.ignoreUntil = t + 0.35
        f.node.alpha = 0.95
        f.node.size = CGSize(width: f.size * 2.2, height: f.size * 2.2)
        f.node.zPosition = 6
        f.node.position = p
    }

    // Turn a pile into falling clumps; vel is the window's velocity, so faster drags fling snow farther
    func release(_ p: Pile, vel: CGVector, id: Int) {
        let fling = CGVector(dx: max(-900, min(900, vel.dx * 0.5)),
                             dy: max(-300, min(500, vel.dy * 0.4)))
        // Snowballs sitting on this surface get flung off too
        for b in balls where b.pile === p {
            b.drop(vel: CGVector(dx: fling.dx + rnd(-30, 30), dy: fling.dy + rnd(20, 80)))
        }
        let total = p.total
        guard total > 0.5 else { p.clear(); return }
        let budget = CGFloat(max(0, maxClumps - flakes.count + targetFlakes))
        let k = min(1, budget / max(1, total / 3.5))
        for c in 0..<p.count where p.h[c] > 0.6 {
            var amount = p.h[c] / 3.5 * k
            while amount > 0 {
                if amount < 1 && CGFloat.random(in: 0...1) > amount { break }
                spawnClump(at: CGPoint(x: p.colX(c) + rnd(-1.5, 1.5), y: p.topY + rnd(0, p.h[c])),
                           vel: CGVector(dx: fling.dx + rnd(-40, 40), dy: fling.dy + rnd(10, 80)),
                           sourceID: id)
                amount -= 1
            }
        }
        p.clear()
    }

    // MARK: Per-frame update

    override func update(_ currentTime: TimeInterval) {
        if lastT == 0 { lastT = currentTime }
        let dt = CGFloat(min(currentTime - lastT, 1.0 / 20.0))
        lastT = currentTime
        t += dt
        pollAcc += dt
        if pollAcc >= Cfg.pollInterval {
            pollWindows(dt: pollAcc)
            pollAcc = 0
        }
        stepFlakes(dt)
        updateMouseCapture()
        if let b = dragBall { stepDrag(b, dt) } else { updateRolling() }
        stepBalls(dt)
    }

    // MARK: Dragging & snowmen

    /// The overlay normally lets every click through. Only while the mouse is over a snowball (or dragging one)
    /// does it catch clicks, so you can grab the ball without clicking the window underneath.
    func updateMouseCapture() {
        guard let w = view?.window else { return }
        let capture = dragBall != nil || ballAt(localMouseLocation()) != nil
        if w.ignoresMouseEvents == capture { w.ignoresMouseEvents = !capture }
    }

    /// The visible, resting snowball under a point (top of a stack first)
    func ballAt(_ m: CGPoint) -> Snowball? {
        var best: Snowball?
        for b in balls where !b.falling && !b.node.isHidden {
            let dx = m.x - b.x, dy = m.y - b.y
            if dx * dx + dy * dy <= (b.r + 2) * (b.r + 2), best == nil || b.y > best!.y { best = b }
        }
        return best
    }

    func above(_ b: Snowball) -> Snowball? { balls.first { $0.below === b } }

    func base(of b: Snowball) -> Snowball {
        var x = b
        while let y = x.below { x = y }
        return x
    }

    /// Balls in a stack from the bottom up
    func stack(from base: Snowball) -> [Snowball] {
        var out = [base]
        while let a = above(out.last!), out.count < 10 { out.append(a) }
        return out
    }

    override func mouseDown(with event: NSEvent) {
        let m = event.location(in: self)
        guard let b = ballAt(m) else { return }
        // Anything stacked on top of the grabbed ball tumbles off
        var a = above(b)
        while let x = a {
            a = above(x)
            x.drop(vel: CGVector(dx: rnd(-50, 50), dy: rnd(40, 100)))
        }
        removeDecor(stackOf: b)
        b.pile = nil
        b.below = nil
        b.dragging = true
        b.node.zPosition = 8                 // in front while dragging
        dragBall = b
        activeBall = nil
        dragOffset = CGPoint(x: b.x - m.x, y: b.y - m.y)
        dragTarget = m
        dragVel = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        dragTarget = event.location(in: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let b = dragBall else { return }
        dragBall = nil
        b.dragging = false
        if let target = stackTarget(for: b) {
            b.below = target
            b.vel = .zero
            let st = stack(from: base(of: b))
            for (i, x) in st.enumerated() { x.node.zPosition = 6.5 + CGFloat(i) * 0.3 }
            if st.count == 3 { makeSnowman(st) }
        } else {
            b.node.zPosition = 6.5
            // Let go: it falls (with a bit of the throw) and lands on whatever is below
            b.drop(vel: CGVector(dx: max(-600, min(600, dragVel.dx * 0.5)),
                                 dy: max(-400, min(400, dragVel.dy * 0.5))))
        }
    }

    func stepDrag(_ b: Snowball, _ dt: CGFloat) {
        let target = CGPoint(x: dragTarget.x + dragOffset.x, y: dragTarget.y + dragOffset.y)
        if dt > 0 {
            let v = CGVector(dx: (target.x - b.x) / dt, dy: (target.y - b.y) / dt)
            dragVel = CGVector(dx: dragVel.dx * 0.7 + v.dx * 0.3, dy: dragVel.dy * 0.7 + v.dy * 0.3)
        }
        b.specks.zRotation -= (target.x - b.x) / b.r
        b.x = target.x
        b.y = target.y
        lastMouse = localMouseLocation()
    }

    /// A ball dropped just above another ball (that isn't already a full snowman) gets stacked on it
    func stackTarget(for b: Snowball) -> Snowball? {
        var best: Snowball?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for c in balls where c !== b && !c.falling && !c.dragging && !c.node.isHidden {
            guard above(c) == nil, stack(from: base(of: c)).count < 3 else { continue }
            let dx = abs(b.x - c.x), dy = b.y - c.y
            guard dx < c.r * 0.9 + b.r * 0.3, dy > 0, dy < c.r + b.r + 30 else { continue }
            if dx < bestDist { best = c; bestDist = dx }
        }
        return best
    }

    func removeDecor(stackOf b: Snowball) {
        for x in stack(from: base(of: b)) {
            x.decor?.removeFromParent()
            x.decor = nil
            x.snowmanAppearance = nil
        }
    }

    /// Three stacked balls become a snowman with a randomized style, expression, and accessory
    func makeSnowman(_ st: [Snowball]) {
        guard st.count >= 3 else { return }
        let baseBall = st[0], body = st[1], head = st[2]
        removeDecor(stackOf: head)

        let appearance = SnowmanAppearance.random()
        for ball in st { ball.snowmanAppearance = appearance }

        let baseMarker = SKNode()
        baseBall.node.addChild(baseMarker)
        baseBall.decor = baseMarker

        let h = buildSnowmanHeadDecor(radius: head.r, appearance: appearance)
        head.node.addChild(h)
        head.decor = h

        let bd = buildSnowmanBodyDecor(radius: body.r, appearance: appearance)
        body.node.addChild(bd)
        body.decor = bd
    }

    func buildSnowmanHeadDecor(radius R: CGFloat, appearance: SnowmanAppearance) -> SKNode {
        let h = SKNode()
        h.zPosition = 0.5
        let coal = NSColor(calibratedWhite: 0.08, alpha: 1)

        // Rosy cheeks
        if appearance.expression == .jollyRosy || appearance.kind == .cozyWinter {
            for sx in [-1.0, 1.0] as [CGFloat] {
                let cheek = SKShapeNode(ellipseOf: CGSize(width: R * 0.28, height: R * 0.18))
                cheek.fillColor = NSColor(calibratedRed: 0.96, green: 0.45, blue: 0.52, alpha: 0.45)
                cheek.strokeColor = .clear
                cheek.position = CGPoint(x: sx * R * 0.44, y: R * 0.02)
                h.addChild(cheek)
            }
        }

        // Eyes & optional bushy brows
        for sx in [-1.0, 1.0] as [CGFloat] {
            if appearance.expression == .winking && sx > 0 {
                let winkPath = CGMutablePath()
                winkPath.move(to: CGPoint(x: R * 0.18, y: R * 0.20))
                winkPath.addQuadCurve(to: CGPoint(x: R * 0.42, y: R * 0.20),
                                      control: CGPoint(x: R * 0.30, y: R * 0.32))
                let wink = SKShapeNode(path: winkPath)
                wink.strokeColor = coal
                wink.lineWidth = max(1.1, R * 0.07)
                wink.lineCap = .round
                h.addChild(wink)
            } else {
                let eye = SKShapeNode(circleOfRadius: max(1, R * 0.09))
                eye.fillColor = coal
                eye.strokeColor = .clear
                eye.position = CGPoint(x: sx * R * 0.3, y: R * 0.22)
                h.addChild(eye)
            }

            if appearance.kind == .nordicExplorer {
                let brow = SKShapeNode(rectOf: CGSize(width: R * 0.24, height: max(1, R * 0.06)),
                                       cornerRadius: R * 0.02)
                brow.fillColor = NSColor(calibratedWhite: 0.22, alpha: 1)
                brow.strokeColor = .clear
                brow.position = CGPoint(x: sx * R * 0.3, y: R * 0.36)
                brow.zRotation = sx * -0.12
                h.addChild(brow)
            }
        }

        // Carrot nose
        let dir = appearance.noseDirection
        let nose = CGMutablePath()
        nose.move(to: CGPoint(x: dir * R * 0.02, y: R * 0.06))
        nose.addLine(to: CGPoint(x: dir * R * 0.76, y: R * (-0.04 + appearance.noseTilt)))
        nose.addLine(to: CGPoint(x: dir * R * 0.02, y: -R * 0.12))
        nose.closeSubpath()
        let carrot = SKShapeNode(path: nose)
        carrot.fillColor = NSColor(calibratedRed: 0.96, green: 0.52, blue: 0.13, alpha: 1)
        carrot.strokeColor = .clear
        h.addChild(carrot)

        // Mouth / Expression
        switch appearance.expression {
        case .cheerfulSmile, .winking, .jollyRosy:
            for k in 0..<5 {
                let a = CGFloat.pi * (1.2 + 0.15 * CGFloat(k))
                let dot = SKShapeNode(circleOfRadius: max(0.7, R * 0.05))
                dot.fillColor = coal
                dot.strokeColor = .clear
                dot.position = CGPoint(x: cos(a) * R * 0.42, y: sin(a) * R * 0.42 - R * 0.05)
                h.addChild(dot)
            }
        case .wideGrin:
            let grinPath = CGMutablePath()
            grinPath.move(to: CGPoint(x: -R * 0.38, y: -R * 0.22))
            grinPath.addQuadCurve(to: CGPoint(x: R * 0.38, y: -R * 0.22),
                                  control: CGPoint(x: 0, y: -R * 0.54))
            let grin = SKShapeNode(path: grinPath)
            grin.strokeColor = coal
            grin.lineWidth = max(1.2, R * 0.08)
            grin.lineCap = .round
            h.addChild(grin)
        case .surprisedO:
            let mouth = SKShapeNode(circleOfRadius: max(1.2, R * 0.11))
            mouth.fillColor = coal
            mouth.strokeColor = .clear
            mouth.position = CGPoint(x: 0, y: -R * 0.34)
            h.addChild(mouth)
        }

        // Neckwear (bow tie for dapperGentleman, scarf for others)
        if appearance.kind == .dapperGentleman {
            let bow = CGMutablePath()
            bow.move(to: CGPoint(x: 0, y: -R * 0.88))
            bow.addLine(to: CGPoint(x: -R * 0.45, y: -R * 0.68))
            bow.addLine(to: CGPoint(x: -R * 0.45, y: -R * 1.08))
            bow.closeSubpath()
            bow.move(to: CGPoint(x: 0, y: -R * 0.88))
            bow.addLine(to: CGPoint(x: R * 0.45, y: -R * 0.68))
            bow.addLine(to: CGPoint(x: R * 0.45, y: -R * 1.08))
            bow.closeSubpath()
            let bowNode = SKShapeNode(path: bow)
            bowNode.fillColor = appearance.primaryColor
            bowNode.strokeColor = .clear
            h.addChild(bowNode)
            let knot = SKShapeNode(circleOfRadius: max(1.0, R * 0.11))
            knot.fillColor = appearance.secondaryColor
            knot.strokeColor = .clear
            knot.position = CGPoint(x: 0, y: -R * 0.88)
            h.addChild(knot)
        } else {
            let scarf = SKShapeNode(rect: CGRect(x: -R * 0.85, y: -R * 0.98, width: R * 1.7, height: R * 0.3),
                                    cornerRadius: R * 0.12)
            scarf.fillColor = appearance.primaryColor
            scarf.strokeColor = .clear
            h.addChild(scarf)

            let tailX = dir > 0 ? R * 0.3 : -R * 0.58
            let tail = SKShapeNode(rect: CGRect(x: tailX, y: -R * 1.55, width: R * 0.28, height: R * 0.7),
                                   cornerRadius: R * 0.08)
            tail.fillColor = appearance.primaryColor
            tail.strokeColor = .clear
            tail.zRotation = dir > 0 ? -0.15 : 0.15
            h.addChild(tail)

            if appearance.kind == .cozyWinter || appearance.kind == .nordicExplorer {
                let stripe = SKShapeNode(rect: CGRect(x: -R * 0.80, y: -R * 0.88, width: R * 1.6, height: R * 0.09),
                                         cornerRadius: R * 0.04)
                stripe.fillColor = appearance.secondaryColor
                stripe.strokeColor = .clear
                h.addChild(stripe)
            }
        }

        // Headwear for each of the 5 predefined styles
        switch appearance.kind {
        case .classicFrosty:
            let brim = SKShapeNode(rectOf: CGSize(width: R * 1.5, height: R * 0.16), cornerRadius: R * 0.06)
            brim.fillColor = coal
            brim.strokeColor = .clear
            brim.position = CGPoint(x: 0, y: R * 0.86)
            h.addChild(brim)
            let crown = SKShapeNode(rectOf: CGSize(width: R * 0.96, height: R * 0.75), cornerRadius: R * 0.06)
            crown.fillColor = coal
            crown.strokeColor = .clear
            crown.position = CGPoint(x: 0, y: R * 1.28)
            h.addChild(crown)
            let band = SKShapeNode(rectOf: CGSize(width: R * 0.96, height: R * 0.14))
            band.fillColor = appearance.primaryColor
            band.strokeColor = .clear
            band.position = CGPoint(x: 0, y: R * 1.00)
            h.addChild(band)

        case .cozyWinter:
            let dome = SKShapeNode(ellipseOf: CGSize(width: R * 1.38, height: R * 0.95))
            dome.fillColor = appearance.primaryColor
            dome.strokeColor = .clear
            dome.position = CGPoint(x: 0, y: R * 0.92)
            h.addChild(dome)
            let cuff = SKShapeNode(rectOf: CGSize(width: R * 1.44, height: R * 0.26), cornerRadius: R * 0.10)
            cuff.fillColor = appearance.secondaryColor
            cuff.strokeColor = .clear
            cuff.position = CGPoint(x: 0, y: R * 0.78)
            h.addChild(cuff)
            let pom = SKShapeNode(circleOfRadius: max(1.5, R * 0.22))
            pom.fillColor = NSColor(calibratedWhite: 0.98, alpha: 1)
            pom.strokeColor = .clear
            pom.position = CGPoint(x: 0, y: R * 1.45)
            h.addChild(pom)

        case .dapperGentleman:
            let hat = SKNode()
            hat.zRotation = -0.08
            let brim = SKShapeNode(rectOf: CGSize(width: R * 1.65, height: R * 0.15), cornerRadius: R * 0.06)
            brim.fillColor = NSColor(calibratedWhite: 0.12, alpha: 1)
            brim.strokeColor = .clear
            brim.position = CGPoint(x: 0, y: R * 0.85)
            hat.addChild(brim)
            let crown = SKShapeNode(rectOf: CGSize(width: R * 1.02, height: R * 0.95), cornerRadius: R * 0.05)
            crown.fillColor = NSColor(calibratedWhite: 0.12, alpha: 1)
            crown.strokeColor = .clear
            crown.position = CGPoint(x: 0, y: R * 1.36)
            hat.addChild(crown)
            let ribbon = SKShapeNode(rectOf: CGSize(width: R * 1.02, height: R * 0.16))
            ribbon.fillColor = appearance.secondaryColor
            ribbon.strokeColor = .clear
            ribbon.position = CGPoint(x: 0, y: R * 1.00)
            hat.addChild(ribbon)
            h.addChild(hat)

        case .nordicExplorer:
            let furBrown = NSColor(calibratedRed: 0.45, green: 0.31, blue: 0.18, alpha: 1)
            let crown = SKShapeNode(ellipseOf: CGSize(width: R * 1.45, height: R * 0.85))
            crown.fillColor = furBrown
            crown.strokeColor = .clear
            crown.position = CGPoint(x: 0, y: R * 0.92)
            h.addChild(crown)
            let visor = SKShapeNode(rectOf: CGSize(width: R * 1.15, height: R * 0.26), cornerRadius: R * 0.08)
            visor.fillColor = appearance.primaryColor
            visor.strokeColor = .clear
            visor.position = CGPoint(x: 0, y: R * 0.82)
            h.addChild(visor)
            for sx in [-1.0, 1.0] as [CGFloat] {
                let flap = SKShapeNode(rectOf: CGSize(width: R * 0.26, height: R * 0.65), cornerRadius: R * 0.10)
                flap.fillColor = furBrown
                flap.strokeColor = .clear
                flap.position = CGPoint(x: sx * R * 0.72, y: R * 0.48)
                flap.zRotation = sx * 0.12
                h.addChild(flap)
            }

        case .playfulScamp:
            let cap = SKNode()
            cap.zRotation = 0.18
            let dome = SKShapeNode(ellipseOf: CGSize(width: R * 1.30, height: R * 0.75))
            dome.fillColor = appearance.primaryColor
            dome.strokeColor = .clear
            dome.position = CGPoint(x: 0, y: R * 0.90)
            cap.addChild(dome)
            let bill = SKShapeNode(rectOf: CGSize(width: R * 0.85, height: R * 0.14), cornerRadius: R * 0.06)
            bill.fillColor = appearance.secondaryColor
            bill.strokeColor = .clear
            bill.position = CGPoint(x: dir * R * 0.45, y: R * 0.76)
            cap.addChild(bill)
            h.addChild(cap)
        }

        // Head accessories
        switch appearance.accessory {
        case .glasses:
            let frameColor = NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.26, alpha: 1)
            for sx in [-1.0, 1.0] as [CGFloat] {
                let rim = SKShapeNode(circleOfRadius: max(1.6, R * 0.21))
                rim.fillColor = .clear
                rim.strokeColor = frameColor
                rim.lineWidth = max(1.0, R * 0.055)
                rim.position = CGPoint(x: sx * R * 0.30, y: R * 0.22)
                h.addChild(rim)
            }
            let bridge = SKShapeNode(rectOf: CGSize(width: R * 0.20, height: max(1.0, R * 0.05)))
            bridge.fillColor = frameColor
            bridge.strokeColor = .clear
            bridge.position = CGPoint(x: 0, y: R * 0.24)
            h.addChild(bridge)

        case .pipe:
            let pipeBrown = NSColor(calibratedRed: 0.40, green: 0.24, blue: 0.12, alpha: 1)
            let pDir = -dir
            let stemPath = CGMutablePath()
            stemPath.move(to: CGPoint(x: pDir * R * 0.22, y: -R * 0.32))
            stemPath.addLine(to: CGPoint(x: pDir * R * 0.78, y: -R * 0.44))
            let stem = SKShapeNode(path: stemPath)
            stem.strokeColor = pipeBrown
            stem.lineWidth = max(1.2, R * 0.08)
            stem.lineCap = .round
            h.addChild(stem)
            let bowl = SKShapeNode(rectOf: CGSize(width: R * 0.22, height: R * 0.26), cornerRadius: R * 0.04)
            bowl.fillColor = pipeBrown
            bowl.strokeColor = .clear
            bowl.position = CGPoint(x: pDir * R * 0.82, y: -R * 0.36)
            h.addChild(bowl)

        case .earmuffs:
            let bandPath = CGMutablePath()
            bandPath.addArc(center: CGPoint(x: 0, y: R * 0.15), radius: R * 0.92,
                            startAngle: 0.15, endAngle: .pi - 0.15, clockwise: false)
            let band = SKShapeNode(path: bandPath)
            band.strokeColor = appearance.secondaryColor
            band.lineWidth = max(1.2, R * 0.08)
            h.addChild(band)
            for sx in [-1.0, 1.0] as [CGFloat] {
                let muff = SKShapeNode(ellipseOf: CGSize(width: R * 0.28, height: R * 0.42))
                muff.fillColor = appearance.primaryColor
                muff.strokeColor = .clear
                muff.position = CGPoint(x: sx * R * 0.92, y: R * 0.15)
                h.addChild(muff)
            }

        case .none, .broomTwig:
            break
        }

        return h
    }

    func buildSnowmanBodyDecor(radius B: CGFloat, appearance: SnowmanAppearance) -> SKNode {
        let bd = SKNode()
        bd.zPosition = 0.5
        let buttonColor: NSColor
        switch appearance.kind {
        case .cozyWinter, .nordicExplorer:
            buttonColor = NSColor(calibratedRed: 0.42, green: 0.26, blue: 0.14, alpha: 1)
        case .dapperGentleman:
            buttonColor = appearance.secondaryColor
        case .classicFrosty, .playfulScamp:
            buttonColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        }

        for k in 0..<3 {
            let btn = SKShapeNode(circleOfRadius: max(0.8, B * 0.075))
            btn.fillColor = buttonColor
            btn.strokeColor = .clear
            btn.position = CGPoint(x: 0, y: B * (0.35 - 0.33 * CGFloat(k)))
            bd.addChild(btn)
        }

        let brown = NSColor(calibratedRed: 0.42, green: 0.28, blue: 0.16, alpha: 1)
        for sx in [-1.0, 1.0] as [CGFloat] {
            let lift = sx < 0 ? appearance.armAngleLeft : appearance.armAngleRight
            let arm = CGMutablePath()
            arm.move(to: CGPoint(x: sx * B * 0.85, y: B * 0.15))
            arm.addLine(to: CGPoint(x: sx * B * 1.75, y: B * lift))
            arm.move(to: CGPoint(x: sx * B * 1.40, y: B * (0.15 + (lift - 0.15) * 0.62)))
            arm.addLine(to: CGPoint(x: sx * B * 1.56, y: B * (lift + 0.22)))
            let stick = SKShapeNode(path: arm)
            stick.strokeColor = brown
            stick.lineWidth = max(1.2, B * 0.09)
            stick.lineCap = .round
            bd.addChild(stick)
        }

        if appearance.accessory == .broomTwig {
            let handX = B * 1.65
            let handY = B * appearance.armAngleRight
            let shaftPath = CGMutablePath()
            shaftPath.move(to: CGPoint(x: handX - B * 0.15, y: -B * 0.85))
            shaftPath.addLine(to: CGPoint(x: handX + B * 0.20, y: handY + B * 0.55))
            let shaft = SKShapeNode(path: shaftPath)
            shaft.strokeColor = brown
            shaft.lineWidth = max(1.2, B * 0.08)
            shaft.lineCap = .round
            bd.addChild(shaft)

            let bristlePath = CGMutablePath()
            let topX = handX + B * 0.20
            let topY = handY + B * 0.55
            for k in -2...2 {
                bristlePath.move(to: CGPoint(x: topX, y: topY))
                bristlePath.addLine(to: CGPoint(x: topX + CGFloat(k) * B * 0.11 + B * 0.08,
                                                y: topY + B * 0.42))
            }
            let bristles = SKShapeNode(path: bristlePath)
            bristles.strokeColor = NSColor(calibratedRed: 0.58, green: 0.42, blue: 0.20, alpha: 1)
            bristles.lineWidth = max(1.0, B * 0.05)
            bristles.lineCap = .round
            bd.addChild(bristles)
        }

        return bd
    }

    // MARK: Snowballs

    /// Is the mouse inside the snow band of this pile (a bit below the edge up to a bit above the snow)?
    func mouseOver(_ p: Pile, _ m: CGPoint) -> Bool {
        guard let c = p.col(at: m.x), !p.occ[c] else { return false }
        return m.y >= p.topY - 6 && m.y <= p.topY + p.h[c] + 14
    }

    /// Which snow surface is the mouse hovering over? Dock first, then windows front to back, then the ground.
    func surfaceUnderMouse(_ m: CGPoint) -> Pile? {
        // Hovering over a snowball counts as hovering over the snow it sits on. Without this, a big ball
        // stops rolling as soon as the cursor rises above the thin snow band, which makes pushing jerky.
        for b in balls where !b.falling && !b.dragging && !b.node.isHidden && b.below == nil {
            guard let p = b.pile, abs(m.x - b.x) < b.r + 8 else { continue }
            if m.y >= p.topY - 6 && m.y <= p.topY + 2 * b.r + 8 { return p }
        }
        if let d = dockPile, mouseOver(d, m) { return d }
        if let dr = dockRect, dr.contains(m) { return nil }
        for item in order {
            if let p = piles[item.id], mouseOver(p, m) { return p }
            if item.rect.contains(m) { return nil }      // over a window's content
        }
        if let g = ground, mouseOver(g, m) { return g }
        return nil
    }

    func updateRolling() {
        let m = localMouseLocation()
        let dx = m.x - lastMouse.x
        lastMouse = m
        guard let p = surfaceUnderMouse(m) else { activeBall = nil; return }
        guard abs(dx) > 0.2 else { return }

        // Keep rolling the current ball, pick up a resting one under the mouse, or start a new one
        if let b = activeBall, b.pile === p, above(b) == nil, abs(b.x - (m.x - dx)) < b.r + 25 {   // ball was at the previous mouse x
            // keep it
        } else if let b = balls.first(where: { !$0.falling && $0.pile === p && abs($0.x - m.x) < $0.r + 10 }) {
            guard above(b) == nil else { activeBall = nil; return }   // don't roll the bottom of a snowman
            activeBall = b
        } else if let c = p.col(at: m.x), p.h[c] > 1.5 {
            let b = Snowball(body: ballTex!, specks: speckTex!)
            b.x = m.x
            b.pile = p
            b.y = p.topY + b.r - 1.5
            b.layout()
            world.addChild(b.node)
            balls.append(b)
            activeBall = b
            trimBalls()
        } else {
            activeBall = nil
            return
        }
        guard let b = activeBall else { return }

        // Move the ball to the mouse, staying on the surface
        let lo = p.minX + b.r, hi = p.minX + p.width - b.r
        let newX = lo < hi ? min(max(m.x, lo), hi) : b.x
        let moved = newX - b.x
        guard abs(moved) > 0.01 else { return }
        let oldX = b.x
        roll(b, on: p, to: newX)
        push(from: b, oldX: oldX, dir: moved > 0 ? 1 : -1, on: p)
    }

    /// Roll a ball to newX: it picks up snow from the columns it passes over and grows
    func roll(_ b: Snowball, on p: Pile, to newX: CGFloat) {
        let moved = newX - b.x
        guard abs(moved) > 0.01 else { return }
        if b.r < Cfg.ballMaxRadius {
            var collected: CGFloat = 0
            let from = min(b.x, newX) - b.r * 0.8
            let to = max(b.x, newX) + b.r * 0.8
            let frac = min(0.6, 0.6 * abs(moved) / (1.6 * b.r))
            if let c0 = p.col(at: max(from, p.minX)), let c1 = p.col(at: min(to, p.minX + p.width - 0.1)), c0 <= c1 {
                for c in c0...c1 where !p.occ[c] {
                    let take = p.h[c] * frac
                    p.h[c] -= take
                    collected += take
                }
                p.dirty = true
            }
            // Ball area grows by the snow area it picked up
            let area = CGFloat.pi * b.r * b.r + collected * Cfg.colW * 0.8
            b.r = min(Cfg.ballMaxRadius, (area / .pi).squareRoot())
        }
        b.x = newX
        b.specks.zRotation -= moved / b.r     // roll
    }

    /// The moving ball pushes any ball it touches in front of it; that ball can push the next one, and so on.
    /// A ball pushed past the end of a surface falls off.
    func push(from b: Snowball, oldX: CGFloat, dir: CGFloat, on p: Pile) {
        // Look for balls ahead of where the pusher *was*: after a fast mouse move it may already have
        // jumped past a ball, and that ball must still be pushed instead of being passed through.
        let ahead = balls
            .filter { $0 !== b && !$0.falling && !$0.dragging && $0.pile === p && ($0.x - oldX) * dir > 0 }
            .sorted { abs($0.x - oldX) < abs($1.x - oldX) }
        var pusher = b
        for o in ahead {
            let need = pusher.x + dir * (pusher.r + o.r)     // where o must be to just touch the pusher
            guard (need - o.x) * dir > 0 else { break }       // not touching: the chain stops here
            let lo = p.minX + o.r, hi = p.minX + p.width - o.r
            if need < lo || need > hi {
                o.x = need
                o.drop(vel: CGVector(dx: dir * 140, dy: 40))  // pushed off the edge
            } else {
                roll(o, on: p, to: need)
            }
            pusher = o
        }
    }

    func trimBalls() {
        while balls.count > Cfg.maxBalls,
              let i = balls.firstIndex(where: { !$0.falling && !$0.dragging && $0.decor == nil && $0.snowmanAppearance == nil && $0 !== activeBall }) {
            balls[i].node.removeFromParent()
            balls.remove(at: i)
        }
    }

    func stepBalls(_ dt: CGFloat) {
        var i = balls.count - 1
        while i >= 0 {
            let b = balls[i]
            var gone = false
            if b.falling {
                if b.decor != nil || b.snowmanAppearance != nil {
                    b.decor?.removeFromParent()
                    b.decor = nil
                    b.snowmanAppearance = nil
                }
                b.node.zPosition = 6.5
                let prevBottom = b.y - b.r
                b.vel.dy -= Cfg.gravity * dt
                b.x += b.vel.dx * dt
                b.y += b.vel.dy * dt
                b.specks.zRotation -= b.vel.dx * dt / b.r
                if b.vel.dy < 0, let p = landingSurface(x: b.x, from: prevBottom, to: b.y - b.r) {
                    splat(b, on: p)                  // falling snowballs burst into a heap of snow
                    gone = true
                } else if b.y < -b.r * 2 || b.x < -100 || b.x > size.width + 100 {
                    gone = true
                }
            } else if b.dragging {
                // position is set by stepDrag
            } else if let under = b.below {
                if under.falling || under.dragging {
                    b.drop(vel: CGVector(dx: under.vel.dx + rnd(-40, 40), dy: max(under.vel.dy, 0) + rnd(30, 80)))
                } else {
                    b.x = under.x
                    b.y = under.y + under.r + b.r * 0.82   // sits slightly sunk into the ball below
                    b.node.isHidden = under.node.isHidden
                }
            } else if let p = b.pile {
                if let c = p.col(at: b.x) {
                    b.node.isHidden = p.occ[c]     // hidden behind a window in front
                } else {
                    b.node.isHidden = true
                }
                b.y = p.topY + b.r - 1.5           // sits slightly sunk into the snow
            } else {
                b.drop(vel: .zero)                 // lost its support (e.g. the ball below was removed)
            }
            if gone {
                b.node.removeFromParent()
                balls.remove(at: i)
            } else {
                b.layout()
            }
            i -= 1
        }
    }

    /// First surface a falling ball hits between two heights: the Dock, then window tops (front to back),
    /// then the bottom of the screen. Returns nil if it hits nothing this frame.
    func landingSurface(x: CGFloat, from top: CGFloat, to bottom: CGFloat) -> Pile? {
        func crosses(_ p: Pile) -> Bool {
            guard let c = p.col(at: x), !p.occ[c] else { return false }
            let s = p.surface(c)
            return top >= s && bottom < s
        }
        if let d = dockPile, crosses(d) { return d }
        for item in order {
            if let p = piles[item.id], crosses(p) { return p }
        }
        // The ground catches everything that reaches the bottom, even where a window covers it
        if let g = ground, let c = g.col(at: x), bottom < g.surface(c) { return g }
        return nil
    }

    /// A falling ball bursts where it lands: its snow becomes a mound on that surface, plus a puff of powder
    func splat(_ b: Snowball, on p: Pile) {
        if let c0 = p.col(at: b.x) {
            let snow = CGFloat.pi * b.r * b.r * 0.7 / Cfg.colW     // ball area -> total column height
            let half = max(2, Int(b.r * 1.4 / Cfg.colW))
            var sum: CGFloat = 0
            for o in -half...half { sum += 1 - abs(CGFloat(o)) / CGFloat(half + 1) }
            for o in -half...half {
                let i = c0 + o
                guard i >= 0, i < p.count, !p.occ[i] else { continue }
                let w = (1 - abs(CGFloat(o)) / CGFloat(half + 1)) / sum
                p.h[i] = min(p.caps[i], p.h[i] + snow * w)
            }
            p.dirty = true
        }
        for _ in 0..<min(14, Int(b.r * 0.6) + 2) {
            spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y - b.r * 0.5 + rnd(0, b.r * 0.5)),
                       vel: CGVector(dx: b.vel.dx * 0.2 + rnd(-90, 90), dy: rnd(60, 180)),
                       sourceID: -3)
        }
    }

    /// A falling ball comes to rest on a surface and can be rolled again from there (currently unused)
    func land(_ b: Snowball, on p: Pile) {
        b.falling = false
        b.vel = .zero
        b.pile = p
        let lo = p.minX + b.r, hi = p.minX + p.width - b.r
        if lo < hi { b.x = min(max(b.x, lo), hi) }
        b.y = p.topY + b.r - 1.5
    }

    /// A falling snowball bursts into loose snow when it hits the ground
    func poof(_ b: Snowball) {
        let n = min(40, Int(b.r * 1.6))
        for _ in 0..<n {
            spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y + rnd(-b.r * 0.5, b.r * 0.5)),
                       vel: CGVector(dx: b.vel.dx * 0.3 + rnd(-90, 90), dy: rnd(40, 170)),
                       sourceID: -3)
        }
    }

    // Read all window frames (macOS origin is top-left, SpriteKit is bottom-left, so flip y)
    func pollWindows(dt: CGFloat) {
        var newOrder: [(id: Int, rect: CGRect)] = []
        // All display scenes share one cached WindowServer snapshot. This avoids one expensive
        // CGWindowListCopyWindowInfo call per monitor.
        let now = ProcessInfo.processInfo.systemUptime
        if now - Self.windowInfoTimestamp >= 0.20 {
            Self.cachedWindowInfo = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            Self.windowInfoTimestamp = now
        }
        let info = Self.cachedWindowInfo
        let mainTop = (NSScreen.main ?? NSScreen.screens.first)?.frame.maxY ?? screenFrame.maxY
        for w in info {
                guard let layerN = w[kCGWindowLayer as String] as? NSNumber, layerN.intValue == 0,
                      let pidN = w[kCGWindowOwnerPID as String] as? NSNumber, pidN.int32Value != myPID,
                      let numN = w[kCGWindowNumber as String] as? NSNumber,
                      let bd = w[kCGWindowBounds as String] as? NSDictionary,
                      let b = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
                let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                if alpha < 0.05 || b.width < 80 || b.height < 40 { continue }
                // Convert WindowServer's top-left global coordinates into AppKit global
                // coordinates, then into this display scene's local coordinate space.
                let globalRect = CGRect(x: b.minX, y: mainTop - b.maxY, width: b.width, height: b.height)
                guard globalRect.intersects(screenFrame) else { continue }
                let localRect = globalRect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
                newOrder.append((id: numN.intValue, rect: localRect))
        }

        // Closed / minimized windows: their snow just falls
        let alive = Set(newOrder.map { $0.id })
        for (id, pile) in piles where !alive.contains(id) {
            release(pile, vel: .zero, id: id)
            pile.remove()
            piles[id] = nil
            lastRect[id] = nil
        }

        for item in newOrder {
            let id = item.id, r = item.rect
            if let pile = piles[id], let old = lastRect[id] {
                if abs(old.width - r.width) > 0.5 {
                    // Width changed: drop the snow and start a new pile
                    release(pile, vel: .zero, id: id)
                    pile.remove()
                    piles[id] = Pile(minX: r.minX, topY: r.maxY, width: r.width, maxH: Cfg.windowPileMax, parent: world)
                } else if abs(old.minX - r.minX) > 0.3 || abs(old.maxY - r.maxY) > 0.3 {
                    // Window dragged: fling the snow off
                    let v = CGVector(dx: (r.minX - old.minX) / dt, dy: (r.maxY - old.maxY) / dt)
                    pile.minX = r.minX
                    pile.topY = r.maxY
                    release(pile, vel: v, id: id)
                }
            } else {
                piles[id] = Pile(minX: r.minX, topY: r.maxY, width: r.width, maxH: Cfg.windowPileMax, parent: world)
            }
            lastRect[id] = r
        }
        order = newOrder

        // The Dock rarely changes; checking every 0.5 s is enough
        dockAcc += dt
        if dockAcc >= 0.5 {
            dockAcc = 0
            updateDock()
        }

        computeOcclusion()
        for p in piles.values { p.redraw() }
        dockPile?.redraw()
        ground?.redraw()
    }

    func fallbackDockRect() -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) ?? NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        guard reserved > 10 && reserved < 160 else { return nil }
        var tileSize: CGFloat = max(36, min(96, reserved - 16))
        var iconCount: CGFloat = 14
        let plistPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        if let dict = NSDictionary(contentsOfFile: plistPath) {
            if let ts = (dict["tilesize"] as? NSNumber)?.doubleValue, ts > 16 {
                tileSize = CGFloat(ts)
            }
            let apps = (dict["persistent-apps"] as? [Any])?.count ?? 0
            let others = (dict["persistent-others"] as? [Any])?.count ?? 0
            let recent = (dict["recent-apps"] as? [Any])?.count ?? 0
            if apps + others > 0 {
                iconCount = CGFloat(apps + others + min(3, recent) + 2)
            }
        }
        let estWidth = min(size.width - 40, max(240, iconCount * (tileSize + 6) + 28 + 2 * Cfg.dockPad))
        let minX = (size.width - estWidth) * 0.5
        return CGRect(x: minX, y: 0, width: estWidth, height: reserved)
    }

    func updateDock() {
        guard isPrimaryDisplay, let dockTracker else { return }
        var r: CGRect? = nil
        var status: String
        if let f = dockTracker.frame() {
            var s = CGRect(x: f.minX - screenFrame.minX - Cfg.dockPad, y: size.height - f.maxY,
                           width: f.width + 2 * Cfg.dockPad, height: f.height)
            // The AX frame can reach a bit above the visible Dock shelf. When the Dock is always
            // shown, the space macOS reserves for it (bottom of visibleFrame) is a better top edge.
            if let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) ?? NSScreen.main ?? NSScreen.screens.first {
                let reserved = screen.visibleFrame.minY - screen.frame.minY
                if reserved > 10 && reserved < s.maxY { s.size.height = reserved - s.minY }
            }
            // Only handle a Dock that sits at the bottom of the screen and is currently on screen.
            // With auto-hide, a hidden Dock is reported below the screen edge, so it fails this check.
            if s.width > s.height && s.minY < 40 && s.maxY > 8 {
                r = s
                status = "found at x=\(Int(s.minX)) width=\(Int(s.width)) top=\(Int(s.maxY)) (AX top \(Int(size.height - f.minY)), screen \(Int(size.width))x\(Int(size.height)))"
            } else {
                status = "ignored (not at bottom or hidden), AX frame = \(f)"
            }
        } else if let fallback = fallbackDockRect() {
            r = fallback
            status = "found via visibleFrame fallback at x=\(Int(fallback.minX)) width=\(Int(fallback.width)) top=\(Int(fallback.maxY)) (\(dockTracker.lastError))"
        } else {
            status = "not found: \(dockTracker.lastError)"
        }
        // Log only when the status changes, so the terminal doesn't get flooded
        let key = status.components(separatedBy: " at ").first ?? status
        if key != lastDockStatus {
            print("❄︎ Dock " + status)
            lastDockStatus = key
        }
        if let old = dockRect, let r = r,
           abs(old.minX - r.minX) < 2.0, abs(old.width - r.width) < 2.0, abs(old.maxY - r.maxY) < 2.0 {
            return
        }
        if let r = r {
            let newTopY = r.maxY + Cfg.dockTopOffset
            let newPile = Pile(minX: r.minX, topY: newTopY, width: r.width,
                               maxH: Cfg.dockPileMax, parent: world)
            if let oldPile = dockPile {
                // Preserve existing snow across Dock magnification or app icon changes by resampling at matching X
                for newCol in 0..<newPile.count {
                    let x = newPile.colX(newCol)
                    if let oldCol = oldPile.col(at: x), oldPile.h[oldCol] > 0 {
                        newPile.h[newCol] = min(newPile.caps[newCol], oldPile.h[oldCol])
                    }
                }
                newPile.dirty = true
                newPile.redraw()
                // Transfer any resting snowballs on the Dock to the updated Dock pile
                let lo = newPile.minX + Cfg.ballStartRadius
                let hi = newPile.minX + newPile.width - Cfg.ballStartRadius
                for b in balls where b.pile === oldPile {
                    if b.x >= lo && b.x <= hi {
                        b.pile = newPile
                        b.y = newPile.topY + b.r - 1.5
                    } else {
                        b.drop(vel: .zero)
                    }
                }
                oldPile.remove()
            }
            dockPile = newPile
            dockRect = r
        } else {
            // Dock hidden or moved off the bottom edge: release its snow
            if let p = dockPile {
                release(p, vel: .zero, id: SnowScene.dockID)
                p.remove()
                dockPile = nil
            }
            dockRect = nil
        }
    }

    // Parts of a window top hidden behind a front window get no snow and aren't drawn
    func computeOcclusion() {
        for (i, item) in order.enumerated() {
            guard let p = piles[item.id] else { continue }
            for c in 0..<p.count {
                let pt = CGPoint(x: p.colX(c), y: p.topY + 1)
                var o = pt.x < 0 || pt.x > size.width || pt.y > size.height
                if !o {
                    for j in 0..<i where order[j].rect.contains(pt) { o = true; break }
                }
                if o != p.occ[c] {
                    p.occ[c] = o
                    if o { p.h[c] = 0 }
                    p.dirty = true
                }
            }
        }
        if let g = ground {
            for c in 0..<g.count {
                let pt = CGPoint(x: g.colX(c), y: 1)
                var o = false
                for item in order where item.rect.contains(pt) { o = true; break }
                if o != g.occ[c] {
                    g.occ[c] = o
                    if o { g.h[c] = 0 }
                    g.dirty = true
                }
            }
        }
    }

    func stepWind(_ dt: CGFloat) -> (wind: CGFloat, lift: CGFloat) {
        windTimer -= dt
        if windTimer <= 0 {
            let roll = CGFloat.random(in: 0...1)
            let next: WindRegime = roll < 0.40 ? .gentleBreeze : (roll < 0.78 ? .moderateWind : .strongGust)
            windRegime = next
            windTimer = CGFloat.random(in: next.durationRange)
            targetWindScale = next.amplitudeScale
            targetWindBias = CGFloat.random(in: next.steadyBiasRange)
            targetWindLift = next.verticalLiftFactor
        }
        let blend = min(1, dt * 0.45)
        currentWindScale += (targetWindScale - currentWindScale) * blend
        currentWindBias += (targetWindBias - currentWindBias) * blend
        currentWindLift += (targetWindLift - currentWindLift) * blend

        let baseWave = 14 * sin(t * 0.11) + 9 * sin(t * 0.37 + 1.3) + 6 * sin(t * 0.9 + 0.4)
        let gustRipple = 8 * sin(t * 1.45 + 0.7) * max(0, currentWindScale - 1.0)
        let wind = baseWave * currentWindScale + currentWindBias + gustRipple
        return (wind, currentWindLift)
    }

    func stepFlakes(_ dt: CGFloat) {
        // A few sines at different frequencies add up to gusty wind
        let (wind, windLift) = stepWind(dt)
        var normal = 0
        var i = flakes.count - 1
        while i >= 0 {
            let f = flakes[i]
            var p = f.node.position
            let prevY = p.y

            if f.isClump {
                f.vel.dy -= Cfg.gravity * dt
                f.vel.dx *= max(0, 1 - 1.2 * dt)
                p.x += f.vel.dx * dt
                p.y += f.vel.dy * dt
            } else {
                let sway = sin(t * f.swayFreq + f.phase) * f.swayAmp
                p.x += (wind * f.windFactor + sway) * dt
                let gustSlowdown = 1.0 - min(0.30, windLift * f.windFactor * min(1.0, abs(wind) / 60.0))
                p.y += (f.vel.dy * gustSlowdown) * dt
                if p.x < -40 { p.x += size.width + 80 } else if p.x > size.width + 40 { p.x -= size.width + 80 }
            }

            var gone = false
            if p.y < prevY {
                // The Dock is always in front of every window, so check it first
                if let d = dockPile, let c = d.col(at: p.x),
                   !(f.isClump && f.ignoreID == SnowScene.dockID && t < f.ignoreUntil) {
                    let s = d.surface(c)
                    if prevY >= s && p.y < s {
                        d.add(at: c, amount: (f.isClump ? 1.6 : f.size * 0.16) * Cfg.dockGain)
                        gone = true
                    }
                }
                // Then check window tops, front to back
                if !gone && !f.inFront { for item in order {
                    guard let pile = piles[item.id] else { continue }
                    if f.isClump && item.id == f.ignoreID && t < f.ignoreUntil { continue }
                    guard let c = pile.col(at: p.x), !pile.occ[c] else { continue }
                    let s = pile.surface(c)
                    if prevY >= s && p.y < s {
                        pile.add(at: c, amount: f.isClump ? 1.6 : f.size * 0.16)
                        gone = true
                        break
                    }
                } }
                // Finally the bottom of the screen
                if !gone, let g = ground, let c = g.col(at: p.x), p.y < g.surface(c) {
                    if !g.occ[c] { g.add(at: c, amount: f.isClump ? 1.6 : f.size * 0.12) }
                    gone = true
                }
            }
            if !gone {
                // Flakes that fall "behind" a window disappear
                if !f.inFront {
                    for item in order where item.rect.contains(p) { gone = true; break }
                }
                if p.y < -20 { gone = true }
                if f.isClump && (p.x < -80 || p.x > size.width + 80) { gone = true }
            }

            if gone {
                recycle(at: i)
            } else {
                f.node.position = p
                if !f.isClump { normal += 1 }
            }
            i -= 1
        }

        // Top up flakes (max 6 per frame so they don't appear in a row)
        let deficit = min(6, targetFlakes - normal)
        if deficit > 0 { for _ in 0..<deficit { spawnFlake() } }
    }
}

// MARK: - Transparent full-screen window + menu bar icon

/// Lets the very first click reach the scene even though this app is never the active app
final class OverlaySKView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayWindow: NSPanel {
    // Stop macOS from pushing the window below the menu bar
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class DisplayOverlay {
    let key: String
    let window: OverlayWindow
    let view: OverlaySKView
    let scene: SnowScene

    init(screen: NSScreen, isPrimary: Bool, targetFlakes: Int) {
        key = String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? screen.localizedName)
        let frame = screen.frame
        window = OverlayWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        view = OverlaySKView(frame: NSRect(origin: .zero, size: frame.size))
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        scene = SnowScene(size: frame.size, screenFrame: frame, isPrimaryDisplay: isPrimary,
                          targetFlakes: targetFlakes)
        scene.scaleMode = .resizeFill
        view.presentScene(scene)
        window.contentView = view
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var displays: [String: DisplayOverlay] = [:]
    var statusItem: NSStatusItem!
    var pauseItem: NSMenuItem!
    var amountItems: [NSMenuItem] = []
    var profileItems: [NSMenuItem] = []
    var isUserPaused = false
    var activeProfile: PerformanceProfile = .balanced
    var selectedSnowAmount = 260
    var reduceMotion = false

    // Settings window controls
    var settingsWindow: NSWindow?
    var profilePopup: NSPopUpButton?
    var amountPopup: NSPopUpButton?
    var reduceMotionCheckbox: NSButton?
    var launchAtLoginCheckbox: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPreferences()
        reconcileDisplays()
        setupMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(self, selector: #selector(suspendRendering), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(self, selector: #selector(resumeRendering), name: name, object: nil)
        }
        applyPerformanceProfile(activeProfile)
    }

    func loadPreferences() {
        if let raw = AppPreferences.defaults.string(forKey: AppPreferences.profileKey),
           let saved = PerformanceProfile(rawValue: raw) { activeProfile = saved }
        let savedAmount = AppPreferences.defaults.integer(forKey: AppPreferences.amountKey)
        if [120, 260, 500].contains(savedAmount) { selectedSnowAmount = savedAmount }
        reduceMotion = AppPreferences.defaults.bool(forKey: AppPreferences.reduceMotionKey)
    }

    func savePreferences() {
        AppPreferences.defaults.set(activeProfile.rawValue, forKey: AppPreferences.profileKey)
        AppPreferences.defaults.set(selectedSnowAmount, forKey: AppPreferences.amountKey)
        AppPreferences.defaults.set(reduceMotion, forKey: AppPreferences.reduceMotionKey)
    }

    func reconcileDisplays() {
        let screens = NSScreen.screens
        let primary = NSScreen.main ?? screens.first
        let desired = Set(screens.map { screenKey($0) })
        let removedKeys = displays.keys.filter { !desired.contains($0) }
        for key in removedKeys {
            guard let display = displays.removeValue(forKey: key) else { continue }
            display.window.orderOut(nil)
            display.scene.removeAllActions()
            display.scene.removeAllChildren()
        }
        let initialTotal = min(selectedSnowAmount, activeProfile.flakes)
        let initialPerDisplay = max(8, Int(ceil(Double(initialTotal) / Double(max(1, screens.count)))))
        for screen in screens {
            let key = screenKey(screen)
            if let existing = displays[key] {
                if existing.window.frame != screen.frame {
                    existing.window.setFrame(screen.frame, display: true)
                }
            } else {
                displays[key] = DisplayOverlay(screen: screen, isPrimary: screen === primary,
                                               targetFlakes: initialPerDisplay)
            }
        }
        applyPerformanceProfile(activeProfile)
        if isUserPaused {
            for display in displays.values {
                display.view.isPaused = true
                display.window.orderOut(nil)
            }
        }
    }

    func screenKey(_ screen: NSScreen) -> String {
        String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? screen.localizedName)
    }

    @objc func suspendRendering() {
        for display in displays.values { display.view.isPaused = true }
    }

    @objc func resumeRendering() {
        guard !isUserPaused else { return }
        for display in displays.values { display.view.isPaused = false }
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "❄︎"
        let menu = NSMenu()
        pauseItem = NSMenuItem(title: "Pause Snow", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        pauseItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(pauseItem)

        let amount = NSMenuItem(title: "Snow Amount", action: nil, keyEquivalent: "")
        let amountMenu = NSMenu()
        for (title, count) in [("Light", 120), ("Medium", 260), ("Heavy", 500)] {
            let item = NSMenuItem(title: title, action: #selector(setAmount(_:)), keyEquivalent: "")
            item.target = self
            item.tag = count
            item.state = count == selectedSnowAmount ? .on : .off
            amountMenu.addItem(item)
            amountItems.append(item)
        }
        amount.submenu = amountMenu
        menu.addItem(amount)

        let performance = NSMenuItem(title: "Performance Profile", action: nil, keyEquivalent: "")
        let performanceMenu = NSMenu()
        for profile in PerformanceProfile.allCases {
            let item = NSMenuItem(title: profile.rawValue, action: #selector(setProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.rawValue
            item.state = profile == activeProfile ? .on : .off
            performanceMenu.addItem(item)
            profileItems.append(item)
        }
        performance.submenu = performanceMenu
        menu.addItem(performance)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)
        let clear = NSMenuItem(title: "Clear Snow", action: #selector(clearSnow), keyEquivalent: "c")
        clear.target = self
        clear.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func applyPerformanceProfile(_ profile: PerformanceProfile) {
        activeProfile = profile
        Cfg.pollInterval = profile.windowPollInterval
        let motionCap = reduceMotion ? 80 : profile.flakes
        Cfg.targetFlakes = min(selectedSnowAmount, motionCap)
        let perDisplay = max(8, Int(ceil(Double(Cfg.targetFlakes) / Double(max(1, displays.count)))))
        for display in displays.values {
            display.view.preferredFramesPerSecond = reduceMotion ? min(15, profile.framesPerSecond) : profile.framesPerSecond
            display.scene.applyTargetFlakes(perDisplay)
        }
        for item in profileItems {
            item.state = (item.representedObject as? String == profile.rawValue) ? .on : .off
        }
        for item in amountItems { item.state = item.tag == selectedSnowAmount ? .on : .off }
        savePreferences()
        updateSettingsControls()
    }

    @objc func setProfile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let profile = PerformanceProfile(rawValue: raw) else { return }
        applyPerformanceProfile(profile)
    }

    @objc func togglePause() {
        isUserPaused.toggle()
        if isUserPaused {
            for display in displays.values {
                display.view.isPaused = true
                display.window.orderOut(nil)
            }
            pauseItem.title = "Resume Snow"
        } else {
            for display in displays.values {
                display.view.isPaused = false
                display.window.orderFrontRegardless()
            }
            pauseItem.title = "Pause Snow"
        }
    }

    @objc func setAmount(_ sender: NSMenuItem) {
        selectedSnowAmount = sender.tag
        let motionCap = reduceMotion ? 80 : activeProfile.flakes
        Cfg.targetFlakes = min(selectedSnowAmount, motionCap)
        let perDisplay = max(8, Int(ceil(Double(Cfg.targetFlakes) / Double(max(1, displays.count)))))
        for display in displays.values { display.scene.applyTargetFlakes(perDisplay) }
        for item in amountItems { item.state = item === sender ? .on : .off }
        savePreferences()
        updateSettingsControls()
    }

    @objc func clearSnow() { for display in displays.values { display.scene.clearAll() } }

    @objc func screensChanged() { reconcileDisplays() }

    // MARK: Settings window

    @objc func openSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        updateSettingsControls()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildSettingsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 390),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WinterIsComing Settings"
        window.isReleasedWhenClosed = false
        let content = NSView()
        window.contentView = content

        let heading = NSTextField(labelWithString: "Customize your winter desktop")
        heading.font = .boldSystemFont(ofSize: 18)
        heading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(heading)

        let intro = NSTextField(wrappingLabelWithString: "Choose a manual performance profile. Settings are saved automatically and restored the next time you launch the app.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(intro)

        let profileLabel = NSTextField(labelWithString: "Performance profile")
        profileLabel.translatesAutoresizingMaskIntoConstraints = false
        let profile = NSPopUpButton(frame: .zero, pullsDown: false)
        profile.addItems(withTitles: PerformanceProfile.allCases.map { $0.rawValue })
        profile.target = self
        profile.action = #selector(settingsProfileChanged(_:))
        profile.translatesAutoresizingMaskIntoConstraints = false
        profilePopup = profile
        content.addSubview(profileLabel)
        content.addSubview(profile)

        let amountLabel = NSTextField(labelWithString: "Snow amount")
        amountLabel.translatesAutoresizingMaskIntoConstraints = false
        let amount = NSPopUpButton(frame: .zero, pullsDown: false)
        amount.addItems(withTitles: ["Light", "Medium", "Heavy"])
        amount.target = self
        amount.action = #selector(settingsAmountChanged(_:))
        amount.translatesAutoresizingMaskIntoConstraints = false
        amountPopup = amount
        content.addSubview(amountLabel)
        content.addSubview(amount)

        let motion = NSButton(checkboxWithTitle: "Reduce motion and visual intensity", target: self,
                              action: #selector(settingsReduceMotionChanged(_:)))
        motion.translatesAutoresizingMaskIntoConstraints = false
        reduceMotionCheckbox = motion
        content.addSubview(motion)

        let login = NSButton(checkboxWithTitle: "Launch at login", target: self,
                             action: #selector(settingsLaunchAtLoginChanged(_:)))
        login.translatesAutoresizingMaskIntoConstraints = false
        launchAtLoginCheckbox = login
        content.addSubview(login)

        let shortcutTitle = NSTextField(labelWithString: "Keyboard shortcuts")
        shortcutTitle.font = .boldSystemFont(ofSize: 13)
        shortcutTitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(shortcutTitle)
        let shortcuts = NSTextField(wrappingLabelWithString: "⌘⌥P  Pause / Resume     ⌘⌥C  Clear snow     ⌘,  Open settings")
        shortcuts.font = .systemFont(ofSize: 12)
        shortcuts.textColor = .secondaryLabelColor
        shortcuts.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(shortcuts)

        let note = NSTextField(wrappingLabelWithString: "Accessibility: enable Reduce Motion to lower the frame rate and limit snowfall intensity. Ambient sound and animals are not included in this build.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(note)

        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            intro.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            intro.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            intro.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            profileLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            profileLabel.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 22),
            profileLabel.widthAnchor.constraint(equalToConstant: 150),
            profile.centerYAnchor.constraint(equalTo: profileLabel.centerYAnchor),
            profile.leadingAnchor.constraint(equalTo: profileLabel.trailingAnchor, constant: 12),
            profile.widthAnchor.constraint(equalToConstant: 220),
            amountLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            amountLabel.topAnchor.constraint(equalTo: profileLabel.bottomAnchor, constant: 18),
            amountLabel.widthAnchor.constraint(equalTo: profileLabel.widthAnchor),
            amount.centerYAnchor.constraint(equalTo: amountLabel.centerYAnchor),
            amount.leadingAnchor.constraint(equalTo: amountLabel.trailingAnchor, constant: 12),
            amount.widthAnchor.constraint(equalTo: profile.widthAnchor),
            motion.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            motion.topAnchor.constraint(equalTo: amountLabel.bottomAnchor, constant: 20),
            login.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            login.topAnchor.constraint(equalTo: motion.bottomAnchor, constant: 12),
            shortcutTitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            shortcutTitle.topAnchor.constraint(equalTo: login.bottomAnchor, constant: 22),
            shortcuts.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            shortcuts.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            shortcuts.topAnchor.constraint(equalTo: shortcutTitle.bottomAnchor, constant: 7),
            note.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            note.topAnchor.constraint(equalTo: shortcuts.bottomAnchor, constant: 12)
        ])
        settingsWindow = window
    }

    func updateSettingsControls() {
        guard let window = settingsWindow else { return }
        _ = window
        profilePopup?.selectItem(withTitle: activeProfile.rawValue)
        let amountTitle = selectedSnowAmount == 120 ? "Light" : (selectedSnowAmount == 500 ? "Heavy" : "Medium")
        amountPopup?.selectItem(withTitle: amountTitle)
        reduceMotionCheckbox?.state = reduceMotion ? .on : .off
        launchAtLoginCheckbox?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func settingsProfileChanged(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title, let profile = PerformanceProfile(rawValue: title) else { return }
        applyPerformanceProfile(profile)
    }

    @objc func settingsAmountChanged(_ sender: NSPopUpButton) {
        let count = sender.indexOfSelectedItem == 0 ? 120 : (sender.indexOfSelectedItem == 2 ? 500 : 260)
        selectedSnowAmount = count
        let motionCap = reduceMotion ? 80 : activeProfile.flakes
        Cfg.targetFlakes = min(selectedSnowAmount, motionCap)
        let perDisplay = max(8, Int(ceil(Double(Cfg.targetFlakes) / Double(max(1, displays.count)))))
        for display in displays.values { display.scene.applyTargetFlakes(perDisplay) }
        savePreferences()
        for item in amountItems { item.state = item.tag == selectedSnowAmount ? .on : .off }
    }

    @objc func settingsReduceMotionChanged(_ sender: NSButton) {
        reduceMotion = sender.state == .on
        savePreferences()
        applyPerformanceProfile(activeProfile)
    }

    @objc func settingsLaunchAtLoginChanged(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Could not update Launch at Login"
            alert.informativeText = "Run WinterIsComing from its packaged .app bundle and check System Settings → General → Login Items.\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.beginSheetModal(for: settingsWindow!)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
