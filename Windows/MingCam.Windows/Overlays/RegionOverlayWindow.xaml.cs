using System;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using MingCam.Windows.Interop;

namespace MingCam.Windows.Overlays;

public partial class RegionOverlayWindow : Window
{
    private bool _isRecordingMode;

    public RegionOverlayWindow()
    {
        InitializeComponent();
        SourceInitialized += OnSourceInitialized;
        SizeChanged += (_, _) => UpdateSizeBadge();
        LocationChanged += (_, _) => UpdateSizeBadge();
        Loaded += (_, _) => UpdateSizeBadge();
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        int exStyle = NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE);
        NativeMethods.SetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE, exStyle | NativeMethods.WS_EX_TOOLWINDOW);

        // Exclude this overlay frame from screen capture so the green/red border never appears in videos
        NativeMethods.SetWindowDisplayAffinity(hwnd, NativeMethods.WDA_EXCLUDEFROMCAPTURE);
    }

    public void SetRecordingMode(bool recording)
    {
        _isRecordingMode = recording;
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd != IntPtr.Zero)
        {
            int exStyle = NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE);
            if (recording)
                exStyle |= NativeMethods.WS_EX_TRANSPARENT;
            else
                exStyle &= ~NativeMethods.WS_EX_TRANSPARENT;

            NativeMethods.SetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE, exStyle);
            NativeMethods.SetWindowDisplayAffinity(hwnd, NativeMethods.WDA_EXCLUDEFROMCAPTURE);
        }

        if (recording)
        {
            FrameBorder.BorderBrush = new SolidColorBrush(Color.FromRgb(239, 68, 68)); // Red
            TopHandle.Visibility = Visibility.Collapsed;
            ResizeGrip.Visibility = Visibility.Collapsed;
        }
        else
        {
            FrameBorder.BorderBrush = new SolidColorBrush(Color.FromRgb(34, 197, 94)); // Green
            TopHandle.Visibility = Visibility.Visible;
            ResizeGrip.Visibility = Visibility.Visible;
            UpdateSizeBadge();
        }
    }

    public NativeMethods.RECT GetCapturePixelRect()
    {
        var source = PresentationSource.FromVisual(this);
        double scaleX = source?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        double scaleY = source?.CompositionTarget?.TransformToDevice.M22 ?? 1.0;

        // Inset by 3px border thickness
        int left = (int)Math.Round((Left + 3) * scaleX);
        int top = (int)Math.Round((Top + 3) * scaleY);
        int width = Math.Max(32, (int)Math.Round((Width - 6) * scaleX));
        int height = Math.Max(32, (int)Math.Round((Height - 6) * scaleY));

        return new NativeMethods.RECT
        {
            Left = left,
            Top = top,
            Right = left + width,
            Bottom = top + height
        };
    }

    private void UpdateSizeBadge()
    {
        if (_isRecordingMode) return;
        var rect = GetCapturePixelRect();
        SizeBadgeText.Text = $"拖曳移動區域框 ｜ {rect.Width} × {rect.Height} px";
    }

    private void TopHandle_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (!_isRecordingMode && e.ButtonState == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void ResizeGrip_DragDelta(object sender, DragDeltaEventArgs e)
    {
        if (_isRecordingMode) return;
        Width = Math.Max(MinWidth, Width + e.HorizontalChange);
        Height = Math.Max(MinHeight, Height + e.VerticalChange);
    }
}
