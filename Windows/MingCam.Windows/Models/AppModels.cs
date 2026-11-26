using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Media;

namespace MingCam.Windows.Models;

public enum CaptureMode
{
    FullScreen,
    Region,
    Window,
    AudioOnly
}

public enum ScreenshotCaptureMode
{
    Region,
    Window,
    FullScreen,
    ColorPicker
}

public enum AnnotationTool
{
    Rectangle,
    Ellipse,
    Arrow,
    Line,
    Pen,
    Highlighter,
    Mosaic,
    Counter,
    Text
}

public sealed class AnnotationShape
{
    public AnnotationTool Tool { get; set; }
    public List<Point> Points { get; set; } = new();
    public Color Color { get; set; } = Colors.Red;
    public double LineWidth { get; set; } = 3.0;
    public string Text { get; set; } = string.Empty;
    public int StepNumber { get; set; } = 1;
}

public enum RecordingStatus
{
    Idle,
    Recording,
    Paused,
    Stopping
}

public enum FileCategoryFilter
{
    All,
    VideoAudio,
    Screenshots
}

public sealed class RecordedFileItem
{
    public string FullPath { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public string FileSizeString { get; init; } = string.Empty;
    public DateTime CreatedAt { get; init; }

    public string Extension => Path.GetExtension(FullPath).ToLowerInvariant();
    public bool IsScreenshot => Extension is ".png" or ".jpg" or ".jpeg";
    public bool IsAudioOnly => Extension is ".m4a" or ".wav";
    public string TypeBadge => IsScreenshot ? "PNG" : (IsAudioOnly ? "M4A" : "MP4");
    public string FormattedDate => CreatedAt.ToString("yyyy/MM/dd HH:mm:ss");
}

public sealed class MonitorTargetItem
{
    public IntPtr Handle { get; init; }
    public string Name { get; init; } = string.Empty;
    public int Left { get; init; }
    public int Top { get; init; }
    public int Width { get; init; }
    public int Height { get; init; }
    public bool IsPrimary { get; init; }

    public string DisplayLabel => $"{Name} ({Width}×{Height}){(IsPrimary ? " [主螢幕]" : "")}";
    public override string ToString() => DisplayLabel;
}

public sealed class WindowTargetItem
{
    public IntPtr Handle { get; init; }
    public string Title { get; init; } = string.Empty;
    public string ProcessName { get; init; } = string.Empty;

    public string DisplayLabel => string.IsNullOrWhiteSpace(ProcessName)
        ? Title
        : $"[{ProcessName}] {Title}";

    public override string ToString() => DisplayLabel;
}
