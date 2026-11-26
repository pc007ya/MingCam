import AppKit
import SwiftUI

@MainActor
final class RegionOverlayController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var regionRectInAppKit: CGRect = CGRect(x: 200, y: 200, width: 1280, height: 720)
    @Published var isRecording: Bool = false {
        didSet {
            updateMousePassThrough()
        }
    }
    @Published var isPaused: Bool = false
    @Published var isVisible: Bool = false

    private var panel: NSPanel?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?

    override init() {
        super.init()
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let w: CGFloat = min(1024, vf.width * 0.65)
            let h: CGFloat = min(640, vf.height * 0.65)
            let x = vf.midX - w / 2
            let y = vf.midY - h / 2
            regionRectInAppKit = CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
        }
    }

    var overlayWindowNumber: Int? {
        panel?.windowNumber
    }

    func show() {
        if panel == nil {
            createPanel()
        }
        panel?.setFrame(regionRectInAppKit, display: true)
        panel?.orderFront(nil)
        isVisible = true
        startMouseMonitoring()
        updateMousePassThrough()
    }

    func hide() {
        stopMouseMonitoring()
        panel?.orderOut(nil)
        isVisible = false
    }

    func setPresetSize(width: CGFloat, height: CGFloat) {
        guard let screen = panel?.screen ?? NSScreen.main else { return }
        let sf = screen.visibleFrame
        let w = min(width, sf.width)
        let h = min(height, sf.height)
        let x = sf.midX - w / 2
        let y = sf.midY - h / 2
        let newRect = CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
        regionRectInAppKit = newRect
        panel?.setFrame(newRect, display: true, animate: true)
    }

    /// Converts the AppKit global window rect into top-left origin coordinates relative to the given NSScreen
    func sourceRect(for screen: NSScreen) -> CGRect {
        let sf = screen.frame
        let wf = panel?.frame ?? regionRectInAppKit
        let x = max(0, wf.minX - sf.minX)
        let y = max(0, sf.maxY - wf.maxY)
        let w = min(wf.width, sf.width - x)
        let h = min(wf.height, sf.height - y)
        return CGRect(x: x.rounded(), y: y.rounded(), width: max(64, w.rounded()), height: max(64, h.rounded()))
    }

    private func startMouseMonitoring() {
        stopMouseMonitoring()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMousePassThrough()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.updateMousePassThrough()
            }
            return event
        }
    }

    private func stopMouseMonitoring() {
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
        if let lm = localMouseMonitor {
            NSEvent.removeMonitor(lm)
            localMouseMonitor = nil
        }
    }

    private func updateMousePassThrough() {
        guard let panel = panel, isVisible else { return }
        if isRecording {
            panel.ignoresMouseEvents = true
            return
        }

        let mouseLoc = NSEvent.mouseLocation
        // If mouse is inside any other MingCam window (the main control panel), always pass through!
        for win in NSApp.windows where win !== panel && win.isVisible {
            if win.frame.contains(mouseLoc) {
                panel.ignoresMouseEvents = true
                return
            }
        }

        let pf = panel.frame
        guard pf.insetBy(dx: -10, dy: -10).contains(mouseLoc) else {
            panel.ignoresMouseEvents = true
            return
        }

        // Only intercept mouse events on the 14pt border or top-left drag badge
        let innerHollowRect = pf.insetBy(dx: 14, dy: 14)
        let topDragBadgeRect = CGRect(x: pf.minX, y: pf.maxY - 48, width: min(360, pf.width), height: 48)

        if topDragBadgeRect.contains(mouseLoc) || !innerHollowRect.contains(mouseLoc) {
            panel.ignoresMouseEvents = false
        } else {
            panel.ignoresMouseEvents = true
        }
    }

    private func createPanel() {
        let style: NSWindow.StyleMask = [.borderless, .resizable, .nonactivatingPanel]
        let p = NSPanel(
            contentRect: regionRectInAppKit,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.minSize = NSSize(width: 200, height: 150)
        p.delegate = self

        let hostingView = NSHostingView(rootView: RegionOverlayView(controller: self))
        p.contentView = hostingView
        self.panel = p
    }

    func windowDidMove(_ notification: Notification) {
        if let f = panel?.frame {
            regionRectInAppKit = f
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let f = panel?.frame {
            regionRectInAppKit = f
        }
    }
}

struct RegionOverlayView: View {
    @ObservedObject var controller: RegionOverlayController

    var borderColor: Color {
        if controller.isRecording {
            return controller.isPaused ? Color.yellow : Color.red
        }
        return Color.green
    }

    var statusLabel: String {
        if controller.isRecording {
            return controller.isPaused ? "PAUSED" : "REC"
        }
        return "按住此標籤拖曳移動・拉動綠框邊緣調整大小"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Completely clear interior so clicks pass right through
            Color.clear

            // Outer Bandicam-style frame
            Rectangle()
                .strokeBorder(borderColor, lineWidth: controller.isRecording ? 3 : 5)

            // Corner markers when not recording
            if !controller.isRecording {
                CornerMarkers(color: borderColor)
            }

            // Top info & drag badge
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(borderColor)
                Text("\(Int(controller.regionRectInAppKit.width)) × \(Int(controller.regionRectInAppKit.height))")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("｜")
                    .foregroundColor(.white.opacity(0.4))
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.85))
            .cornerRadius(6)
            .padding(8)
        }
    }
}

struct CornerMarkers: View {
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let len: CGFloat = 20
            let thick: CGFloat = 6
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: len))
                    p.addLine(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: len, y: 0))
                }
                .stroke(color, lineWidth: thick)

                Path { p in
                    p.move(to: CGPoint(x: geo.size.width - len, y: 0))
                    p.addLine(to: CGPoint(x: geo.size.width, y: 0))
                    p.addLine(to: CGPoint(x: geo.size.width, y: len))
                }
                .stroke(color, lineWidth: thick)

                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height - len))
                    p.addLine(to: CGPoint(x: 0, y: geo.size.height))
                    p.addLine(to: CGPoint(x: len, y: geo.size.height))
                }
                .stroke(color, lineWidth: thick)

                Path { p in
                    p.move(to: CGPoint(x: geo.size.width - len, y: geo.size.height))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - len))
                }
                .stroke(color, lineWidth: thick)
            }
        }
    }
}
