import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @ObservedObject var engine: ScreenRecorderEngine
    @ObservedObject var overlayController: RegionOverlayController
    @ObservedObject var pinManager: PinManager
    @ObservedObject var hotkeyManager: GlobalHotkeyManager

    init(engine: ScreenRecorderEngine) {
        self.engine = engine
        self.overlayController = engine.overlayController
        self.pinManager = engine.pinManager
        self.hotkeyManager = engine.hotkeyManager
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Header Bar (with Workspace Switcher + Global Quick Actions)
            topHeaderBar
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color(red: 0.11, green: 0.12, blue: 0.15))

            Divider()
                .background(Color.white.opacity(0.1))

            // MARK: - Sub-Mode Strip (Switches based on activeWorkspaceTab)
            if engine.activeWorkspaceTab == .recorder {
                recorderModeSelectorBar
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.14, green: 0.15, blue: 0.18))
            } else {
                screenshotModeSelectorBar
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.13, green: 0.15, blue: 0.19))
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // MARK: - Instant Hover Feature Explanation Banner (滑鼠停留即時顯示功能說明)
            hoverFeatureBanner

            // MARK: - Error Banner (if any)
            if let err = engine.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(err)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                    Spacer()
                    Button("重新檢查權限") {
                        Task { await engine.refreshShareableContent() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.35))
            }

            // MARK: - Main Workspace Content
            HStack(alignment: .top, spacing: 16) {
                // Left Column: Dynamic controls for Recorder OR Screenshot/Snipaste/PicPick + Global Hotkeys
                ScrollView(.vertical, showsIndicators: false) {
                    if engine.activeWorkspaceTab == .recorder {
                        VStack(spacing: 14) {
                            captureTargetCard
                            recordingSettingsCard
                            globalHotkeySettingsCard
                        }
                    } else {
                        VStack(spacing: 14) {
                            screenshotControlCard
                            globalHotkeySettingsCard
                            snipastePinManagerCard
                            picPickColorHistoryCard
                        }
                    }
                }
                .frame(width: 400)

                // Right Column: Latest Screenshot Preview (if in screenshot tab) + Output Files
                VStack(spacing: 14) {
                    if engine.activeWorkspaceTab == .screenshot, let previewImg = engine.lastCapturedImage {
                        latestScreenshotPreviewCard(previewImg)
                    }
                    outputFilesCard
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(18)
            .background(Color(red: 0.09, green: 0.10, blue: 0.12))

            // MARK: - Footer Status Bar
            footerBar
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        }
        .frame(minWidth: 920, minHeight: 620)
        .preferredColorScheme(.dark)
    }

    // MARK: - Instant Hover Feature Explanation Banner
    private var hoverFeatureBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: engine.hoveredFeatureTitle != nil ? "sparkles" : "info.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(engine.hoveredFeatureTitle != nil ? .yellow : .cyan.opacity(0.8))

            if let title = engine.hoveredFeatureTitle, let detail = engine.hoveredFeatureDetail {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(.yellow)
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                }
            } else {
                Text("💡 滑鼠停留在任何按鈕上可即時查看功能說明 ｜ 框選截圖 (\(hotkeyManager.snipHotkey.label)\(hotkeyManager.alsoEnableF1F3 ? " / F1" : ""))：下方自動浮出工具列，支援直接選擇「📌 釘選貼圖」、「📋 複製」、「💾 儲存」或「✏️ 編輯器」。")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(
            engine.hoveredFeatureTitle != nil
                ? Color(red: 0.18, green: 0.20, blue: 0.28)
                : Color(red: 0.11, green: 0.13, blue: 0.17)
        )
    }

    // MARK: - Top Header Bar
    private var topHeaderBar: some View {
        HStack(spacing: 14) {
            // Brand Logo & Title
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: engine.activeWorkspaceTab == .recorder
                                    ? [Color.red, Color.orange]
                                    : [Color.cyan, Color.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: engine.activeWorkspaceTab == .recorder ? "record.circle" : "viewfinder")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("MingCam")
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                        Text("All-in-One")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.25))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                    Text("Bandicam 錄影 ＋ Snipaste 貼圖 ＋ PicPick 標註")
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.55))
                }
            }

            // PicPick-Style Mode Switcher (錄影與錄音 vs 截圖與貼圖)
            HStack(spacing: 4) {
                ForEach(AppWorkspaceTab.allCases) { tab in
                    let isSelected = (engine.activeWorkspaceTab == tab)
                    Button(action: {
                        engine.activeWorkspaceTab = tab
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 12, weight: .bold))
                            Text(tab.rawValue)
                                .font(.system(size: 12.5, weight: .bold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isSelected ? (tab == .recorder ? Color.red.opacity(0.85) : Color.cyan.opacity(0.85)) : Color.clear)
                        )
                        .foregroundColor(isSelected ? (tab == .recorder ? .white : .black) : .white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .onHover { h in
                        if h {
                            if tab == .recorder {
                                engine.setHoverHelp("🎬 錄影與錄音工作區：", "提供全螢幕、矩形綠框、指定視窗高畫質 MP4 錄影，以及系統內部聲音 M4A 內錄（完全無時間限制）。")
                            } else {
                                engine.setHoverHelp("📸 截圖與貼圖工作區 (Snipaste + PicPick)：", "提供框選截圖、即時標註塗鴉、螢幕懸浮貼圖、延遲截圖與像素放大鏡取色器。")
                            }
                        } else {
                            engine.setHoverHelp(nil, nil)
                        }
                    }
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.4))
            .cornerRadius(9)

            Spacer()

            // Quick Snip & Pin Buttons (Always Accessible!)
            HStack(spacing: 8) {
                Button(action: { engine.triggerScreenshot(modeOverride: .region) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "crop")
                        Text("區域截圖")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Color.cyan.opacity(0.22))
                    .foregroundColor(.cyan)
                    .cornerRadius(7)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.cyan.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .onHover { h in
                    if h {
                        engine.setHoverHelp(
                            "✂️ 框選截圖 (\(hotkeyManager.snipHotkey.label)\(hotkeyManager.alsoEnableF1F3 ? " / F1" : ""))：",
                            "下方自動浮出工具列，支援直接選擇「📌 釘選貼圖」、「📋 複製」、「💾 儲存」或「✏️ 編輯器」。"
                        )
                    } else {
                        engine.setHoverHelp(nil, nil)
                    }
                }

                Button(action: { engine.pinFromClipboard() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "pin.fill")
                        Text("貼圖")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.purple.opacity(0.25))
                    .foregroundColor(.purple)
                    .cornerRadius(7)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.purple.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .onHover { h in
                    if h {
                        engine.setHoverHelp(
                            "📌 剪貼簿貼圖 (\(hotkeyManager.pinHotkey.label)\(hotkeyManager.alsoEnableF1F3 ? " / F3" : ""))：",
                            "將剪貼簿中的圖片或文字直接釘選懸浮於螢幕最上層（滾輪縮放・Option+滾輪調透明度・雙擊關閉）。"
                        )
                    } else {
                        engine.setHoverHelp(nil, nil)
                    }
                }
            }

            // Live Timer & REC Button
            HStack(spacing: 10) {
                Text(engine.formattedElapsedTime)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(engine.status == .recording ? .red : (engine.status == .paused ? .yellow : .white))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.45))
                    .cornerRadius(7)

                if engine.status == .recording || engine.status == .paused {
                    Button(action: { engine.togglePause() }) {
                        Image(systemName: engine.status == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(Color.orange.opacity(0.85))
                            .foregroundColor(.white)
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in
                        engine.setHoverHelp(h ? "⏸ 暫停 / 繼續錄影：" : nil, h ? "暫停期間的畫面與時間會自動扣除，恢復錄影時無縫接續。" : nil)
                    }
                }

                Button(action: { engine.toggleRecording() }) {
                    HStack(spacing: 6) {
                        Image(systemName: engine.status == .idle ? "record.circle.fill" : "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text(engine.status == .idle ? "REC" : "STOP")
                            .font(.system(size: 13, weight: .heavy))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        engine.status == .idle
                            ? LinearGradient(colors: [Color(red: 0.9, green: 0.15, blue: 0.2), Color(red: 0.75, green: 0.08, blue: 0.12)], startPoint: .top, endPoint: .bottom)
                            : LinearGradient(colors: [Color.gray.opacity(0.8), Color.gray.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    )
                    .foregroundColor(.white)
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(engine.status == .stopping)
                .onHover { h in
                    if h {
                        engine.setHoverHelp(
                            "🔴 開始 / 停止錄影 (\(hotkeyManager.recordHotkey.label))：",
                            "依照目前選定的模式開始無時間限制錄製，即使在背景也可透過全域快捷鍵啟動或停止。"
                        )
                    } else {
                        engine.setHoverHelp(nil, nil)
                    }
                }
            }
        }
    }

    // MARK: - Recorder Sub-Mode Strip
    private var recorderModeSelectorBar: some View {
        HStack(spacing: 10) {
            ForEach(CaptureMode.allCases) { m in
                let isSelected = (engine.mode == m)
                Button(action: {
                    if engine.status == .idle {
                        engine.mode = m
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: m.iconName)
                            .font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.rawValue)
                                .font(.system(size: 13, weight: .bold))
                            Text(m.subtitle)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.red.opacity(0.28) : Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.red.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1.2)
                    )
                }
                .buttonStyle(.plain)
                .disabled(engine.status != .idle)
                .onHover { h in
                    if h {
                        engine.setHoverHelp("🎥 \(m.rawValue)模式：", m.subtitle)
                    } else {
                        engine.setHoverHelp(nil, nil)
                    }
                }
            }
        }
    }

    // MARK: - Screenshot Sub-Mode Strip
    private var screenshotModeSelectorBar: some View {
        HStack(spacing: 10) {
            ForEach(ScreenshotCaptureMode.allCases) { sm in
                let isSelected = (engine.screenshotMode == sm)
                Button(action: {
                    engine.screenshotMode = sm
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: sm.iconName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isSelected ? .cyan : .white)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sm.rawValue)
                                .font(.system(size: 13, weight: .bold))
                            Text(sm.subtitle)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.cyan.opacity(0.22) : Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.cyan.opacity(0.85) : Color.white.opacity(0.08), lineWidth: 1.2)
                    )
                }
                .buttonStyle(.plain)
                .onHover { h in
                    if h {
                        if sm == .region {
                            engine.setHoverHelp(
                                "✂️ 框選截圖 (\(hotkeyManager.snipHotkey.label))：",
                                "下方自動浮出工具列，支援直接選擇「📌 釘選貼圖」、「📋 複製」、「💾 儲存」或「✏️ 編輯器」。"
                            )
                        } else {
                            engine.setHoverHelp("📸 \(sm.rawValue)：", sm.subtitle)
                        }
                    } else {
                        engine.setHoverHelp(nil, nil)
                    }
                }
            }
        }
    }

    // MARK: - Global Background Hotkey Settings Card (背景快捷鍵設定)
    private var globalHotkeySettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("背景全域快捷鍵設定", systemImage: "keyboard.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Toggle("啟用背景熱鍵", isOn: $hotkeyManager.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Text("開啟後，即使 MingCam 縮小或在背景執行，您在使用瀏覽器、觀看影片或玩遊戲時也能直接按快捷鍵截圖、貼圖或錄影。")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))

            Divider().background(Color.white.opacity(0.1))

            // 1. Snip Hotkey Row
            hotkeyConfigRow(
                title: "✂️ 框選截圖：",
                currentCombo: $hotkeyManager.snipHotkey,
                presets: HotkeyCombo.snipPresets,
                targetID: "snip"
            )

            // 2. Pin Hotkey Row
            hotkeyConfigRow(
                title: "📌 剪貼簿貼圖：",
                currentCombo: $hotkeyManager.pinHotkey,
                presets: HotkeyCombo.pinPresets,
                targetID: "pin"
            )

            // 3. Color Picker Hotkey Row
            hotkeyConfigRow(
                title: "🎨 放大鏡取色：",
                currentCombo: $hotkeyManager.colorHotkey,
                presets: HotkeyCombo.colorPresets,
                targetID: "color"
            )

            // 4. Record / Stop Hotkey Row
            hotkeyConfigRow(
                title: "🔴 開始/停止錄影：",
                currentCombo: $hotkeyManager.recordHotkey,
                presets: HotkeyCombo.recordPresets,
                targetID: "record"
            )

            Divider().background(Color.white.opacity(0.08))

            Toggle("同時啟用 Snipaste 經典單鍵：按 F1 框選截圖 / 按 F3 貼圖", isOn: $hotkeyManager.alsoEnableF1F3)
                .font(.system(size: 11.5))

            Toggle("關閉主視窗時保留在背景與頂部選單列待命（隨時響應快捷鍵）", isOn: $hotkeyManager.keepAliveInBackground)
                .font(.system(size: 11.5))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.14, green: 0.15, blue: 0.18)))
    }

    private func hotkeyConfigRow(
        title: String,
        currentCombo: Binding<HotkeyCombo>,
        presets: [HotkeyCombo],
        targetID: String
    ) -> some View {
        let isRecordingThis = (hotkeyManager.recordingTargetAction == targetID)
        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 112, alignment: .leading)

            Menu {
                ForEach(presets) { preset in
                    Button(preset.label) {
                        currentCombo.wrappedValue = preset
                    }
                }
            } label: {
                Text(currentCombo.wrappedValue.label)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)

            Button(isRecordingThis ? "請按鍵...(ESC取消)" : "自訂按鍵") {
                if isRecordingThis {
                    hotkeyManager.stopCapturingCustomKey()
                } else {
                    hotkeyManager.startCapturingCustomKey(for: targetID)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isRecordingThis ? .orange : .gray)
            .controlSize(.small)
        }
    }

    // MARK: - Screenshot & Snipaste Cards (Left Column in Screenshot Tab)
    private var screenshotControlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("螢幕截圖與標註設定", systemImage: engine.screenshotMode.iconName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    engine.triggerScreenshot()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "camera.fill")
                        Text("立即啟動 (\(engine.screenshotMode.rawValue))")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.cyan)
                    .foregroundColor(.black)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { h in
                    if h {
                        engine.setHoverHelp(
                            "✂️ 框選截圖 (\(hotkeyManager.snipHotkey.label))：",
                            "下方自動浮出工具列，支援直接選擇「📌 釘選貼圖」、「📋 複製」、「💾 儲存」或「✏️ 編輯器」。"
                        )
                    } else {
                        engine.setHoverHelp(nil, nil)
                    }
                }
            }

            Divider().background(Color.white.opacity(0.1))

            if engine.screenshotMode == .window {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("選擇要擷取的視窗：")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.75))
                        Spacer()
                        Button("重新整理") {
                            Task { await engine.refreshShareableContent() }
                        }
                        .controlSize(.mini)
                    }
                    Picker("目標視窗", selection: $engine.selectedWindowID) {
                        ForEach(engine.availableWindows, id: \.windowID) { win in
                            let appName = win.owningApplication?.applicationName ?? "App"
                            let title = win.title ?? "無標題"
                            Text("[\(appName)] \(title)")
                                .tag(Optional(win.windowID))
                        }
                    }
                    .labelsHidden()
                }
            }

            HStack {
                Text("延遲倒數：")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                Picker("", selection: $engine.screenshotDelaySeconds) {
                    Text("立即 (0秒)").tag(0)
                    Text("3 秒後").tag(3)
                    Text("5 秒後").tag(5)
                }
                .pickerStyle(.segmented)
            }

            Toggle("截圖完成自動複製到剪貼簿", isOn: $engine.autoCopyScreenshot)
                .font(.system(size: 12))
            Toggle("截圖完成自動儲存 PNG 檔案", isOn: $engine.autoSaveScreenshot)
                .font(.system(size: 12))
            Toggle("全螢幕/視窗截圖後直接釘選為懸浮貼圖", isOn: $engine.autoPinAfterCapture)
                .font(.system(size: 12))
            Toggle("截圖時自動隱藏本控制面板視窗", isOn: $engine.excludeAppWindowInRecording)
                .font(.system(size: 12))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.14, green: 0.15, blue: 0.18)))
    }

    private var snipastePinManagerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Snipaste 螢幕貼圖管理", systemImage: "pin.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("目前貼圖：\(pinManager.activePins.count) 張")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.purple)
            }

            Text("支援將截圖、剪貼簿圖片或複製的文字釘選在螢幕最上層。滑鼠滾輪可縮放大小，按住 Option+滾輪可調整透明度，雙擊即可關閉。")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.65))

            HStack(spacing: 8) {
                Button(action: { engine.pinFromClipboard() }) {
                    Label("從剪貼簿貼圖 (\(hotkeyManager.pinHotkey.label))", systemImage: "doc.on.clipboard.fill")
                        .font(.system(size: 11.5, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)

                if !pinManager.activePins.isEmpty {
                    Button(pinManager.allPinsHidden ? "顯示全部" : "隱藏全部") {
                        pinManager.toggleHideAllPins()
                    }
                    .controlSize(.small)

                    Button("關閉全部") {
                        pinManager.closeAllPins()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.14, green: 0.15, blue: 0.18)))
    }

    private var picPickColorHistoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("PicPick 螢幕取色紀錄", systemImage: "eyedropper.halffull")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button("啟動放大鏡取色 (\(hotkeyManager.colorHotkey.label))") {
                    engine.triggerScreenshot(modeOverride: .colorPicker)
                }
                .controlSize(.small)
            }

            if engine.pickedColorsHistory.isEmpty {
                Text("在截圖或取色模式中移動游標並按 C 鍵，即可擷取螢幕任意像素的 HEX / RGB 色碼。")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array(engine.pickedColorsHistory.enumerated()), id: \.offset) { _, item in
                        Button(action: {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(item.hex, forType: .string)
                            engine.statusMessage = "已複製色碼：\(item.hex)"
                        }) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: item.color))
                                    .frame(width: 16, height: 16)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.4), lineWidth: 0.5))
                                Text(item.hex)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.14, green: 0.15, blue: 0.18)))
    }

    // MARK: - Latest Screenshot Quick Preview Card
    private func latestScreenshotPreviewCard(_ image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("最新截圖預覽 (\(Int(image.size.width)) × \(Int(image.size.height)))", systemImage: "photo.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.cyan)
                Spacer()
                Button("📌 釘選到螢幕") {
                    engine.pinImageToScreen(image)
                }
                .controlSize(.small)
                Button("📋 複製") {
                    engine.copyImageToClipboard(image)
                    engine.statusMessage = "已複製截圖到剪貼簿"
                }
                .controlSize(.small)
                Button("💾 另存 PNG") {
                    if let url = engine.saveScreenshotToDisk(image) {
                        engine.statusMessage = "已儲存：\(url.lastPathComponent)"
                    }
                }
                .controlSize(.small)
            }

            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 150)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.35))
                .cornerRadius(6)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.14, green: 0.15, blue: 0.18)))
    }

    // MARK: - Recorder Capture Target Card
    private var captureTargetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("錄製範圍設定", systemImage: engine.mode.iconName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    Task { await engine.refreshShareableContent() }
                }) {
                    Label("重新整理", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(engine.status != .idle)
            }

            Divider().background(Color.white.opacity(0.1))

            switch engine.mode {
            case .region:
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("目前框選尺寸：")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.75))
                        Text("\(Int(overlayController.regionRectInAppKit.width)) × \(Int(overlayController.regionRectInAppKit.height)) pt")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                        Spacer()
                        Button(overlayController.isVisible ? "隱藏綠框" : "顯示綠框") {
                            if overlayController.isVisible {
                                overlayController.hide()
                            } else {
                                overlayController.show()
                            }
                        }
                        .controlSize(.small)
                    }

                    Text("快速尺寸預設（可直接拖曳螢幕上的綠框標籤移動、拉動邊緣縮放）：")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))

                    HStack(spacing: 8) {
                        presetButton("1920×1080", w: 1920, h: 1080)
                        presetButton("1280×720", w: 1280, h: 720)
                        presetButton("1024×768", w: 1024, h: 768)
                        presetButton("直式 720×1280", w: 720, h: 1280)
                    }
                }

            case .fullScreen:
                VStack(alignment: .leading, spacing: 8) {
                    Text("選擇要錄製的螢幕：")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.75))
                    Picker("螢幕顯示器", selection: $engine.selectedDisplayID) {
                        ForEach(engine.availableDisplays, id: \.displayID) { disp in
                            Text("顯示器 #\(disp.displayID) (\(disp.width)×\(disp.height))")
                                .tag(Optional(disp.displayID))
                        }
                    }
                    .labelsHidden()
                    .disabled(engine.status != .idle)
                }

            case .window:
                VStack(alignment: .leading, spacing: 8) {
                    Text("選擇要錄製的應用程式視窗：")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.75))
                    Picker("目標視窗", selection: $engine.selectedWindowID) {
                        ForEach(engine.availableWindows, id: \.windowID) { win in
                            let appName = win.owningApplication?.applicationName ?? "App"
                            let title = win.title ?? "無標題"
                            Text("[\(appName)] \(title)")
                                .tag(Optional(win.windowID))
                        }
                    }
                    .labelsHidden()
                    .disabled(engine.status != .idle)
                }

            case .audioOnly:
                VStack(alignment: .leading, spacing: 6) {
                    Text("純音訊內錄模式 (.m4a)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.green)
                    Text("直接擷取 macOS 系統內部播放的高音質數位音訊（AAC 48kHz / 192kbps），適合錄製音樂、會議、直播或語音。")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.14, green: 0.15, blue: 0.18)))
    }

    private func presetButton(_ label: String, w: CGFloat, h: CGFloat) -> some View {
        Button(label) {
            overlayController.show()
            overlayController.setPresetSize(width: w, height: h)
        }
        .controlSize(.small)
        .disabled(engine.status != .idle)
    }

    // MARK: - Recording Settings Card
    private var recordingSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("錄影畫質與音訊設定", systemImage: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                // Live Audio Meter
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.12))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(2, geo.size.width * CGFloat(engine.audioLevel)))
                        }
                    }
                    .frame(width: 75, height: 6)
                }
            }

            Divider().background(Color.white.opacity(0.1))

            if engine.mode != .audioOnly {
                HStack {
                    Text("影格率 (FPS)：")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                    Picker("", selection: $engine.fps) {
                        Text("30 FPS (省空間)").tag(30)
                        Text("60 FPS (高流暢)").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .disabled(engine.status != .idle)
                }

                Toggle("錄影中顯示滑鼠游標", isOn: $engine.showsCursor)
                    .font(.system(size: 12))
                    .disabled(engine.status != .idle)

                Toggle("錄影畫面自動排除本控制面板視窗", isOn: $engine.excludeAppWindowInRecording)
                    .font(.system(size: 12))
                    .disabled(engine.status != .idle)
            }

            Toggle("錄製系統內部聲音（電腦播放的聲音）", isOn: $engine.captureSystemAudio)
                .font(.system(size: 12, weight: .medium))
                .disabled(engine.status != .idle)

            Toggle("同時錄製麥克風聲音", isOn: $engine.captureMicrophone)
                .font(.system(size: 12))
                .disabled(engine.status != .idle)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.14, green: 0.15, blue: 0.18)))
    }

    // MARK: - Output Files Card
    private var outputFilesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("輸出資料夾與檔案列表", systemImage: "folder.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Picker("", selection: $engine.fileFilter) {
                    ForEach(FileCategoryFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Button("更換目錄") {
                    engine.chooseOutputFolder()
                }
                .controlSize(.small)
                Button("Finder") {
                    engine.openOutputFolder()
                }
                .controlSize(.small)
            }

            Text(engine.outputFolderURL.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)

            Divider().background(Color.white.opacity(0.1))

            if engine.filteredFiles.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.25))
                    Text("目前分類尚無檔案")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.45))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(engine.filteredFiles) { item in
                            HStack(spacing: 10) {
                                Image(systemName: iconForFile(item))
                                    .font(.system(size: 20))
                                    .foregroundColor(colorForFile(item))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text("\(item.fileSizeString) ・ \(item.formattedDate)")
                                        .font(.system(size: 10.5))
                                        .foregroundColor(.white.opacity(0.55))
                                }

                                Spacer()

                                if item.isScreenshot {
                                    Button("📌 貼圖") {
                                        if let img = NSImage(contentsOf: item.url) {
                                            engine.pinImageToScreen(img)
                                        }
                                    }
                                    .controlSize(.small)
                                }

                                Button(item.isScreenshot ? "開啟" : "播放") {
                                    engine.openFile(item)
                                }
                                .controlSize(.small)

                                Button(action: { engine.revealFile(item) }) {
                                    Image(systemName: "magnifyingglass")
                                }
                                .controlSize(.small)
                                .help("在 Finder 中顯示")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.14, green: 0.15, blue: 0.18)))
    }

    private func iconForFile(_ item: RecordedFileItem) -> String {
        if item.isScreenshot { return "photo.circle.fill" }
        if item.isAudioOnly { return "waveform.circle.fill" }
        return "video.circle.fill"
    }

    private func colorForFile(_ item: RecordedFileItem) -> Color {
        if item.isScreenshot { return .cyan }
        if item.isAudioOnly { return .green }
        return .red
    }

    // MARK: - Footer Bar
    private var footerBar: some View {
        HStack {
            Text(engine.statusMessage)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
            Spacer()
            Text("背景快捷鍵：\(hotkeyManager.snipHotkey.label)\(hotkeyManager.alsoEnableF1F3 ? "/F1" : "") 截圖 ｜ \(hotkeyManager.pinHotkey.label)\(hotkeyManager.alsoEnableF1F3 ? "/F3" : "") 貼圖 ｜ \(hotkeyManager.recordHotkey.label) 錄影")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
    }
}
