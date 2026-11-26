using System;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace MingCam.Windows;

public partial class OverlayTestWindow : Window
{
    private readonly DispatcherTimer _closeTimer;

    public bool ExcludeFromCaptureSucceeded { get; private set; }

    public OverlayTestWindow()
    {
        InitializeComponent();
        SourceInitialized += OnSourceInitialized;

        _closeTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _closeTimer.Tick += (_, _) =>
        {
            _closeTimer.Stop();
            Close();
        };
        Loaded += (_, _) => _closeTimer.Start();
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        int exStyle = NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE);
        NativeMethods.SetWindowLong(
            hwnd,
            NativeMethods.GWL_EXSTYLE,
            exStyle | NativeMethods.WS_EX_TRANSPARENT | NativeMethods.WS_EX_TOOLWINDOW);

        ExcludeFromCaptureSucceeded = NativeMethods.SetWindowDisplayAffinity(
            hwnd,
            NativeMethods.WDA_EXCLUDEFROMCAPTURE);
    }
}
