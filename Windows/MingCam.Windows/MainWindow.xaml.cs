using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using MingCam.Windows.Interop;
using MingCam.Windows.Models;
using MingCam.Windows.Overlays;
using MingCam.Windows.Services;
using CaptureMode = MingCam.Windows.Models.CaptureMode;

namespace MingCam.Windows;

public partial class MainWindow : Window
{
    private readonly ScreenRecorderEngine _recorder = new();
    private readonly GlobalHotkeyService _hotkeys = new();
    private readonly DispatcherTimer _uiTimer;
    private readonly List<SnipastePinWindow> _pinWindows = new();

    private RegionOverlayWindow? _regionOverlay;
    private ScreenshotOverlayWindow? _activeShotOverlay;

    public MainWindow()
    {
        InitializeComponent();

        _recorder.StateChanged += () => Dispatcher.Invoke(SyncRecorderUi);
        _recorder.RecordingSaved += path => Dispatcher.Invoke(() =>
        {
            SetStatus($"✅ 已儲存錄製檔案：{Path.GetFileName(path)}");
            RefreshFiles();
        });

        _uiTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        _uiTimer.Tick += (_, _) =>
        {
            if (_recorder.Status is RecordingStatus.Recording or RecordingStatus.Paused)
            {
                RecTimerLabel.Text = _recorder.Elapsed.ToString(@"hh\:mm\:ss");
            }
        };

        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        OutputFolderLabel.Text = $"輸出位置：{_recorder.OutputDirectory}";
        RefreshTargets();
        RefreshFiles();

        _hotkeys.RegionScreenshotTriggered += () => Dispatcher.Invoke(() => LaunchScreenshotOverlay(colorPickerOnly: false));
        _hotkeys.PinClipboardTriggered += () => Dispatcher.Invoke(PinFromClipboard);
        _hotkeys.ColorPickerTriggered += () => Dispatcher.Invoke(() => LaunchScreenshotOverlay(colorPickerOnly: true));
        _hotkeys.ToggleRecordTriggered += () => Dispatcher.Invoke(ToggleRecordingByHotkey);
        _hotkeys.Attach(this);

        HotkeyStatusText.Text = _hotkeys.StatusSummary;
        SetStatus("MingCam for Windows 已就緒。");
    }

    private void SetStatus(string msg)
    {
        StatusFooterText.Text = $"[{DateTime.Now:HH:mm:ss}] {msg}";
    }

    // --- Navigation ---

    private void SwitchPanel(UIElement target, Button activeBtn)
    {
        RecorderPanel.Visibility = target == RecorderPanel ? Visibility.Visible : Visibility.Collapsed;
        ScreenshotPanel.Visibility = target == ScreenshotPanel ? Visibility.Visible : Visibility.Collapsed;
        FilesPanel.Visibility = target == FilesPanel ? Visibility.Visible : Visibility.Collapsed;

        var navButtons = new[] { NavRecorderBtn, NavScreenshotBtn, NavFilesBtn };
        foreach (var btn in navButtons)
        {
            bool active = btn == activeBtn;
            btn.Background = active ? new SolidColorBrush(Color.FromRgb(30, 41, 59)) : Brushes.Transparent;
            btn.Foreground = active ? Brushes.White : new SolidColorBrush(Color.FromRgb(148, 163, 184));
            btn.FontWeight = active ? FontWeights.SemiBold : FontWeights.Medium;
        }
    }

    private void NavRecorder_Click(object sender, RoutedEventArgs e) => SwitchPanel(RecorderPanel, NavRecorderBtn);
    private void NavScreenshot_Click(object sender, RoutedEventArgs e) => SwitchPanel(ScreenshotPanel, NavScreenshotBtn);
    private void NavFiles_Click(object sender, RoutedEventArgs e)
    {
        RefreshFiles();
        SwitchPanel(FilesPanel, NavFilesBtn);
    }

    // --- Recorder ---

    private CaptureMode GetSelectedCaptureMode()
    {
        if (ModeRegionRadio.IsChecked == true) return CaptureMode.Region;
        if (ModeWindowRadio.IsChecked == true) return CaptureMode.Window;
        if (ModeAudioOnlyRadio.IsChecked == true) return CaptureMode.AudioOnly;
        return CaptureMode.FullScreen;
    }

    private void CaptureMode_Changed(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        var mode = GetSelectedCaptureMode();

        MonitorPickerRow.Visibility = mode == CaptureMode.FullScreen ? Visibility.Visible : Visibility.Collapsed;
        RegionHintRow.Visibility = mode == CaptureMode.Region ? Visibility.Visible : Visibility.Collapsed;
        WindowPickerRow.Visibility = mode == CaptureMode.Window ? Visibility.Visible : Visibility.Collapsed;
        AudioOnlyHintRow.Visibility = mode == CaptureMode.AudioOnly ? Visibility.Visible : Visibility.Collapsed;

        if (mode == CaptureMode.Region)
        {
            EnsureRegionOverlayVisible();
        }
        else if (_recorder.Status == RecordingStatus.Idle)
        {
            HideRegionOverlay();
        }
    }

    private void EnsureRegionOverlayVisible()
    {
        if (_regionOverlay == null)
        {
            _regionOverlay = new RegionOverlayWindow();
            _regionOverlay.Closed += (_, _) => _regionOverlay = null;
        }
        _regionOverlay.SetRecordingMode(_recorder.Status is RecordingStatus.Recording or RecordingStatus.Paused);
        _regionOverlay.Show();
    }

    private void HideRegionOverlay()
    {
        if (_regionOverlay != null)
        {
            _regionOverlay.Close();
            _regionOverlay = null;
        }
    }

    private void RefreshTargets_Click(object sender, RoutedEventArgs e) => RefreshTargets();

    private void RefreshTargets()
    {
        var monitors = NativeMethods.GetMonitors();
        MonitorCombo.ItemsSource = monitors;
        MonitorCombo.SelectedItem = monitors.FirstOrDefault(m => m.IsPrimary) ?? monitors.FirstOrDefault();

        IntPtr ownHwnd = new WindowInteropHelper(this).Handle;
        var windows = NativeMethods.GetCapturableWindows(ownHwnd);
        WindowCombo.ItemsSource = windows;
        if (windows.Count > 0) WindowCombo.SelectedIndex = 0;
    }

    private void StartRecord_Click(object sender, RoutedEventArgs e) => StartRecording();

    private void StartRecording()
    {
        var mode = GetSelectedCaptureMode();
        int fps = Fps60Radio.IsChecked == true ? 60 : 30;
        bool sysAudio = SystemAudioCheck.IsChecked == true;
        bool micAudio = MicAudioCheck.IsChecked == true;

        NativeMethods.RECT regionRect = default;
        if (mode == CaptureMode.Region)
        {
            EnsureRegionOverlayVisible();
            regionRect = _regionOverlay!.GetCapturePixelRect();
            _regionOverlay.SetRecordingMode(true);
        }

        bool started = _recorder.StartRecording(
            mode,
            fps,
            sysAudio,
            micAudio,
            MonitorCombo.SelectedItem as MonitorTargetItem,
            WindowCombo.SelectedItem as WindowTargetItem,
            regionRect);

        if (started)
        {
            _uiTimer.Start();
            SetStatus($"正在錄製 ({mode}, {fps} FPS)...");
        }
        else
        {
            _regionOverlay?.SetRecordingMode(false);
            if (!string.IsNullOrEmpty(_recorder.LastError))
            {
                SetStatus($"⚠️ {_recorder.LastError}");
                MessageBox.Show(_recorder.LastError, "MingCam 錄影提示", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
    }

    private void PauseRecord_Click(object sender, RoutedEventArgs e)
    {
        _recorder.TogglePause();
    }

    private async void StopRecord_Click(object sender, RoutedEventArgs e)
    {
        await StopRecordingAsync();
    }

    private async Task StopRecordingAsync()
    {
        _uiTimer.Stop();
        await _recorder.StopRecordingAsync();
        _regionOverlay?.SetRecordingMode(false);
    }

    private async void ToggleRecordingByHotkey()
    {
        if (_recorder.Status == RecordingStatus.Idle)
        {
            StartRecording();
        }
        else if (_recorder.Status is RecordingStatus.Recording or RecordingStatus.Paused)
        {
            await StopRecordingAsync();
        }
    }

    private void SyncRecorderUi()
    {
        var st = _recorder.Status;
        bool idle = st == RecordingStatus.Idle;

        StartRecordBtn.IsEnabled = idle;
        PauseRecordBtn.IsEnabled = st is RecordingStatus.Recording or RecordingStatus.Paused;
        StopRecordBtn.IsEnabled = st is RecordingStatus.Recording or RecordingStatus.Paused;

        PauseRecordBtn.Content = st == RecordingStatus.Paused ? "▶ 繼續" : "⏸ 暫停";

        switch (st)
        {
            case RecordingStatus.Idle:
                RecStatusLabel.Text = "待機就緒";
                RecIndicatorDot.Fill = new SolidColorBrush(Color.FromRgb(100, 116, 139));
                RecTimerLabel.Text = "00:00:00";
                break;
            case RecordingStatus.Recording:
                RecStatusLabel.Text = "正在錄製中...";
                RecIndicatorDot.Fill = new SolidColorBrush(Color.FromRgb(239, 68, 68));
                break;
            case RecordingStatus.Paused:
                RecStatusLabel.Text = "已暫停錄製";
                RecIndicatorDot.Fill = new SolidColorBrush(Color.FromRgb(234, 179, 8));
                break;
            case RecordingStatus.Stopping:
                RecStatusLabel.Text = "正在寫入檔案...";
                RecIndicatorDot.Fill = new SolidColorBrush(Color.FromRgb(56, 189, 248));
                break;
        }
    }

    // --- Screenshot & Snipaste Pin ---

    private void RegionScreenshot_Click(object sender, RoutedEventArgs e) => LaunchScreenshotOverlay(colorPickerOnly: false);
    private void ColorPicker_Click(object sender, RoutedEventArgs e) => LaunchScreenshotOverlay(colorPickerOnly: true);

    private void LaunchScreenshotOverlay(bool colorPickerOnly)
    {
        if (_activeShotOverlay != null)
        {
            _activeShotOverlay.Activate();
            return;
        }

        var overlay = new ScreenshotOverlayWindow(
            colorPickerOnly,
            _recorder.OutputDirectory,
            onPin: bmp => Dispatcher.Invoke(() => OpenPinWindow(bmp)),
            onSaved: path => Dispatcher.Invoke(() =>
            {
                SetStatus($"✅ 截圖已儲存並複製：{Path.GetFileName(path)}");
                RefreshFiles();
            }),
            onToast: msg => Dispatcher.Invoke(() => SetStatus(msg)));

        overlay.Closed += (_, _) => _activeShotOverlay = null;
        _activeShotOverlay = overlay;
        overlay.Show();
    }

    private void FullScreenShot_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            int vx = NativeMethods.GetSystemMetrics(NativeMethods.SM_XVIRTUALSCREEN);
            int vy = NativeMethods.GetSystemMetrics(NativeMethods.SM_YVIRTUALSCREEN);
            int vw = NativeMethods.GetSystemMetrics(NativeMethods.SM_CXVIRTUALSCREEN);
            int vh = NativeMethods.GetSystemMetrics(NativeMethods.SM_CYVIRTUALSCREEN);

            IntPtr desktopDc = NativeMethods.GetDC(IntPtr.Zero);
            IntPtr memDc = NativeMethods.CreateCompatibleDC(desktopDc);
            IntPtr hBitmap = NativeMethods.CreateCompatibleBitmap(desktopDc, vw, vh);
            IntPtr oldObj = NativeMethods.SelectObject(memDc, hBitmap);
            try
            {
                NativeMethods.BitBlt(memDc, 0, 0, vw, vh, desktopDc, vx, vy, NativeMethods.SRCCOPY | NativeMethods.CAPTUREBLT);
                BitmapSource bmp = Imaging.CreateBitmapSourceFromHBitmap(hBitmap, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                bmp.Freeze();

                string path = Path.Combine(_recorder.OutputDirectory, $"MingCam_Full_{DateTime.Now:yyyyMMdd_HHmmss}.png");
                using (var fs = File.Create(path))
                {
                    var enc = new PngBitmapEncoder();
                    enc.Frames.Add(BitmapFrame.Create(bmp));
                    enc.Save(fs);
                }
                Clipboard.SetImage(bmp);
                SetStatus($"✅ 全螢幕截圖已儲存並複製：{Path.GetFileName(path)}");
                RefreshFiles();
            }
            finally
            {
                NativeMethods.SelectObject(memDc, oldObj);
                NativeMethods.DeleteObject(hBitmap);
                NativeMethods.DeleteDC(memDc);
                NativeMethods.ReleaseDC(IntPtr.Zero, desktopDc);
            }
        }
        catch (Exception ex)
        {
            SetStatus($"❌ 全螢幕截圖失敗：{ex.Message}");
        }
    }

    private void PinClipboard_Click(object sender, RoutedEventArgs e) => PinFromClipboard();

    private void PinFromClipboard()
    {
        try
        {
            if (Clipboard.ContainsImage())
            {
                var img = Clipboard.GetImage();
                if (img != null)
                {
                    OpenPinWindow(img);
                    SetStatus("📌 已將剪貼簿圖片釘選到螢幕最上層。");
                    return;
                }
            }
            if (Clipboard.ContainsText())
            {
                string txt = Clipboard.GetText();
                if (!string.IsNullOrWhiteSpace(txt))
                {
                    var pin = new SnipastePinWindow(txt);
                    TrackPinWindow(pin);
                    pin.Show();
                    SetStatus("📌 已將剪貼簿文字釘選到螢幕最上層。");
                    return;
                }
            }
            SetStatus("剪貼簿內沒有圖片或文字可供貼圖。");
        }
        catch (Exception ex)
        {
            SetStatus($"❌ 讀取剪貼簿失敗：{ex.Message}");
        }
    }

    private void OpenPinWindow(BitmapSource image)
    {
        var pin = new SnipastePinWindow(image);
        TrackPinWindow(pin);
        pin.Show();
    }

    private void TrackPinWindow(SnipastePinWindow pin)
    {
        _pinWindows.Add(pin);
        pin.Closed += (_, _) =>
        {
            _pinWindows.Remove(pin);
            UpdatePinCountLabel();
        };
        UpdatePinCountLabel();
    }

    private void UpdatePinCountLabel()
    {
        CloseAllPinsBtn.Content = $"關閉全部貼圖 ({_pinWindows.Count})";
    }

    private void CloseAllPins_Click(object sender, RoutedEventArgs e)
    {
        foreach (var pin in _pinWindows.ToList())
        {
            pin.Close();
        }
        _pinWindows.Clear();
        UpdatePinCountLabel();
    }

    // --- File Library ---

    private FileCategoryFilter GetFileFilter()
    {
        if (FilterMediaRadio.IsChecked == true) return FileCategoryFilter.VideoAudio;
        if (FilterShotRadio.IsChecked == true) return FileCategoryFilter.Screenshots;
        return FileCategoryFilter.All;
    }

    private void FileFilter_Changed(object sender, RoutedEventArgs e)
    {
        if (IsLoaded) RefreshFiles();
    }

    private void RefreshFiles_Click(object sender, RoutedEventArgs e) => RefreshFiles();

    private void RefreshFiles()
    {
        FilesListBox.ItemsSource = _recorder.LoadFiles(GetFileFilter());
    }

    private void OpenOutputFolder_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(_recorder.OutputDirectory);
        Process.Start(new ProcessStartInfo("explorer.exe", _recorder.OutputDirectory) { UseShellExecute = true });
    }

    private void FilesListBox_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (FilesListBox.SelectedItem is RecordedFileItem item && File.Exists(item.FullPath))
        {
            Process.Start(new ProcessStartInfo(item.FullPath) { UseShellExecute = true });
        }
    }

    private void OpenFileItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string path && File.Exists(path))
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
    }

    private void DeleteFileItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string path && File.Exists(path))
        {
            try
            {
                File.Delete(path);
                RefreshFiles();
                SetStatus($"已刪除：{Path.GetFileName(path)}");
            }
            catch (Exception ex)
            {
                SetStatus($"❌ 刪除失敗：{ex.Message}");
            }
        }
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        _uiTimer.Stop();
        _hotkeys.Dispose();
        _recorder.Dispose();
        HideRegionOverlay();
        foreach (var pin in _pinWindows.ToList())
        {
            pin.Close();
        }
    }
}
