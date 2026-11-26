import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Combine

@MainActor
final class ScreenRecorderEngine: NSObject, ObservableObject {
    // MARK: - Published UI State
    @Published var activeWorkspaceTab: AppWorkspaceTab = .recorder {
        didSet {
            syncOverlayVisibility()
        }
    }
    @Published var mode: CaptureMode = .fullScreen {
        didSet {
            syncOverlayVisibility()
        }
    }
    @Published var screenshotMode: ScreenshotCaptureMode = .region
    @Published var screenshotDelaySeconds: Int = 0
    @Published var autoCopyScreenshot: Bool = true
    @Published var autoSaveScreenshot: Bool = true
    @Published var autoPinAfterCapture: Bool = false
    @Published var lastCapturedImage: NSImage? = nil
    @Published var pickedColorsHistory: [(hex: String, rgb: String, color: NSColor)] = []
    @Published var fileFilter: FileCategoryFilter = .all

    @Published var status: RecordingStatus = .idle {
        didSet {
            overlayController.isRecording = (status == .recording || status == .paused)
            overlayController.isPaused = (status == .paused)
        }
    }
    @Published var availableDisplays: [SCDisplay] = []
    @Published var availableWindows: [SCWindow] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?

    // Settings
    @Published var fps: Int = 60
    @Published var showsCursor: Bool = true
    @Published var captureSystemAudio: Bool = true
    @Published var captureMicrophone: Bool = false
    @Published var excludeAppWindowInRecording: Bool = true
    @Published var outputFolderURL: URL

    // Live Metrics & Hover Help
    @Published var elapsedSeconds: Int = 0
    @Published var audioLevel: Float = 0.0
    @Published var statusMessage: String = "準備就緒（錄影・錄音・Snipaste 截圖與貼圖）"
    @Published var errorMessage: String?
    @Published var recordedFiles: [RecordedFileItem] = []
    @Published var hoveredFeatureTitle: String? = nil
    @Published var hoveredFeatureDetail: String? = nil

    let overlayController = RegionOverlayController()
    let screenshotOverlay = ScreenshotOverlayController()
    let pinManager = PinManager.shared
    let hotkeyManager = GlobalHotkeyManager.shared

    // Internal Capture State
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var timer: Timer?
    private let writerQueue = DispatchQueue(label: "com.ming.mingcam.writer", qos: .userInitiated)

    override init() {
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/錄製螢幕")
        if FileManager.default.fileExists(atPath: defaultDir.path) {
            self.outputFolderURL = defaultDir
        } else {
            self.outputFolderURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        super.init()
        refreshFileList()
        setupGlobalHotkeyCallbacks()
        Task {
            await refreshShareableContent()
            syncOverlayVisibility()
        }
    }

    func setHoverHelp(_ title: String?, _ detail: String?) {
        hoveredFeatureTitle = title
        hoveredFeatureDetail = detail
    }

    private func setupGlobalHotkeyCallbacks() {
        hotkeyManager.onSnipTriggered = { [weak self] in
            self?.triggerScreenshot(modeOverride: .region)
        }
        hotkeyManager.onPinTriggered = { [weak self] in
            self?.pinFromClipboard()
        }
        hotkeyManager.onColorTriggered = { [weak self] in
            self?.triggerScreenshot(modeOverride: .colorPicker)
        }
        hotkeyManager.onRecordTriggered = { [weak self] in
            self?.toggleRecording()
        }
    }

    func syncOverlayVisibility() {
        if activeWorkspaceTab == .recorder && mode == .region {
            overlayController.show()
        } else {
            overlayController.hide()
        }
    }

    var filteredFiles: [RecordedFileItem] {
        switch fileFilter {
        case .all:
            return recordedFiles
        case .videoAudio:
            return recordedFiles.filter { !$0.isScreenshot }
        case .screenshots:
            return recordedFiles.filter { $0.isScreenshot }
        }
    }

    var formattedElapsedTime: String {
        let hrs = elapsedSeconds / 3600
        let mins = (elapsedSeconds % 3600) / 60
        let secs = elapsedSeconds % 60
        return String(format: "%02d:%02d:%02d", hrs, mins, secs)
    }

    // MARK: - Content Discovery
    func refreshShareableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.availableDisplays = content.displays
            if self.selectedDisplayID == nil, let first = content.displays.first {
                self.selectedDisplayID = first.displayID
            }

            let myPID = ProcessInfo.processInfo.processIdentifier
            let filteredWindows = content.windows.filter { win in
                guard let title = win.title, !title.isEmpty else { return false }
                guard win.frame.width > 100 && win.frame.height > 80 else { return false }
                if win.owningApplication?.processID == myPID { return false }
                return true
            }
            self.availableWindows = filteredWindows
            if self.selectedWindowID == nil || !filteredWindows.contains(where: { $0.windowID == self.selectedWindowID }) {
                self.selectedWindowID = filteredWindows.first?.windowID
            }
            self.errorMessage = nil
        } catch {
            self.errorMessage = "需要「螢幕與系統音訊錄製」權限：請於「系統設定 > 隱私權與安全性 > 螢幕與系統音訊錄製」中允許 MingCam。"
        }
    }

    // MARK: - File Management
    func refreshFileList() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: outputFolderURL,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let allowedExts = Set(["mp4", "mov", "m4a", "png", "jpg", "jpeg"])
        var items: [RecordedFileItem] = []

        for url in urls where allowedExts.contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            let created = values?.creationDate ?? Date.distantPast
            let size = Int64(values?.fileSize ?? 0)
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            items.append(RecordedFileItem(url: url, name: url.lastPathComponent, fileSizeString: sizeStr, createdAt: created))
        }

        items.sort { $0.createdAt > $1.createdAt }
        self.recordedFiles = items
    }

    // MARK: - Screenshot, Snipaste Pin & PicPick Features
    func triggerScreenshot(modeOverride: ScreenshotCaptureMode? = nil) {
        if screenshotOverlay.isPresented {
            screenshotOverlay.cancelAndDismiss()
            return
        }
        let targetMode = modeOverride ?? screenshotMode
        Task {
            if screenshotDelaySeconds > 0 {
                for remaining in (1...screenshotDelaySeconds).reversed() {
                    statusMessage = "⏱ 倒數 \(remaining) 秒後進行截圖..."
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            await executeScreenshot(mode: targetMode)
        }
    }

    private func executeScreenshot(mode targetMode: ScreenshotCaptureMode) async {
        errorMessage = nil
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let myPID = ProcessInfo.processInfo.processIdentifier
            let myWindows = content.windows.filter { $0.owningApplication?.processID == myPID }

            switch targetMode {
            case .window:
                guard let win = content.windows.first(where: { $0.windowID == selectedWindowID }) ?? content.windows.first(where: { $0.owningApplication?.processID != myPID }) else {
                    errorMessage = "找不到可截圖的目標視窗，請先選擇視窗。"
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: win)
                let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                let config = SCStreamConfiguration()
                config.width = max(100, Int(win.frame.width * scale))
                config.height = max(80, Int(win.frame.height * scale))
                config.showsCursor = false

                let cgImg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let nsImg = NSImage(cgImage: cgImg, size: win.frame.size)
                handleCompletedScreenshot(nsImg, defaultAction: autoPinAfterCapture ? .pin : (autoSaveScreenshot ? .save : .copy), pinOrigin: nil)

            case .fullScreen:
                guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID }) ?? content.displays.first else {
                    errorMessage = "找不到顯示器。"
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: excludeAppWindowInRecording ? myWindows : [])
                let scale = screenScaleFactor(for: display.displayID)
                let config = SCStreamConfiguration()
                config.width = Int(CGFloat(display.width) * scale)
                config.height = Int(CGFloat(display.height) * scale)
                config.showsCursor = showsCursor

                let cgImg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let nsImg = NSImage(cgImage: cgImg, size: CGSize(width: display.width, height: display.height))
                handleCompletedScreenshot(nsImg, defaultAction: autoPinAfterCapture ? .pin : (autoSaveScreenshot ? .save : .copy), pinOrigin: nil)

            case .region, .colorPicker:
                guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID }) ?? content.displays.first else {
                    errorMessage = "找不到顯示器。"
                    return
                }
                let nsScreen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
                }) ?? NSScreen.main ?? NSScreen.screens.first!

                let filter = SCContentFilter(display: display, excludingWindows: excludeAppWindowInRecording ? myWindows : [])
                let scale = nsScreen.backingScaleFactor
                let config = SCStreamConfiguration()
                config.width = Int(nsScreen.frame.width * scale)
                config.height = Int(nsScreen.frame.height * scale)
                config.showsCursor = false

                let cgImg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

                screenshotOverlay.present(
                    cgImage: cgImg,
                    screen: nsScreen,
                    colorPickerOnly: (targetMode == .colorPicker),
                    onFinishWithImage: { [weak self] finalImg, action, appKitRect in
                        guard let self else { return }
                        self.handleCompletedScreenshot(finalImg, defaultAction: action, pinOrigin: appKitRect.origin)
                    },
                    onColorPicked: { [weak self] hex, rgb, nsColor in
                        guard let self else { return }
                        self.pickedColorsHistory.removeAll { $0.hex == hex }
                        self.pickedColorsHistory.insert((hex: hex, rgb: rgb, color: nsColor), at: 0)
                        if self.pickedColorsHistory.count > 12 {
                            self.pickedColorsHistory.removeLast()
                        }
                        self.statusMessage = "🎨 已複製色碼：\(hex)  |  RGB(\(rgb))"
                    },
                    onCancel: { [weak self] in
                        self?.statusMessage = "已取消截圖"
                    }
                )
            }
        } catch {
            errorMessage = "截圖失敗：\(error.localizedDescription)\n請確認「螢幕與系統音訊錄製」權限已開啟。"
        }
    }

    private func handleCompletedScreenshot(
        _ image: NSImage,
        defaultAction: ScreenshotOverlayController.SnipFinishAction,
        pinOrigin: CGPoint?
    ) {
        self.lastCapturedImage = image

        switch defaultAction {
        case .copy:
            copyImageToClipboard(image)
            if autoSaveScreenshot {
                if let savedURL = saveScreenshotToDisk(image) {
                    statusMessage = "📸 已複製到剪貼簿並儲存：\(savedURL.lastPathComponent)"
                } else {
                    statusMessage = "📸 已複製截圖到剪貼簿"
                }
            } else {
                statusMessage = "📸 已複製截圖到剪貼簿"
            }

        case .save:
            if autoCopyScreenshot {
                copyImageToClipboard(image)
            }
            if let savedURL = saveScreenshotToDisk(image) {
                statusMessage = "💾 已儲存截圖：\(savedURL.lastPathComponent)"
            }

        case .pin:
            if autoCopyScreenshot {
                copyImageToClipboard(image)
            }
            pinImageToScreen(image, origin: pinOrigin)
            statusMessage = "📌 已將截圖釘選懸浮於螢幕（滾輪縮放・Option+滾輪調透明度・雙擊關閉）"

        case .editInMain:
            if autoCopyScreenshot {
                copyImageToClipboard(image)
            }
            activeWorkspaceTab = .screenshot
            NSApp.activate(ignoringOtherApps: true)
            statusMessage = "✏️ 已載入至內建預覽工作台"
        }
    }

    func copyImageToClipboard(_ image: NSImage) {
        pinManager.copyToClipboard(image)
    }

    func pinImageToScreen(_ image: NSImage, origin: CGPoint? = nil) {
        pinManager.pinImage(image, at: origin) { [weak self] imgToSave in
            if let url = self?.saveScreenshotToDisk(imgToSave) {
                self?.statusMessage = "💾 已儲存貼圖：\(url.lastPathComponent)"
            }
        }
    }

    func pinFromClipboard() {
        let ok = pinManager.pinFromClipboard { [weak self] imgToSave in
            if let url = self?.saveScreenshotToDisk(imgToSave) {
                self?.statusMessage = "💾 已儲存貼圖：\(url.lastPathComponent)"
            }
        }
        if ok {
            statusMessage = "📌 已從剪貼簿建立螢幕懸浮貼圖（滾輪可縮放・雙擊關閉）"
        } else {
            statusMessage = "⚠️ 剪貼簿中目前沒有圖片或文字可供貼圖"
        }
    }

    @discardableResult
    func saveScreenshotToDisk(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let url = outputFolderURL.appendingPathComponent("MingSnap_\(df.string(from: Date())).png")
        do {
            try pngData.write(to: url)
            refreshFileList()
            return url
        } catch {
            return nil
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "選擇儲存資料夾"
        panel.directoryURL = outputFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderURL = url
            refreshFileList()
        }
    }

    func openOutputFolder() {
        NSWorkspace.shared.open(outputFolderURL)
    }

    func openFile(_ item: RecordedFileItem) {
        NSWorkspace.shared.open(item.url)
    }

    func revealFile(_ item: RecordedFileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Recording Lifecycle
    func toggleRecording() {
        switch status {
        case .idle:
            Task { await startRecording() }
        case .recording, .paused:
            Task { await stopRecording() }
        case .stopping:
            break
        }
    }

    func togglePause() {
        guard let output = streamOutput else { return }
        if status == .recording {
            output.setPaused(true)
            status = .paused
            statusMessage = "已暫停錄製（可隨時繼續）"
        } else if status == .paused {
            output.setPaused(false)
            status = .recording
            statusMessage = "正在錄製中..."
        }
    }

    func startRecording() async {
        errorMessage = nil

        if mode == .audioOnly && !captureSystemAudio && !captureMicrophone {
            errorMessage = "純音訊模式下，請至少勾選「系統內部聲音」或「麥克風」。"
            return
        }

        if captureMicrophone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                errorMessage = "未取得麥克風權限，請在「系統設定 > 隱私權與安全性 > 麥克風」中開啟，或取消勾選麥克風。"
                return
            }
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.availableDisplays = content.displays

            let filter: SCContentFilter
            let streamConfig = SCStreamConfiguration()
            var outputWidth: Int = 1920
            var outputHeight: Int = 1080

            // Exclude our own overlay window (and optionally control panel) from the video stream
            let myPID = ProcessInfo.processInfo.processIdentifier
            let overlayWinNum = overlayController.overlayWindowNumber
            let excludedWindows = content.windows.filter { win in
                if let overlayWinNum, Int(win.windowID) == overlayWinNum {
                    return true
                }
                if excludeAppWindowInRecording && win.owningApplication?.processID == myPID {
                    return true
                }
                return false
            }

            switch mode {
            case .fullScreen, .audioOnly:
                guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID }) ?? content.displays.first else {
                    errorMessage = "找不到可錄製的螢幕顯示器。"
                    return
                }
                filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
                let scale = screenScaleFactor(for: display.displayID)
                if mode == .audioOnly {
                    outputWidth = 128
                    outputHeight = 72
                } else {
                    outputWidth = makeEven(Int(CGFloat(display.width) * scale))
                    outputHeight = makeEven(Int(CGFloat(display.height) * scale))
                }

            case .region:
                guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID }) ?? content.displays.first else {
                    errorMessage = "找不到可錄製的螢幕顯示器。"
                    return
                }
                filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
                let nsScreen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
                }) ?? NSScreen.main ?? NSScreen.screens.first!

                let srcRect = overlayController.sourceRect(for: nsScreen)
                streamConfig.sourceRect = srcRect
                let scale = nsScreen.backingScaleFactor
                outputWidth = makeEven(Int(srcRect.width * scale))
                outputHeight = makeEven(Int(srcRect.height * scale))

            case .window:
                guard let win = content.windows.first(where: { $0.windowID == selectedWindowID }) else {
                    errorMessage = "找不到指定的應用程式視窗，請重新整理視窗列表。"
                    return
                }
                filter = SCContentFilter(desktopIndependentWindow: win)
                let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
                outputWidth = makeEven(max(200, Int(win.frame.width * scale)))
                outputHeight = makeEven(max(150, Int(win.frame.height * scale)))
            }

            streamConfig.width = outputWidth
            streamConfig.height = outputHeight
            streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(mode == .audioOnly ? 10 : fps))
            streamConfig.showsCursor = showsCursor
            streamConfig.queueDepth = 6
            streamConfig.pixelFormat = kCVPixelFormatType_32BGRA

            streamConfig.capturesAudio = captureSystemAudio
            streamConfig.excludesCurrentProcessAudio = true
            streamConfig.sampleRate = 48000
            streamConfig.channelCount = 2

            if #available(macOS 15.0, *) {
                streamConfig.captureMicrophone = captureMicrophone
            }

            let outputURL = makeOutputFileURL(isAudioOnly: mode == .audioOnly)
            let isAudioOnly = (mode == .audioOnly)

            let outputHandler = try CaptureStreamOutput(
                outputURL: outputURL,
                isAudioOnly: isAudioOnly,
                width: outputWidth,
                height: outputHeight,
                fps: fps,
                capturesSystemAudio: captureSystemAudio,
                capturesMic: captureMicrophone,
                writerQueue: writerQueue,
                onAudioLevel: { [weak self] level in
                    Task { @MainActor [weak self] in
                        self?.audioLevel = level
                    }
                },
                onStreamError: { [weak self] err in
                    Task { @MainActor [weak self] in
                        self?.errorMessage = "錄製發生中斷：\(err.localizedDescription)"
                        await self?.stopRecording()
                    }
                }
            )

            let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: outputHandler)
            if !isAudioOnly {
                try newStream.addStreamOutput(outputHandler, type: .screen, sampleHandlerQueue: writerQueue)
            }
            if captureSystemAudio {
                try newStream.addStreamOutput(outputHandler, type: .audio, sampleHandlerQueue: writerQueue)
            }
            if #available(macOS 15.0, *), captureMicrophone {
                try newStream.addStreamOutput(outputHandler, type: .microphone, sampleHandlerQueue: writerQueue)
            }

            try await newStream.startCapture()

            self.streamOutput = outputHandler
            self.stream = newStream
            self.elapsedSeconds = 0
            self.status = .recording
            self.statusMessage = "正在錄製：\(outputURL.lastPathComponent)"
            startTimer()

        } catch {
            self.errorMessage = "無法啟動錄製：\(error.localizedDescription)\n請確認已在「系統設定 > 隱私權與安全性 > 螢幕與系統音訊錄製」中授權。"
            self.status = .idle
        }
    }

    func stopRecording() async {
        guard status == .recording || status == .paused else { return }
        status = .stopping
        statusMessage = "正在寫入並儲存檔案..."
        stopTimer()
        audioLevel = 0.0

        if let activeStream = stream {
            try? await activeStream.stopCapture()
        }
        stream = nil

        if let output = streamOutput {
            await output.finishWriting()
            let savedName = output.outputURL.lastPathComponent
            statusMessage = "已儲存：\(savedName)"
        }
        streamOutput = nil
        status = .idle
        refreshFileList()
    }

    // MARK: - Helpers
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.status == .recording else { return }
                self.elapsedSeconds += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func makeOutputFileURL(isAudioOnly: Bool) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let ts = df.string(from: Date())
        let ext = isAudioOnly ? "m4a" : "mp4"
        let prefix = isAudioOnly ? "MingAudio" : "MingCam"
        return outputFolderURL.appendingPathComponent("\(prefix)_\(ts).\(ext)")
    }

    private func screenScaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            return screen.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func makeEven(_ value: Int) -> Int {
        value % 2 == 0 ? value : value + 1
    }
}

// MARK: - SCStreamOutput & AVAssetWriter Handler
final class CaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let outputURL: URL
    private let isAudioOnly: Bool
    private let assetWriter: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?

    private let writerQueue: DispatchQueue
    private let onAudioLevel: (Float) -> Void
    private let onStreamError: (Error) -> Void

    private var sessionStarted = false
    private var isPaused = false
    private var pauseStartPTS: CMTime = .invalid
    private var totalPauseOffset: CMTime = .zero
    private var lastHandledPTS: CMTime = .invalid

    init(
        outputURL: URL,
        isAudioOnly: Bool,
        width: Int,
        height: Int,
        fps: Int,
        capturesSystemAudio: Bool,
        capturesMic: Bool,
        writerQueue: DispatchQueue,
        onAudioLevel: @escaping (Float) -> Void,
        onStreamError: @escaping (Error) -> Void
    ) throws {
        self.outputURL = outputURL
        self.isAudioOnly = isAudioOnly
        self.writerQueue = writerQueue
        self.onAudioLevel = onAudioLevel
        self.onStreamError = onStreamError

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let fileType: AVFileType = isAudioOnly ? .m4a : .mp4
        self.assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: fileType)

        if !isAudioOnly {
            let pixelCount = width * height
            let bitsPerPixel: Double = fps >= 60 ? 0.16 : 0.12
            let bitrate = max(4_000_000, Int(Double(pixelCount * fps) * bitsPerPixel))

            let compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoExpectedSourceFrameRateKey: fps
            ]

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compressionProps
            ]

            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(vInput) {
                assetWriter.add(vInput)
                self.videoInput = vInput
            }
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]

        if capturesSystemAudio {
            let sAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            sAudio.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(sAudio) {
                assetWriter.add(sAudio)
                self.systemAudioInput = sAudio
            }
        }

        if capturesMic && (!isAudioOnly || !capturesSystemAudio) {
            let mAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            mAudio.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(mAudio) {
                assetWriter.add(mAudio)
                self.micAudioInput = mAudio
            }
        }

        super.init()
        assetWriter.startWriting()
    }

    func setPaused(_ paused: Bool) {
        writerQueue.async {
            if paused && !self.isPaused {
                self.isPaused = true
                self.pauseStartPTS = self.lastHandledPTS
            } else if !paused && self.isPaused {
                self.isPaused = false
                if self.pauseStartPTS.isValid && self.lastHandledPTS.isValid {
                    let delta = CMTimeSubtract(self.lastHandledPTS, self.pauseStartPTS)
                    if delta.seconds > 0 {
                        self.totalPauseOffset = CMTimeAdd(self.totalPauseOffset, delta)
                    }
                }
                self.pauseStartPTS = .invalid
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid {
            lastHandledPTS = pts
        }

        if outputType == .audio || ( { if #available(macOS 15.0, *) { return outputType == .microphone } else { return false } }() ) {
            let level = computeAudioLevel(from: sampleBuffer)
            onAudioLevel(level)
        }

        guard !isPaused else { return }
        guard assetWriter.status == .writing else { return }

        if outputType == .screen {
            guard isValidVideoFrame(sampleBuffer) else { return }
        }

        let adjustedBuffer: CMSampleBuffer
        if totalPauseOffset.seconds > 0, let shifted = adjustTimeStamp(sampleBuffer: sampleBuffer, by: totalPauseOffset) {
            adjustedBuffer = shifted
        } else {
            adjustedBuffer = sampleBuffer
        }

        let adjustedPTS = CMSampleBufferGetPresentationTimeStamp(adjustedBuffer)
        if !sessionStarted {
            if !isAudioOnly && outputType != .screen {
                // Start session on the first valid video frame for clean sync
                return
            }
            assetWriter.startSession(atSourceTime: adjustedPTS)
            sessionStarted = true
        }

        switch outputType {
        case .screen:
            if let vInput = videoInput, vInput.isReadyForMoreMediaData {
                vInput.append(adjustedBuffer)
            }
        case .audio:
            if let sInput = systemAudioInput, sInput.isReadyForMoreMediaData {
                sInput.append(adjustedBuffer)
            }
        case .microphone:
            if let mInput = micAudioInput, mInput.isReadyForMoreMediaData {
                mInput.append(adjustedBuffer)
            } else if systemAudioInput == nil, let sInput = systemAudioInput, sInput.isReadyForMoreMediaData {
                sInput.append(adjustedBuffer)
            }
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError(error)
    }

    func finishWriting() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async {
                guard self.assetWriter.status == .writing && self.sessionStarted else {
                    self.assetWriter.cancelWriting()
                    continuation.resume()
                    return
                }
                self.videoInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.micAudioInput?.markAsFinished()
                self.assetWriter.finishWriting {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Sample Buffer Utilities
    private func isValidVideoFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let frameStatus = SCFrameStatus(rawValue: statusRawValue) else {
            return false
        }
        return frameStatus == .complete && CMSampleBufferGetImageBuffer(sampleBuffer) != nil
    }

    private func adjustTimeStamp(sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }

        var timingArray = Array(repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timingArray, entriesNeededOut: &count)

        for i in 0..<count {
            timingArray[i].presentationTimeStamp = CMTimeSubtract(timingArray[i].presentationTimeStamp, offset)
            if timingArray[i].decodeTimeStamp.isValid {
                timingArray[i].decodeTimeStamp = CMTimeSubtract(timingArray[i].decodeTimeStamp, offset)
            }
        }

        var outBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timingArray,
            sampleBufferOut: &outBuffer
        )
        return status == noErr ? outBuffer : nil
    }

    private func computeAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0.0 }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer, length > 0 else { return 0.0 }

        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { return 0.0 }

        return ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
            var sum: Float = 0.0
            let step = max(1, floatCount / 256)
            var samples = 0
            var idx = 0
            while idx < floatCount {
                let s = floatPtr[idx]
                sum += s * s
                samples += 1
                idx += step
            }
            let rms = sqrt(sum / Float(max(1, samples)))
            let clamped = min(1.0, max(0.0, rms * 3.5))
            return clamped
        }
    }
}
