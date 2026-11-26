import AppKit
import SwiftUI

@MainActor
final class PinItem: Identifiable, ObservableObject {
    let id = UUID()
    let image: NSImage
    let createdAt = Date()
    @Published var scale: CGFloat = 1.0
    @Published var opacity: Double = 1.0
    @Published var isShadowEnabled: Bool = true
    weak var panel: NSPanel?

    init(image: NSImage) {
        self.image = image
    }
}

@MainActor
final class PinManager: ObservableObject {
    static let shared = PinManager()

    @Published var activePins: [PinItem] = []
    @Published var allPinsHidden: Bool = false

    func pinImage(_ image: NSImage, at screenOrigin: CGPoint? = nil, onSave: ((NSImage) -> Void)? = nil) {
        let item = PinItem(image: image)
        let size = image.size
        let defaultOrigin: CGPoint
        if let screenOrigin {
            defaultOrigin = screenOrigin
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            defaultOrigin = CGPoint(
                x: (vf.midX - size.width / 2).rounded(),
                y: (vf.midY - size.height / 2).rounded()
            )
        } else {
            defaultOrigin = CGPoint(x: 200, y: 200)
        }

        let rect = CGRect(origin: defaultOrigin, size: CGSize(width: max(80, size.width), height: max(60, size.height)))
        let panel = SnipastePinPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        item.panel = panel

        let rootView = PinnedImageView(
            item: item,
            onCopy: { [weak self] in
                self?.copyToClipboard(image)
            },
            onSave: {
                onSave?(image)
            },
            onClose: { [weak self] in
                self?.closePin(item)
            }
        )

        panel.contentView = NSHostingView(rootView: rootView)
        panel.onScrollZoom = { [weak self, weak item] deltaY, isOptionPressed in
            guard let self, let item else { return }
            if isOptionPressed {
                let newOpacity = min(1.0, max(0.2, item.opacity + Double(deltaY) * 0.03))
                item.opacity = newOpacity
                panel.alphaValue = newOpacity
            } else {
                let factor: CGFloat = deltaY > 0 ? 1.06 : 0.94
                let newScale = min(4.0, max(0.25, item.scale * factor))
                self.applyScale(newScale, to: item)
            }
        }
        panel.orderFrontRegardless()
        activePins.insert(item, at: 0)
        allPinsHidden = false
    }

    func applyScale(_ newScale: CGFloat, to item: PinItem) {
        guard let panel = item.panel else { return }
        item.scale = newScale
        let oldFrame = panel.frame
        let newW = max(60, (item.image.size.width * newScale).rounded())
        let newH = max(45, (item.image.size.height * newScale).rounded())
        let newX = (oldFrame.midX - newW / 2).rounded()
        let newY = (oldFrame.midY - newH / 2).rounded()
        panel.setFrame(CGRect(x: newX, y: newY, width: newW, height: newH), display: true)
    }

    func applyOpacity(_ newOpacity: Double, to item: PinItem) {
        item.opacity = newOpacity
        item.panel?.alphaValue = newOpacity
    }

    func closePin(_ item: PinItem) {
        item.panel?.orderOut(nil)
        activePins.removeAll { $0.id == item.id }
    }

    func closeAllPins() {
        for item in activePins {
            item.panel?.orderOut(nil)
        }
        activePins.removeAll()
    }

    func toggleHideAllPins() {
        allPinsHidden.toggle()
        for item in activePins {
            if allPinsHidden {
                item.panel?.orderOut(nil)
            } else {
                item.panel?.orderFrontRegardless()
            }
        }
    }

    @discardableResult
    func pinFromClipboard(onSave: ((NSImage) -> Void)? = nil) -> Bool {
        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb) {
            pinImage(image, onSave: onSave)
            return true
        }
        // Also support pinning text from clipboard as a styled card (like Snipaste!)
        if let str = pb.string(forType: .string), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let textImg = renderTextCardImage(str) {
                pinImage(textImg, onSave: onSave)
                return true
            }
        }
        return false
    }

    func copyToClipboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func renderTextCardImage(_ text: String) -> NSImage? {
        let trimmed = String(text.prefix(800))
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let maxRect = CGSize(width: 480, height: 600)
        let bound = (trimmed as NSString).boundingRect(with: maxRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        let cardSize = CGSize(width: max(220, ceil(bound.width) + 32), height: max(70, ceil(bound.height) + 32))

        let img = NSImage(size: cardSize)
        img.lockFocus()
        NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 0.96).setFill()
        let path = NSBezierPath(roundedRect: CGRect(origin: .zero, size: cardSize), xRadius: 8, yRadius: 8)
        path.fill()
        (trimmed as NSString).draw(in: CGRect(x: 16, y: 16, width: cardSize.width - 32, height: cardSize.height - 32), withAttributes: attrs)
        img.unlockFocus()
        return img
    }
}

final class SnipastePinPanel: NSPanel {
    var onScrollZoom: ((CGFloat, Bool) -> Void)?

    override var canBecomeKey: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard abs(dy) > 0.1 else { return }
        let isOption = event.modifierFlags.contains(.option)
        onScrollZoom?(dy, isOption)
    }
}

struct PinnedImageView: View {
    @ObservedObject var item: PinItem
    @State private var isHovering = false
    @State private var copiedFeedback = false

    let onCopy: () -> Void
    let onSave: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: item.image)
                .resizable()
                .interpolation(.high)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isHovering ? Color.cyan : Color.white.opacity(0.35), lineWidth: isHovering ? 2 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))

            if isHovering {
                HStack(spacing: 6) {
                    Text("\(Int(item.scale * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)

                    if item.opacity < 0.99 {
                        Text("透明度\(Int(item.opacity * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.yellow)
                    }

                    Button(action: {
                        onCopy()
                        copiedFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            copiedFeedback = false
                        }
                    }) {
                        Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(copiedFeedback ? .green : .white)
                    }
                    .buttonStyle(.plain)
                    .help("複製圖片")

                    Button(action: onSave) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help("儲存到輸出資料夾")

                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("關閉貼圖 (或雙擊關閉)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.82))
                .cornerRadius(6)
                .padding(6)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(count: 2) {
            onClose()
        }
        .contextMenu {
            Button("📋 複製圖片到剪貼簿") { onCopy() }
            Button("💾 儲存圖片 (.png)") { onSave() }
            Divider()
            Menu("🔍 縮放比例 (\(Int(item.scale * 100))%)") {
                Button("50%") { PinManager.shared.applyScale(0.5, to: item) }
                Button("100% (原始大小)") { PinManager.shared.applyScale(1.0, to: item) }
                Button("150%") { PinManager.shared.applyScale(1.5, to: item) }
                Button("200%") { PinManager.shared.applyScale(2.0, to: item) }
            }
            Menu("👁 透明度 (\(Int(item.opacity * 100))%)") {
                Button("100% (不透明)") { PinManager.shared.applyOpacity(1.0, to: item) }
                Button("80%") { PinManager.shared.applyOpacity(0.8, to: item) }
                Button("50% (半透明對照)") { PinManager.shared.applyOpacity(0.5, to: item) }
                Button("30%") { PinManager.shared.applyOpacity(0.3, to: item) }
            }
            Divider()
            Button("❌ 關閉此貼圖") { onClose() }
        }
    }
}
