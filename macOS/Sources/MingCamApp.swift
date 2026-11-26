import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !GlobalHotkeyManager.shared.keepAliveInBackground
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }
}

@main
struct MingCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = ScreenRecorderEngine()
    @ObservedObject private var hotkeyManager = GlobalHotkeyManager.shared

    var body: some Scene {
        WindowGroup("MingCam — 錄影・錄音・Snipaste 截圖貼圖・PicPick 標註") {
            ContentView(engine: engine)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("錄影與截圖") {
                Button("✂️ 區域截圖 + 標註 (\(hotkeyManager.snipHotkey.label))") {
                    engine.triggerScreenshot(modeOverride: .region)
                }

                Button("📌 從剪貼簿釘選貼圖 (\(hotkeyManager.pinHotkey.label))") {
                    engine.pinFromClipboard()
                }

                Button("🎨 螢幕放大鏡取色器 (\(hotkeyManager.colorHotkey.label))") {
                    engine.triggerScreenshot(modeOverride: .colorPicker)
                }

                Divider()

                Button(engine.status == .idle ? "🔴 開始錄製影片/音訊 (\(hotkeyManager.recordHotkey.label))" : "⏹ 停止錄製 (\(hotkeyManager.recordHotkey.label))") {
                    engine.toggleRecording()
                }

                if engine.status == .recording || engine.status == .paused {
                    Button(engine.status == .paused ? "▶️ 繼續錄製" : "⏸ 暫停錄製") {
                        engine.togglePause()
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                }
            }
        }

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                Text("MingCam (\(engine.formattedElapsedTime))")
                    .font(.headline)
                Divider()
                Button("🖥 顯示主控制面板") {
                    NSApp.activate(ignoringOtherApps: true)
                    for win in NSApp.windows {
                        win.makeKeyAndOrderFront(nil)
                    }
                }
                Divider()
                Button("✂️ 區域截圖 + 標註 (\(hotkeyManager.snipHotkey.label))") {
                    engine.triggerScreenshot(modeOverride: .region)
                }
                Button("🖥 全螢幕截圖") {
                    engine.triggerScreenshot(modeOverride: .fullScreen)
                }
                Button("📌 從剪貼簿貼圖 (\(hotkeyManager.pinHotkey.label))") {
                    engine.pinFromClipboard()
                }
                Button("🎨 螢幕放大鏡取色 (\(hotkeyManager.colorHotkey.label))") {
                    engine.triggerScreenshot(modeOverride: .colorPicker)
                }
                Divider()
                Button(engine.status == .idle ? "🔴 開始錄製 (\(hotkeyManager.recordHotkey.label))" : "⏹ 停止錄製 (\(hotkeyManager.recordHotkey.label))") {
                    engine.toggleRecording()
                }
                if engine.status == .recording || engine.status == .paused {
                    Button(engine.status == .paused ? "▶️ 繼續錄製" : "⏸ 暫停錄製") {
                        engine.togglePause()
                    }
                }
                Divider()
                Button("開啟輸出資料夾") {
                    engine.openOutputFolder()
                }
                Button("結束 MingCam") {
                    NSApp.terminate(nil)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: engine.status == .recording ? "record.circle.fill" : "viewfinder")
                if engine.status != .idle {
                    Text(engine.formattedElapsedTime)
                }
            }
        }
    }
}
