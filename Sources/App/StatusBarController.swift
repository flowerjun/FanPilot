import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Menu bar item. Left-click cycles AUTO → CUSTOM → CONSTANT; right-click (or ⌃-click) opens the settings popover.
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    private var updateScheduled = false
    private var appearanceObservation: NSKeyValueObservation?

    // Spinning icon. Swapping NSStatusItem images makes AppKit redraw the whole item (and its
    // per-Space replicants) every frame, which cost 8–20% CPU. Instead a layer sits over the
    // button's (blank) image slot and Core Animation spins it, so the app only retunes the
    // speed when the RPM reading changes.
    private static let degreesPerSecondPerRPM = 0.075   // 1500 RPM → 112°/s, 4900 RPM → 367°/s
    private let spinLayer = CALayer()
    private let maskLayer = CALayer()
    private var masks: [String: CGImage] = [:]
    private var iconSize = NSSize(width: 18, height: 18)
    private var currentSymbol = ""
    private var currentSpeed = 0.0   // degrees per second
    private var shownTitleKey = ""
    private var shownToolTip = ""
    /// Horizontal margin inside the item, per side. AppKit's default is 2 pt; 0 makes the item
    /// exactly as wide as icon + text (the menu bar still adds its own spacing between items).
    private static let sideMargin: CGFloat = 0
    /// Menu bar font with fixed-width digits, so 1499 → 1500 doesn't jiggle the text or resize the item.
    private static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

    init(model: AppModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.font = Self.titleFont
            button.image = NSImage(size: iconSize)   // transparent placeholder that reserves the icon's space
            button.wantsLayer = true
            spinLayer.mask = maskLayer
            button.layer?.addSublayer(spinLayer)
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateTint() }
            }
        }
        // objectWillChange fires before the value lands and often several times per change;
        // coalesce into one update on the next runloop turn.
        for publisher in [model.objectWillChange.eraseToAnyPublisher(), model.live.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &cancellables)
        }
        updateButton()
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.updateScheduled = false
            self?.updateButton()
        }
    }

    // MARK: Icon

    private func updateIcon() {
        guard let button = item.button else { return }
        // Hidden icon: drop the placeholder image so the slot collapses, hide the layer and
        // stop the spin entirely.
        let wantImage = model.showIcon
        if (button.image != nil) != wantImage {
            button.image = wantImage ? NSImage(size: iconSize) : nil
            button.imagePosition = wantImage ? .imageLeading : .noImage
        }
        if spinLayer.isHidden == wantImage {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            spinLayer.isHidden = !wantImage
            CATransaction.commit()
        }
        guard wantImage else { setSpeed(0); return }

        let symbol = model.saved.mode == .system ? "fan" : "fan.fill"
        if symbol != currentSymbol {
            if masks[symbol] == nil { masks[symbol] = Self.renderMask(symbol: symbol, size: iconSize) }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            maskLayer.contents = masks[symbol]
            CATransaction.commit()
            currentSymbol = symbol
        }
        positionLayer()
        // Speed 0 freezes the layer where it is (animation off).
        setSpeed(model.spinIcon ? (model.live.readings.fanRPM ?? 0) * Self.degreesPerSecondPerRPM : 0)
    }

    private func positionLayer() {
        guard let button = item.button, let cell = button.cell as? NSButtonCell else { return }
        let r = cell.imageRect(forBounds: button.bounds)
        // The image slot's center sits 0.75 pt below the title's digit center (measured from a
        // Retina screenshot against the system clock); nudge up so icon and text share a center.
        // The button is flipped, so "up" is negative y.
        let frame = CGRect(x: r.midX - iconSize.width / 2, y: r.midY - iconSize.height / 2 - 0.75, width: iconSize.width, height: iconSize.height)
        guard spinLayer.frame != frame else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spinLayer.frame = frame
        maskLayer.frame = spinLayer.bounds
        spinLayer.contentsScale = button.window?.backingScaleFactor ?? 2
        maskLayer.contentsScale = spinLayer.contentsScale
        CATransaction.commit()
    }

    private func updateTint() {
        guard let button = item.button else { return }
        var color = NSColor.labelColor.cgColor
        if let custom = model.iconColors[model.saved.mode] {
            color = custom.cgColor
        } else {
            button.effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        }
        guard spinLayer.backgroundColor != color else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spinLayer.backgroundColor = color
        CATransaction.commit()
    }

    /// One endless clockwise revolution per second at layer speed 1; the RPM only changes the
    /// layer's time scale. Re-basing beginTime/timeOffset keeps the angle continuous, and the
    /// direction can never flip because the animation itself is never rebuilt.
    private func setSpeed(_ dps: Double) {
        let dps = max(0, dps)
        if abs(dps - currentSpeed) < max(1, currentSpeed * 0.03) { return }   // ignore jitter
        currentSpeed = dps
        if spinLayer.animation(forKey: "spin") == nil {
            // The status bar button is a flipped view, which mirrors the sense of rotation:
            // there a positive angle turns clockwise on screen. (Image contents aren't flipped.)
            let flipped = item.button?.isFlipped ?? true
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = (flipped ? 2 : -2) * Double.pi   // clockwise on screen
            spin.duration = 1
            spin.repeatCount = .infinity
            spinLayer.add(spin, forKey: "spin")
        }
        let now = CACurrentMediaTime()
        let local = spinLayer.convertTime(now, from: nil)
        spinLayer.speed = Float(dps / 360)
        spinLayer.timeOffset = local
        spinLayer.beginTime = now
    }

    /// Alpha mask of the SF fan symbol, mirrored: its blades sweep for counter-clockwise
    /// spin, and the icon spins clockwise.
    private static func renderMask(symbol: String, size: NSSize) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "FanPilot")?.withSymbolConfiguration(config) else { return nil }
        let w = base.size.width, h = base.size.height
        let scale: CGFloat = 4
        var proposed = NSRect(x: 0, y: 0, width: w * scale, height: h * scale)
        guard let bitmap = base.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(bitmap, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Interaction

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            togglePopover()
        } else {
            model.cycleMode()
        }
    }

    private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Build the SwiftUI content only while the popover is open; a hidden hosting
            // controller would keep re-rendering on every model change.
            let hosting = NSHostingController(rootView: ContentView(inPopover: true).environmentObject(model))
            hosting.sizingOptions = .preferredContentSize
            popover.contentViewController = hosting
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let readings = model.live.readings
        let temp = readings.temperature(for: model.saved.source)
        // Filled fan = FanPilot is controlling; outline = macOS is.
        var parts: [String] = []
        if model.showTemp { parts.append(temp.map { model.tempUnit.text($0, symbol: false) } ?? "--°") }
        if model.showRPM { parts.append(readings.fanRPM.map { "\(Int($0))" } ?? "--") }
        let text = parts.joined(separator: "\u{2002}")   // en space: a bit wider than a normal space
        // imageHugsTitle leaves only ~3 pt between icon and text; a thin space adds a little air.
        let title = model.showIcon && !text.isEmpty ? "\u{2009}" + text : text
        let titleColor = model.titleColor(for: temp)
        let titleKey = title + (titleColor.map(AppModel.hexString) ?? "")
        if titleKey != shownTitleKey {   // avoid redrawing the item when nothing changed
            shownTitleKey = titleKey
            if let titleColor {
                button.attributedTitle = NSAttributedString(string: title, attributes: [
                    .foregroundColor: titleColor,
                    .font: Self.titleFont,
                ])
            } else {
                button.title = title   // plain title = the menu bar's own text color
            }
        }
        let toolTip = "\(AppModel.modeName(model.saved.mode)) — " + tr("클릭: 다음 모드, 우클릭: 설정", "Click: next mode, Right-click: settings")
        if toolTip != shownToolTip { shownToolTip = toolTip; button.toolTip = toolTip }
        updateIcon()
        updateTint()
        updateLength()
    }

    private func updateLength() {
        guard let button = item.button else { return }
        // intrinsicContentSize includes AppKit's 2 pt margin on each side.
        let width = ceil(button.intrinsicContentSize.width) - 2 * (2 - Self.sideMargin)
        if item.length != width {
            item.length = width
            positionLayer()   // image slot moves with the new layout
        }
    }
}

extension StatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
