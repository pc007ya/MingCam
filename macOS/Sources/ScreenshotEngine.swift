import AppKit
import SwiftUI
import ScreenCaptureKit

@MainActor
final class ScreenshotOverlayController: NSObject, ObservableObject {
    @Published var selectionRect: CGRect = .zero
    @Published var isDraggingSelection: Bool = false
    @Published var hasCompletedSelection: Bool = false
    @Published var cursorPosition: CGPoint = .zero
    @Published var currentHexColor: String = "#FFFFFF"
    @Published var currentRGBString: String = "255, 255, 255"
    @Published var currentPixelNSColor: NSColor = .white

    // Annotation State inside Overlay
    @Published var selectedTool: AnnotationTool? = nil
    @Published var selectedColor: Color = .red
    @Published var strokeWidth: CGFloat = 3.0
    @Published var shapes: [AnnotationShape] = []
    @Published var activeShape: AnnotationShape? = nil
    @Published var nextStepNumber: Int = 1
    @Published var pendingTextInput: String = ""
    @Published var textInputPosition: CGPoint? = nil

    var fullScreenCGImage: CGImage?
    var fullScreenNSImage: NSImage?
    var screenFrame: CGRect = .zero
    var backingScale: CGFloat = 2.0
    var colorPickerOnlyMode: Bool = false

    private var overlayWindow: SnipOverlayWindow?
    private var keyMonitor: Any?
    private var globalEventMonitor: Any?

    var isPresented: Bool {
        overlayWindow != nil
    }

    var onFinishWithImage: ((NSImage, SnipFinishAction, CGRect) -> Void)?
    var onColorPicked: ((String, String, NSColor) -> Void)?
    var onCancel: (() -> Void)?

    enum SnipFinishAction {
        case copy
        case save
        case pin
        case editInMain
    }

    func present(
        cgImage: CGImage,
        screen: NSScreen,
        colorPickerOnly: Bool,
        onFinishWithImage: @escaping (NSImage, SnipFinishAction, CGRect) -> Void,
        onColorPicked: @escaping (String, String, NSColor) -> Void,
        onCancel: @escaping () -> Void
    ) {
        // Always clean up any previous overlay window first so none can ever get stuck
        dismiss()

        self.fullScreenCGImage = cgImage
        self.screenFrame = screen.frame
        self.backingScale = CGFloat(cgImage.width) / max(1, screen.frame.width)
        self.fullScreenNSImage = NSImage(cgImage: cgImage, size: screen.frame.size)
        self.colorPickerOnlyMode = colorPickerOnly
        self.onFinishWithImage = onFinishWithImage
        self.onColorPicked = onColorPicked
        self.onCancel = onCancel

        self.selectionRect = .zero
        self.isDraggingSelection = false
        self.hasCompletedSelection = false
        self.selectedTool = nil
        self.shapes = []
        self.activeShape = nil
        self.nextStepNumber = 1
        self.textInputPosition = nil

        let win = SnipOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.onEscapeOrRightClick = { [weak self] isRightClick in
            guard let self else { return }
            if isRightClick && self.hasCompletedSelection {
                // First right-click resets selection (like Snipaste); second right-click exits
                self.selectionRect = .zero
                self.hasCompletedSelection = false
                self.shapes.removeAll()
                self.textInputPosition = nil
            } else {
                self.cancelAndDismiss()
            }
        }
        win.level = .statusBar + 1
        win.isOpaque = true
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.acceptsMouseMovedEvents = true
        let hostingView = NSHostingView(rootView: SnipOverlayView(controller: self))
        win.contentView = hostingView

        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        win.makeFirstResponder(hostingView)
        self.overlayWindow = win

        installKeyMonitor()
        GlobalHotkeyManager.shared.onEscapeTriggered = { [weak self] in
            self?.handleEscapePressed()
        }
        GlobalHotkeyManager.shared.setEscapeHotkeyActive(true)
    }

    func handleEscapePressed() {
        if textInputPosition != nil {
            textInputPosition = nil
            return
        }
        cancelAndDismiss()
    }

    func cancelAndDismiss() {
        let cancelCallback = onCancel
        dismiss()
        cancelCallback?()
    }

    func dismiss() {
        GlobalHotkeyManager.shared.setEscapeHotkeyActive(false)
        if let km = keyMonitor {
            NSEvent.removeMonitor(km)
            keyMonitor = nil
        }
        if let gm = globalEventMonitor {
            NSEvent.removeMonitor(gm)
            globalEventMonitor = nil
        }
        overlayWindow?.orderOut(nil)
        overlayWindow = nil

        // Guarantee no orphaned SnipOverlayWindow ever remains on screen
        for win in NSApp.windows where win is SnipOverlayWindow {
            win.orderOut(nil)
        }
    }

    func updateCursorInfo(at viewPoint: CGPoint) {
        cursorPosition = viewPoint
        guard let cg = fullScreenCGImage else { return }
        let px = Int((viewPoint.x * backingScale).rounded())
        let py = Int((viewPoint.y * backingScale).rounded())
        if let color = samplePixelColor(in: cg, x: px, y: py) {
            currentPixelNSColor = color
            let r = Int((color.redComponent * 255).rounded())
            let g = Int((color.greenComponent * 255).rounded())
            let b = Int((color.blueComponent * 255).rounded())
            currentHexColor = String(format: "#%02X%02X%02X", r, g, b)
            currentRGBString = "\(r), \(g), \(b)"
        }
    }

    func undoAnnotation() {
        guard !shapes.isEmpty else { return }
        let removed = shapes.removeLast()
        if removed.tool == .counter {
            nextStepNumber = max(1, nextStepNumber - 1)
        }
    }

    func clearAnnotations() {
        shapes.removeAll()
        nextStepNumber = 1
    }

    func commitTextAnnotation() {
        guard let pos = textInputPosition else { return }
        let trimmed = pendingTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let shape = AnnotationShape(
                tool: .text,
                points: [pos],
                color: NSColor(selectedColor),
                lineWidth: strokeWidth,
                text: trimmed
            )
            shapes.append(shape)
        }
        pendingTextInput = ""
        textInputPosition = nil
    }

    func completeCapture(action: SnipFinishAction) {
        commitTextAnnotation()
        guard let finalImage = renderCroppedAnnotatedImage() else {
            dismiss()
            onCancel?()
            return
        }
        // Convert view-space top-left selectionRect to global AppKit bottom-left screen coordinates for Pin placement
        let appKitOrigin = CGPoint(
            x: screenFrame.minX + selectionRect.minX,
            y: screenFrame.maxY - selectionRect.maxY
        )
        let appKitRect = CGRect(origin: appKitOrigin, size: selectionRect.size)
        dismiss()
        onFinishWithImage?(finalImage, action, appKitRect)
    }

    func renderCroppedAnnotatedImage() -> NSImage? {
        guard let cg = fullScreenCGImage else { return nil }
        let cropRectPoints = selectionRect.width > 4 && selectionRect.height > 4
            ? selectionRect
            : CGRect(origin: .zero, size: screenFrame.size)

        let pixelRect = CGRect(
            x: (cropRectPoints.minX * backingScale).rounded(),
            y: (cropRectPoints.minY * backingScale).rounded(),
            width: max(2, (cropRectPoints.width * backingScale).rounded()),
            height: max(2, (cropRectPoints.height * backingScale).rounded())
        )

        guard let croppedCG = cg.cropping(to: pixelRect) else { return nil }
        let targetSize = cropRectPoints.size

        let outImage = NSImage(size: targetSize)
        outImage.lockFocusFlipped(true)
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            outImage.unlockFocus()
            return nil
        }

        // Draw base cropped screenshot in flipped coordinates
        ctx.saveGState()
        ctx.translateBy(x: 0, y: targetSize.height)
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.draw(croppedCG, in: CGRect(origin: .zero, size: targetSize))
        ctx.restoreGState()

        // Draw all annotations offset by cropRectPoints.origin
        for shape in shapes {
            drawAnnotationShape(shape, in: ctx, offset: cropRectPoints.origin)
        }

        outImage.unlockFocus()
        return outImage
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .rightMouseDown {
                if self.hasCompletedSelection {
                    self.selectionRect = .zero
                    self.hasCompletedSelection = false
                    self.shapes.removeAll()
                    self.textInputPosition = nil
                } else {
                    self.cancelAndDismiss()
                }
                return nil
            }
            if event.keyCode == 53 { // ESC
                self.handleEscapePressed()
                return nil
            }
            if self.textInputPosition != nil {
                if event.keyCode == 36 { // Return
                    self.commitTextAnnotation()
                    return nil
                }
                return event
            }
            if event.charactersIgnoringModifiers?.lowercased() == "c" && !event.modifierFlags.contains(.command) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(self.currentHexColor, forType: .string)
                self.onColorPicked?(self.currentHexColor, self.currentRGBString, self.currentPixelNSColor)
                if self.colorPickerOnlyMode {
                    self.dismiss()
                }
                return nil
            }
            if event.charactersIgnoringModifiers?.lowercased() == "z" && event.modifierFlags.contains(.command) {
                self.undoAnnotation()
                return nil
            }
            if event.keyCode == 36 && self.hasCompletedSelection { // Enter -> Copy
                self.completeCapture(action: .copy)
                return nil
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if event.type == .rightMouseDown {
                    self.cancelAndDismiss()
                } else if event.keyCode == 53 {
                    self.handleEscapePressed()
                }
            }
        }
    }

    private func samplePixelColor(in cgImage: CGImage, x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height else { return nil }
        guard let singlePixel = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var raw = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &raw,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(singlePixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(
            calibratedRed: CGFloat(raw[0]) / 255.0,
            green: CGFloat(raw[1]) / 255.0,
            blue: CGFloat(raw[2]) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - Shared Annotation Renderer (CoreGraphics)
func drawAnnotationShape(_ shape: AnnotationShape, in ctx: CGContext, offset: CGPoint) {
    let pts = shape.points.map { CGPoint(x: $0.x - offset.x, y: $0.y - offset.y) }
    guard let first = pts.first else { return }
    let last = pts.last ?? first

    ctx.saveGState()
    defer { ctx.restoreGState() }

    switch shape.tool {
    case .rectangle:
        let rect = CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
        ctx.setStrokeColor(shape.color.cgColor)
        ctx.setLineWidth(shape.lineWidth)
        ctx.stroke(rect)

    case .ellipse:
        let rect = CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
        ctx.setStrokeColor(shape.color.cgColor)
        ctx.setLineWidth(shape.lineWidth)
        ctx.strokeEllipse(in: rect)

    case .line:
        ctx.setStrokeColor(shape.color.cgColor)
        ctx.setLineWidth(shape.lineWidth)
        ctx.setLineCap(.round)
        ctx.move(to: first)
        ctx.addLine(to: last)
        ctx.strokePath()

    case .arrow:
        ctx.setStrokeColor(shape.color.cgColor)
        ctx.setFillColor(shape.color.cgColor)
        ctx.setLineWidth(shape.lineWidth)
        ctx.setLineCap(.round)
        ctx.move(to: first)
        ctx.addLine(to: last)
        ctx.strokePath()

        let angle = atan2(last.y - first.y, last.x - first.x)
        let arrowLength: CGFloat = max(12, shape.lineWidth * 4.2)
        let arrowAngle: CGFloat = .pi / 6
        let p1 = CGPoint(
            x: last.x - arrowLength * cos(angle - arrowAngle),
            y: last.y - arrowLength * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: last.x - arrowLength * cos(angle + arrowAngle),
            y: last.y - arrowLength * sin(angle + arrowAngle)
        )
        ctx.move(to: last)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()

    case .pen:
        guard pts.count > 1 else { return }
        ctx.setStrokeColor(shape.color.cgColor)
        ctx.setLineWidth(shape.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: pts[0])
        for p in pts.dropFirst() {
            ctx.addLine(to: p)
        }
        ctx.strokePath()

    case .highlighter:
        guard pts.count > 1 else { return }
        ctx.setStrokeColor(shape.color.withAlphaComponent(0.38).cgColor)
        ctx.setLineWidth(max(14, shape.lineWidth * 4.5))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: pts[0])
        for p in pts.dropFirst() {
            ctx.addLine(to: p)
        }
        ctx.strokePath()

    case .mosaic:
        guard pts.count > 1 else { return }
        let blockSize: CGFloat = 12
        for p in pts {
            let bx = floor(p.x / blockSize) * blockSize
            let by = floor(p.y / blockSize) * blockSize
            let isEven = (Int(bx / blockSize) + Int(by / blockSize)) % 2 == 0
            ctx.setFillColor(
                isEven
                    ? NSColor(calibratedWhite: 0.25, alpha: 0.85).cgColor
                    : NSColor(calibratedWhite: 0.55, alpha: 0.85).cgColor
            )
            ctx.fill(CGRect(x: bx, y: by, width: blockSize, height: blockSize))
        }

    case .counter:
        let radius: CGFloat = 13
        let circleRect = CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(shape.color.cgColor)
        ctx.fillEllipse(in: circleRect)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: circleRect)

        let numStr = "\(shape.stepNumber)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .heavy),
            .foregroundColor: NSColor.white
        ]
        let sz = numStr.size(withAttributes: attrs)
        numStr.draw(
            at: CGPoint(x: first.x - sz.width / 2, y: first.y - sz.height / 2),
            withAttributes: attrs
        )

    case .text:
        guard !shape.text.isEmpty else { return }
        let fontSize = max(15, shape.lineWidth * 5.5)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: shape.color,
            .backgroundColor: NSColor.black.withAlphaComponent(0.55)
        ]
        (shape.text as NSString).draw(at: first, withAttributes: attrs)
    }
}

final class SnipOverlayWindow: NSWindow {
    var onEscapeOrRightClick: ((Bool) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscapeOrRightClick?(false)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscapeOrRightClick?(false)
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onEscapeOrRightClick?(true)
    }
}

// MARK: - Full-Screen Snipaste Overlay SwiftUI View
struct SnipOverlayView: View {
    @ObservedObject var controller: ScreenshotOverlayController
    @State private var dragStart: CGPoint = .zero
    @State private var hoveredToolbarHint: String? = nil

    let paletteColors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .white]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 1. Frozen full-screen image
                if let nsImg = controller.fullScreenNSImage {
                    Image(nsImage: nsImg)
                        .resizable()
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                // 2. Dimming mask outside the selected region
                if !controller.colorPickerOnlyMode {
                    SnipDimmingMask(selectionRect: controller.selectionRect, fullSize: geo.size)
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                }

                // 3. Drawn Annotations Canvas
                Canvas { context, _ in
                    let allShapes = controller.shapes + (controller.activeShape.map { [$0] } ?? [])
                    for shape in allShapes {
                        drawShapeInSwiftUICanvas(shape, in: &context)
                    }
                }
                .allowsHitTesting(false)

                // 4. Selection Border & Handles
                if controller.selectionRect.width > 2 && controller.selectionRect.height > 2 {
                    Rectangle()
                        .strokeBorder(Color.cyan, lineWidth: 2)
                        .frame(width: controller.selectionRect.width, height: controller.selectionRect.height)
                        .position(x: controller.selectionRect.midX, y: controller.selectionRect.midY)
                        .allowsHitTesting(false)

                    // Top-left size badge (Snipaste style)
                    Text("\(Int(controller.selectionRect.width)) × \(Int(controller.selectionRect.height))")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.82))
                        .cornerRadius(4)
                        .position(
                            x: max(55, controller.selectionRect.minX + 55),
                            y: max(18, controller.selectionRect.minY - 16)
                        )
                        .allowsHitTesting(false)
                }

                // 5. Interactive Gesture Layer for Region Selection & Drawing
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let pt) = phase {
                            controller.updateCursorInfo(at: pt)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                controller.updateCursorInfo(at: value.location)

                                if controller.colorPickerOnlyMode {
                                    return
                                }

                                // If a drawing tool is selected and we already have a selection
                                if let tool = controller.selectedTool, controller.hasCompletedSelection {
                                    handleAnnotationDragChanged(tool: tool, value: value)
                                    return
                                }

                                // Otherwise dragging selection box
                                if !controller.isDraggingSelection {
                                    controller.isDraggingSelection = true
                                    dragStart = value.startLocation
                                }
                                let minX = min(dragStart.x, value.location.x)
                                let minY = min(dragStart.y, value.location.y)
                                let w = abs(value.location.x - dragStart.x)
                                let h = abs(value.location.y - dragStart.y)
                                controller.selectionRect = CGRect(x: minX, y: minY, width: w, height: h)
                            }
                            .onEnded { value in
                                if controller.colorPickerOnlyMode {
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(controller.currentHexColor, forType: .string)
                                    controller.onColorPicked?(controller.currentHexColor, controller.currentRGBString, controller.currentPixelNSColor)
                                    controller.dismiss()
                                    return
                                }

                                if let tool = controller.selectedTool, controller.hasCompletedSelection {
                                    handleAnnotationDragEnded(tool: tool, value: value)
                                    return
                                }

                                controller.isDraggingSelection = false
                                if controller.selectionRect.width < 10 || controller.selectionRect.height < 10 {
                                    // Single click -> select full screen or keep ready
                                    return
                                }
                                controller.hasCompletedSelection = true
                                if controller.selectedTool == nil {
                                    controller.selectedTool = .rectangle
                                }
                            }
                    )

                // 6. Always-visible Top Escape Bar (Guarantees 1-click mouse exit anytime)
                HStack(spacing: 12) {
                    Text(controller.colorPickerOnlyMode ? "🎨 螢幕取色模式：點擊左鍵或按 C 複製色碼" : "✂️ 拖曳滑鼠左鍵框選截圖範圍")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)

                    if controller.hasCompletedSelection {
                        Button(action: {
                            controller.selectionRect = .zero
                            controller.hasCompletedSelection = false
                            controller.shapes.removeAll()
                            controller.textInputPosition = nil
                        }) {
                            Text("重新框選 (右鍵)")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.85))
                                .foregroundColor(.white)
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: {
                        controller.cancelAndDismiss()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                            Text("退出截圖 (ESC / 右鍵)")
                                .font(.system(size: 12, weight: .heavy))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.9))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.85))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25), lineWidth: 1))
                .position(x: geo.size.width / 2, y: 36)

                // 7. Floating Text Input Box (when using Text tool)
                if let textPos = controller.textInputPosition {
                    HStack(spacing: 6) {
                        TextField("輸入標註文字後按 Enter...", text: $controller.pendingTextInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit {
                                controller.commitTextAnnotation()
                            }
                        Button("確定") {
                            controller.commitTextAnnotation()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(6)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(6)
                    .position(x: min(geo.size.width - 140, max(140, textPos.x)), y: max(30, textPos.y))
                }

                // 8. Snipaste Magnifier + Color Picker Loupe (shown before completing selection or in ColorPicker mode)
                if !controller.hasCompletedSelection || controller.colorPickerOnlyMode {
                    MagnifierLoupeView(controller: controller)
                        .position(
                            x: min(geo.size.width - 110, controller.cursorPosition.x + 95),
                            y: min(geo.size.height - 110, controller.cursorPosition.y + 95)
                        )
                        .allowsHitTesting(false)
                }

                // 9. Snipaste / PicPick Floating Annotation & Action Toolbar
                if controller.hasCompletedSelection && !controller.colorPickerOnlyMode {
                    snipToolbar(in: geo.size)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func handleAnnotationDragChanged(tool: AnnotationTool, value: DragGesture.Value) {
        if tool == .counter || tool == .text { return }
        if controller.activeShape == nil {
            controller.activeShape = AnnotationShape(
                tool: tool,
                points: [value.startLocation, value.location],
                color: NSColor(controller.selectedColor),
                lineWidth: controller.strokeWidth
            )
        } else {
            if tool == .pen || tool == .highlighter || tool == .mosaic {
                controller.activeShape?.points.append(value.location)
            } else {
                controller.activeShape?.points = [value.startLocation, value.location]
            }
        }
    }

    private func handleAnnotationDragEnded(tool: AnnotationTool, value: DragGesture.Value) {
        if tool == .counter {
            let stepShape = AnnotationShape(
                tool: .counter,
                points: [value.location],
                color: NSColor(controller.selectedColor),
                lineWidth: controller.strokeWidth,
                stepNumber: controller.nextStepNumber
            )
            controller.shapes.append(stepShape)
            controller.nextStepNumber += 1
            return
        }
        if tool == .text {
            controller.commitTextAnnotation()
            controller.textInputPosition = value.location
            return
        }
        if let active = controller.activeShape {
            controller.shapes.append(active)
            controller.activeShape = nil
        }
    }

    @ViewBuilder
    private func snipToolbar(in screenSize: CGSize) -> some View {
        let toolbarWidth: CGFloat = 760
        let toolbarX = min(max(toolbarWidth / 2 + 12, controller.selectionRect.midX), screenSize.width - toolbarWidth / 2 - 12)
        let belowY = controller.selectionRect.maxY + 42
        let aboveY = controller.selectionRect.minY - 42
        let toolbarY = belowY < screenSize.height - 50 ? belowY : max(45, aboveY)

        VStack(spacing: 6) {
            // Row 1: Drawing Tools + Undo + Actions
            HStack(spacing: 6) {
                ForEach(AnnotationTool.allCases) { tool in
                    let isSelected = (controller.selectedTool == tool)
                    Button(action: { controller.selectedTool = tool }) {
                        VStack(spacing: 2) {
                            Image(systemName: tool.iconName)
                                .font(.system(size: 13, weight: .semibold))
                            Text(tool.rawValue)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .frame(width: 42, height: 34)
                        .background(isSelected ? Color.cyan.opacity(0.3) : Color.white.opacity(0.06))
                        .foregroundColor(isSelected ? .cyan : .white)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isSelected ? Color.cyan : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { h in
                        hoveredToolbarHint = h ? toolHintText(for: tool) : nil
                    }
                }

                Divider().frame(height: 26).background(Color.white.opacity(0.2))

                // Undo & Clear
                Button(action: { controller.undoAnnotation() }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 34)
                        .background(Color.white.opacity(0.08))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { h in
                    hoveredToolbarHint = h ? "↩️ 復原上一步標註 (快捷鍵 ⌘Z)" : nil
                }

                Button(action: { controller.clearAnnotations() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 34)
                        .background(Color.white.opacity(0.08))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { h in
                    hoveredToolbarHint = h ? "🗑 清除畫面上的所有標註與塗鴉" : nil
                }

                Divider().frame(height: 26).background(Color.white.opacity(0.2))

                // Snipaste Pin Button
                Button(action: { controller.completeCapture(action: .pin) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "pin.fill")
                        Text("釘選貼圖")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color.purple.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { h in
                    hoveredToolbarHint = h ? "📌 釘選貼圖 (Snipaste)：將截圖懸浮在螢幕最上層（滾輪縮放・Option+滾輪調透明度・雙擊關閉）" : nil
                }

                // Edit in PicPick Editor
                Button(action: { controller.completeCapture(action: .editInMain) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.below.rectangle")
                        Text("編輯器")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .background(Color.blue.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { h in
                    hoveredToolbarHint = h ? "✏️ 編輯器：將截圖送入 MingCam 主視窗預覽工作台，可隨時另存、複製或轉為貼圖" : nil
                }

                // Save PNG
                Button(action: { controller.completeCapture(action: .save) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("儲存")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color.green.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { h in
                    hoveredToolbarHint = h ? "💾 儲存：將高畫質 PNG 截圖（含標註）直接存入輸出資料夾" : nil
                }

                // Copy to Clipboard
                Button(action: { controller.completeCapture(action: .copy) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("複製")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color.cyan.opacity(0.85))
                    .foregroundColor(.black)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { h in
                    hoveredToolbarHint = h ? "📋 複製 (或按 Enter)：將截圖複製到系統剪貼簿，可直接 Cmd+V 貼到通訊軟體或文件中" : nil
                }

                // Cancel
                Button(action: {
                    controller.dismiss()
                    controller.onCancel?()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 34)
                        .background(Color.red.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { h in
                    hoveredToolbarHint = h ? "❌ 取消本次截圖 (或按 ESC 鍵)" : nil
                }
            }

            // Row 2: Color Swatches & Stroke Width + Instant Hover Tooltip
            HStack(spacing: 10) {
                Text("顏色：")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))

                ForEach(Array(paletteColors.enumerated()), id: \.offset) { _, c in
                    Circle()
                        .fill(c)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: controller.selectedColor == c ? 2.5 : 0.5)
                        )
                        .onTapGesture {
                            controller.selectedColor = c
                        }
                }

                Divider().frame(height: 16).background(Color.white.opacity(0.2))

                Text("粗細：")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))

                ForEach([2.0, 4.0, 7.0], id: \.self) { w in
                    Button(action: { controller.strokeWidth = CGFloat(w) }) {
                        Circle()
                            .fill(controller.strokeWidth == CGFloat(w) ? Color.cyan : Color.white.opacity(0.6))
                            .frame(width: CGFloat(w * 2 + 4), height: CGFloat(w * 2 + 4))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
                if let hint = hoveredToolbarHint {
                    Text(hint)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.yellow)
                        .lineLimit(1)
                } else {
                    Text("提示：滑鼠移到按鈕可看說明 ｜ 按 C 複製色碼 (\(controller.currentHexColor)) ｜ Enter 複製 ｜ ESC 取消")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.65))
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(8)
        .frame(width: toolbarWidth)
        .background(Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.95))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .position(x: toolbarX, y: toolbarY)
    }

    private func toolHintText(for tool: AnnotationTool) -> String {
        switch tool {
        case .rectangle: return "▭ 矩形工具：在截圖範圍內拖曳繪製矩形標示框"
        case .ellipse: return "◯ 橢圓工具：在截圖範圍內拖曳繪製圓形或橢圓標示框"
        case .arrow: return "↗ 箭頭工具：拖曳繪製指向重點的醒目箭頭"
        case .line: return "╱ 直線工具：拖曳繪製筆直標示線"
        case .pen: return "✏️ 畫筆工具：自由手繪塗鴉與圈選重點"
        case .highlighter: return "🖍 螢光筆工具：半透明加粗畫筆，適合標記文字重點"
        case .mosaic: return "▦ 馬賽克工具：塗抹遮蓋敏感個資、帳號或隱私內容"
        case .counter: return "① 步驟序號章：點擊畫面依序蓋上 ① ② ③ 步驟編號"
        case .text: return "T 文字工具：點擊畫面任意位置輸入說明文字"
        }
    }

    private func drawShapeInSwiftUICanvas(_ shape: AnnotationShape, in context: inout GraphicsContext) {
        guard let first = shape.points.first else { return }
        let last = shape.points.last ?? first
        let color = Color(nsColor: shape.color)

        switch shape.tool {
        case .rectangle:
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            context.stroke(Path(rect), with: .color(color), lineWidth: shape.lineWidth)

        case .ellipse:
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: shape.lineWidth)

        case .line:
            var p = Path()
            p.move(to: first)
            p.addLine(to: last)
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: shape.lineWidth, lineCap: .round))

        case .arrow:
            var p = Path()
            p.move(to: first)
            p.addLine(to: last)
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: shape.lineWidth, lineCap: .round))

            let angle = atan2(last.y - first.y, last.x - first.x)
            let arrowLen: CGFloat = max(12, shape.lineWidth * 4.2)
            let arrowAng: CGFloat = .pi / 6
            var head = Path()
            head.move(to: last)
            head.addLine(to: CGPoint(x: last.x - arrowLen * cos(angle - arrowAng), y: last.y - arrowLen * sin(angle - arrowAng)))
            head.addLine(to: CGPoint(x: last.x - arrowLen * cos(angle + arrowAng), y: last.y - arrowLen * sin(angle + arrowAng)))
            head.closeSubpath()
            context.fill(head, with: .color(color))

        case .pen:
            guard shape.points.count > 1 else { return }
            var p = Path()
            p.move(to: shape.points[0])
            for pt in shape.points.dropFirst() {
                p.addLine(to: pt)
            }
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: shape.lineWidth, lineCap: .round, lineJoin: .round))

        case .highlighter:
            guard shape.points.count > 1 else { return }
            var p = Path()
            p.move(to: shape.points[0])
            for pt in shape.points.dropFirst() {
                p.addLine(to: pt)
            }
            context.stroke(p, with: .color(color.opacity(0.38)), style: StrokeStyle(lineWidth: max(14, shape.lineWidth * 4.5), lineCap: .round, lineJoin: .round))

        case .mosaic:
            let blockSize: CGFloat = 12
            for pt in shape.points {
                let bx = floor(pt.x / blockSize) * blockSize
                let by = floor(pt.y / blockSize) * blockSize
                let isEven = (Int(bx / blockSize) + Int(by / blockSize)) % 2 == 0
                context.fill(
                    Path(CGRect(x: bx, y: by, width: blockSize, height: blockSize)),
                    with: .color(isEven ? Color.gray.opacity(0.85) : Color.black.opacity(0.75))
                )
            }

        case .counter:
            let r: CGFloat = 13
            let rect = CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2)
            context.draw(
                Text("\(shape.stepNumber)").font(.system(size: 13, weight: .heavy)).foregroundColor(.white),
                at: first
            )

        case .text:
            guard !shape.text.isEmpty else { return }
            let fontSize = max(15, shape.lineWidth * 5.5)
            context.draw(
                Text(shape.text).font(.system(size: fontSize, weight: .bold)).foregroundColor(color),
                at: first,
                anchor: .topLeading
            )
        }
    }
}

struct SnipDimmingMask: Shape {
    let selectionRect: CGRect
    let fullSize: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(origin: .zero, size: fullSize))
        if selectionRect.width > 1 && selectionRect.height > 1 {
            path.addRect(selectionRect)
        }
        return path
    }
}

struct MagnifierLoupeView: View {
    @ObservedObject var controller: ScreenshotOverlayController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: controller.currentPixelNSColor))
                    .frame(width: 24, height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white, lineWidth: 1))

                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.currentHexColor)
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .foregroundColor(.cyan)
                    Text("RGB(\(controller.currentRGBString))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            Divider().background(Color.white.opacity(0.2))

            Text("座標: (\(Int(controller.cursorPosition.x)), \(Int(controller.cursorPosition.y)))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))

            if controller.selectionRect.width > 0 {
                Text("選取: \(Int(controller.selectionRect.width)) × \(Int(controller.selectionRect.height))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
            }

            Text(controller.colorPickerOnlyMode ? "點擊左鍵或按 C 複製色碼" : "拖曳框選區域｜按 C 複製色碼")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.yellow)
        }
        .padding(10)
        .frame(width: 185)
        .background(Color.black.opacity(0.88))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cyan.opacity(0.6), lineWidth: 1.2))
    }
}
