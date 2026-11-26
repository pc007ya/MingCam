import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

enum AppWorkspaceTab: String, CaseIterable, Identifiable {
    case recorder = "錄影與錄音"
    case screenshot = "截圖與貼圖"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .recorder: return "video.fill"
        case .screenshot: return "viewfinder"
        }
    }
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case fullScreen = "全螢幕"
    case region = "矩形區域"
    case window = "指定視窗"
    case audioOnly = "純音訊 (M4A)"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .region: return "viewfinder.rectangular"
        case .fullScreen: return "display"
        case .window: return "macwindow"
        case .audioOnly: return "waveform"
        }
    }

    var subtitle: String {
        switch self {
        case .region: return "自訂框選螢幕範圍（類 Bandicam 綠框）"
        case .fullScreen: return "錄製整個螢幕畫面"
        case .window: return "鎖定單一應用程式視窗錄製"
        case .audioOnly: return "僅錄製系統聲音／麥克風為 .m4a"
        }
    }
}

enum ScreenshotCaptureMode: String, CaseIterable, Identifiable {
    case region = "區域截圖 (Snipaste)"
    case window = "指定視窗截圖"
    case fullScreen = "全螢幕截圖"
    case colorPicker = "螢幕取色放大鏡"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .region: return "crop"
        case .window: return "macwindow.badge.plus"
        case .fullScreen: return "camera.viewfinder"
        case .colorPicker: return "eyedropper.halffull"
        }
    }

    var subtitle: String {
        switch self {
        case .region: return "框選範圍 + 即時標註 + 釘選貼圖 (F1)"
        case .window: return "擷取單一應用程式視窗為高畫質 PNG"
        case .fullScreen: return "立即擷取整個螢幕畫面"
        case .colorPicker: return "放大鏡像素取色，自動複製 HEX/RGB"
        }
    }
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case rectangle = "矩形"
    case ellipse = "橢圓"
    case arrow = "箭頭"
    case line = "直線"
    case pen = "畫筆"
    case highlighter = "螢光筆"
    case mosaic = "馬賽克"
    case counter = "序號"
    case text = "文字"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .mosaic: return "checkerboard.rectangle"
        case .counter: return "1.circle.fill"
        case .text: return "textformat"
        }
    }
}

struct AnnotationShape: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor
    var lineWidth: CGFloat
    var text: String = ""
    var stepNumber: Int = 1
}

enum RecordingStatus: Equatable {
    case idle
    case recording
    case paused
    case stopping
}

enum FileCategoryFilter: String, CaseIterable, Identifiable {
    case all = "全部檔案"
    case videoAudio = "錄影/錄音"
    case screenshots = "螢幕截圖"

    var id: String { rawValue }
}

struct RecordedFileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let fileSizeString: String
    let createdAt: Date

    var isScreenshot: Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "png" || ext == "jpg" || ext == "jpeg"
    }

    var isAudioOnly: Bool {
        url.pathExtension.lowercased() == "m4a"
    }

    var formattedDate: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return df.string(from: createdAt)
    }
}
