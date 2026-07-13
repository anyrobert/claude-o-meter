// Claude-O-Meter — floating variant. A draggable circular button (Claude glyph
// inside a colored usage ring) that floats above all windows on every Space,
// like the claude.ai userscript's overlay button. Click toggles the usage
// panel; drag moves it (position persists); right-click for a menu.

import AppKit
import Combine
import SwiftUI

// MARK: - Button rendering

enum ButtonRenderer {
    static let diameter: CGFloat = 48

    static func draw(in bounds: NSRect, percent: Double?, hasError: Bool, dark: Bool) {
        let ringWidth: CGFloat = 3

        // Disc — same colors as the userscript button (#fff / #2b2b2b).
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        (dark ? NSColor(srgbRed: 0.169, green: 0.169, blue: 0.169, alpha: 1) : .white).setFill()
        disc.fill()

        // Ring track on the disc rim.
        let ringRect = bounds.insetBy(dx: ringWidth / 2 + 1.5, dy: ringWidth / 2 + 1.5)
        let track = NSBezierPath(ovalIn: ringRect)
        track.lineWidth = ringWidth
        NSColor.gray.withAlphaComponent(0.3).setStroke()
        track.stroke()

        // Progress arc, clockwise from 12 o'clock.
        if !hasError, let percent, percent > 0.5 {
            let fraction = min(max(percent, 0), 100) / 100
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: NSPoint(x: bounds.midX, y: bounds.midY),
                radius: ringRect.width / 2,
                startAngle: 90,
                endAngle: 90 - 360 * fraction,
                clockwise: true
            )
            arc.lineWidth = ringWidth
            arc.lineCapStyle = .round
            Ring.nsColor(for: percent).setStroke()
            arc.stroke()
        }

        // Claude glyph, centered at half the button size.
        let glyphSize = bounds.width * 0.5
        let glyphRect = NSRect(
            x: bounds.midX - glyphSize / 2,
            y: bounds.midY - glyphSize / 2,
            width: glyphSize,
            height: glyphSize
        )
        ClaudeGlyph.color.setFill()
        ClaudeGlyph.path(in: glyphRect).fill()
    }

    static func image(percent: Double?, hasError: Bool, dark: Bool, diameter: CGFloat = ButtonRenderer.diameter) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            draw(in: rect, percent: percent, hasError: hasError, dark: dark)
            return true
        }
    }
}

// MARK: - The floating button view (draw + drag/click/right-click)

@MainActor
final class FloatButtonView: NSView {
    private let model: UsageModel
    private var cancellable: AnyCancellable?

    private var mouseDownScreenPoint = NSPoint.zero
    private var windowOriginAtMouseDown = NSPoint.zero
    private var dragging = false
    private let dragThreshold: CGFloat = 4

    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model))
        return popover
    }()

    init(model: UsageModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: ButtonRenderer.diameter, height: ButtonRenderer.diameter))
        toolTip = "Claude usage — click for details, drag to move, right-click for menu"
        cancellable = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.needsDisplay = true
                self?.window?.invalidateShadow()
            }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ButtonRenderer.draw(in: bounds, percent: model.sessionPercent, hasError: model.hasError, dark: dark)
    }

    // React on the first click even when another app is frontmost.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Drag to move; a press that doesn't move past the threshold counts as a
    // click and toggles the panel — same behavior as the userscript.
    override func mouseDown(with event: NSEvent) {
        dragging = false
        mouseDownScreenPoint = NSEvent.mouseLocation
        windowOriginAtMouseDown = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let location = NSEvent.mouseLocation
        let dx = location.x - mouseDownScreenPoint.x
        let dy = location.y - mouseDownScreenPoint.y
        if !dragging {
            guard hypot(dx, dy) >= dragThreshold else { return }
            if popover.isShown { popover.performClose(nil) }  // close the panel as the drag starts
            dragging = true
        }
        window.setFrameOrigin(NSPoint(x: windowOriginAtMouseDown.x + dx, y: windowOriginAtMouseDown.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            if let origin = window?.frame.origin {
                UserDefaults.standard.set([origin.x, origin.y], forKey: FloatWindow.positionKey)
            }
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)  // let the panel's buttons take clicks
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let details = NSMenuItem(title: "Open claude.ai usage", action: #selector(openDetails), keyEquivalent: "")
        details.target = self
        menu.addItem(details)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Claude-O-Meter", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func refreshNow() { model.refreshNow() }
    @objc private func openDetails() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - The floating window

@MainActor
final class FloatWindow: NSPanel {
    static let positionKey = "FloatWindowOrigin"

    init(model: UsageModel) {
        let diameter = ButtonRenderer.diameter
        super.init(
            contentRect: NSRect(origin: Self.restoredOrigin(size: diameter),
                                size: NSSize(width: diameter, height: diameter)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false  // drag is hand-rolled in FloatButtonView
        contentView = FloatButtonView(model: model)
    }

    // Saved position if it's still on a connected screen, else bottom-right.
    private static func restoredOrigin(size: CGFloat) -> NSPoint {
        if let saved = UserDefaults.standard.array(forKey: positionKey) as? [Double], saved.count == 2 {
            let rect = NSRect(x: saved[0], y: saved[1], width: size, height: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                return rect.origin
            }
        }
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: frame.maxX - size - 20, y: frame.minY + 20)
    }
}

// MARK: - App

@MainActor
final class FloatAppDelegate: NSObject, NSApplicationDelegate {
    private var model: UsageModel?
    private var window: FloatWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = UsageModel()
        self.model = model
        let window = FloatWindow(model: model)
        self.window = window
        window.orderFrontRegardless()
    }
}

@main
struct ClaudeOMeterFloatApp: App {
    @NSApplicationDelegateAdaptor(FloatAppDelegate.self) private var delegate

    init() {
        let args = CommandLine.arguments
        if args.contains("--check") {
            runCheckAndExit()
        }
        // Debug: render the button to PNGs (light + dark) without launching the UI.
        if let index = args.firstIndex(of: "--render-icon"), args.count > index + 1 {
            renderIconAndExit(basePath: args[index + 1])
        }
    }

    var body: some Scene {
        Settings { EmptyView() }  // no regular windows; the FloatWindow is the UI
    }
}

func renderIconAndExit(basePath: String) -> Never {
    for (suffix, dark) in [("light", false), ("dark", true)] {
        let image = ButtonRenderer.image(percent: 42, hasError: false, dark: dark, diameter: 96)
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            print("ERROR: render failed")
            exit(1)
        }
        let path = "\(basePath)-\(suffix).png"
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } catch {
            print("ERROR: \(error)")
            exit(1)
        }
    }
    exit(0)
}
