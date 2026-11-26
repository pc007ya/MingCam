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
    private readonly List<string> _colorHistory = new();

    private bool _isRecorderWorkspace = true;
    private CaptureMode _selectedCaptureMode = CaptureMode.FullScreen;
    private ScreenshotCaptureMode _selectedScreenshotMode = ScreenshotCaptureMode.Region;
    private BitmapSource? _latestCapturedImage;

    private RegionOverlayWindow? _regionOverlay;
    private ScreenshotOverlayWindow? _activeShotOverlay;

    public ScreenRecorderEngine RecorderEngine => _recorder;

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
        OutputFolderLabel.Text = _recorder.OutputDirectory;
        RefreshTargets();
        RefreshFiles();
        ApplyWorkspaceVisuals();
        ApplyCaptureModeVisuals();
        ApplyScreenshotModeVisuals();

        _hotkeys.RegionScreenshotTriggered += () => Dispatcher.Invoke(() => LaunchScreenshotOverlay(colorPickerOnly: false));
        _hotkeys.PinClipboardTriggered += () => Dispatcher.Invoke(PinFromClipboard);
        _hotkeys.ColorPickerTriggered += () => Dispatcher.Invoke(() => LaunchScreenshotOverlay(colorPickerOnly: true));
        _hotkeys.ToggleRecordTriggered += () => Dispatcher.Invoke(ToggleRecordingByHotkey);
        _hotkeys.Attach(this);

        HotkeyStatusText.Text = _hotkeys.StatusSummary;
        SetStatus("MingCam for Windows 已就緒（免安裝 Portable 模式）。");
    }

    private void SetStatus(string msg)
    {
        StatusFooterText.Text = $"[{DateTime.Now:HH:mm:ss}] {msg}";
    }

    // --- Hover Help Banner (Matches macOS hoverFeatureBanner) ---

    private void HoverHelp_Enter(object sender, MouseEventArgs e)
    {
        if (sender is FrameworkElement el && el.Tag is string raw && raw.Contains('|'))
        {
            var parts = raw.Split('|', 2);
            HoverBannerTitle.Text = parts[0];
            HoverBannerTitle.Foreground = new SolidColorBrush(Color.FromRgb(250, 204, 21));
            HoverBannerDetail.Text = parts[1];
            HoverBannerDetail.Foreground = Brushes.White;
            HoverBannerBorder.Background = new SolidColorBrush(Color.FromRgb(34, 38, 52));
        }
    }

    private void HoverHelp_Leave(object sender, MouseEventArgs e)
    {
        HoverBannerTitle.Text = "💡";
        HoverBannerTitle.Foreground = new SolidColorBrush(Color.FromRgb(56, 189, 248));
        HoverBannerDetail.Text = "滑鼠停留在任何按鈕上可即時查看功能說明 ｜ 框選截圖 (F1) · 剪貼簿貼圖 (F3) · 放大鏡取色 (Ctrl+Shift+C) · 錄影 (Ctrl+Shift+R)";
        HoverBannerDetail.Foreground = new SolidColorBrush(Color.FromRgb(184, 193, 206));
        HoverBannerBorder.Background = new SolidColorBrush(Color.FromRgb(28, 33, 43));
    }

    // --- Top Workspace Tabs (Recorder vs Screenshot) ---

    public void SwitchToWorkspace(bool recorderTab)
    {
        _isRecorderWorkspace = recorderTab;
        ApplyWorkspaceVisuals();
    }

    private void TabRecorder_Click(object sender, RoutedEventArgs e) => SwitchToWorkspace(true);
    private void TabScreenshot_Click(object sender, RoutedEventArgs e) => SwitchToWorkspace(false);

    private void ApplyWorkspaceVisuals()
    {
        RecorderModeStrip.Visibility = _isRecorderWorkspace ? Visibility.Visible : Visibility.Collapsed;
        ScreenshotModeStrip.Visibility = _isRecorderWorkspace ? Visibility.Collapsed : Visibility.Visible;

        RecorderLeftCards.Visibility = _isRecorderWorkspace ? Visibility.Visible : Visibility.Collapsed;
        ScreenshotLeftCards.Visibility = _isRecorderWorkspace ? Visibility.Collapsed : Visibility.Visible;
        LatestPreviewCard.Visibility = (!_isRecorderWorkspace && _latestCapturedImage != null)
            ? Visibility.Visible
            : Visibility.Collapsed;

        // Top switcher pill colors (Red for Recorder, Cyan for Screenshot — matching macOS!)
        TabRecorderBtn.Background = _isRecorderWorkspace ? new SolidColorBrush(Color.FromRgb(220, 38, 38)) : Brushes.Transparent;
        TabRecorderBtn.Foreground = _isRecorderWorkspace ? Brushes.White : new SolidColorBrush(Color.FromRgb(180, 188, 200));

        TabScreenshotBtn.Background = !_isRecorderWorkspace ? new SolidColorBrush(Color.FromRgb(6, 182, 212)) : Brushes.Transparent;
        TabScreenshotBtn.Foreground = !_isRecorderWorkspace ? Brushes.Black : new SolidColorBrush(Color.FromRgb(180, 188, 200));

        // Brand badge gradient
        BrandBadgeCircle.Background = _isRecorderWorkspace
            ? new LinearGradientBrush(Color.FromRgb(239, 68, 68), Color.FromRgb(249, 115, 22), 45)
            : new LinearGradientBrush(Color.FromRgb(6, 182, 212), Color.FromRgb(37, 99, 235), 45);
        BrandIconText.Text = _isRecorderWorkspace ? "●" : "⌖";
    }

    // --- Sub-Mode Strips ---

    private void RecorderModeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string tag && Enum.TryParse<CaptureMode>(tag, out var mode))
        {
            _selectedCaptureMode = mode;
            ApplyCaptureModeVisuals();
        }
    }

    private void ApplyCaptureModeVisuals()
    {
        var map = new (Button Btn, CaptureMode Mode)[]
        {
            (ModeFullBtn, CaptureMode.FullScreen),
            (ModeRegionBtn, CaptureMode.Region),
            (ModeWindowBtn, CaptureMode.Window),
            (ModeAudioBtn, CaptureMode.AudioOnly)
        };

        foreach (var (btn, mode) in map)
        {
            bool active = mode == _selectedCaptureMode;
            btn.Background = active ? new SolidColorBrush(Color.FromRgb(42, 47, 62)) : new SolidColorBrush(Color.FromRgb(30, 32, 40));
            btn.BorderBrush = active ? new SolidColorBrush(Color.FromRgb(239, 68, 68)) : new SolidColorBrush(Color.FromRgb(45, 49, 61));
            btn.Foreground = active ? Brushes.White : new SolidColorBrush(Color.FromRgb(180, 188, 200));
            btn.FontWeight = active ? FontWeights.Bold : FontWeights.Medium;
        }

        MonitorPickerRow.Visibility = _selectedCaptureMode == CaptureMode.FullScreen ? Visibility.Visible : Visibility.Collapsed;
        RegionHintRow.Visibility = _selectedCaptureMode == CaptureMode.Region ? Visibility.Visible : Visibility.Collapsed;
        WindowPickerRow.Visibility = _selectedCaptureMode == CaptureMode.Window ? Visibility.Visible : Visibility.Collapsed;
        AudioOnlyHintRow.Visibility = _selectedCaptureMode == CaptureMode.AudioOnly ? Visibility.Visible : Visibility.Collapsed;

        if (_selectedCaptureMode == CaptureMode.Region)
        {
            EnsureRegionOverlayVisible();
        }
        else if (_recorder.Status == RecordingStatus.Idle)
        {
            HideRegionOverlay();
        }
    }

    private void ScreenshotModeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string tag && Enum.TryParse<ScreenshotCaptureMode>(tag, out var mode))
        {
            _selectedScreenshotMode = mode;
            ApplyScreenshotModeVisuals();
        }
    }

    private void ApplyScreenshotModeVisuals()
    {
        var map = new (Button Btn, ScreenshotCaptureMode Mode)[]
        {
            (ShotRegionBtn, ScreenshotCaptureMode.Region),
            (ShotWindowBtn, ScreenshotCaptureMode.Window),
            (ShotFullBtn, ScreenshotCaptureMode.FullScreen),
            (ShotColorBtn, ScreenshotCaptureMode.ColorPicker)
        };

        foreach (var (btn, mode) in map)
        {
            bool active = mode == _selectedScreenshotMode;
            btn.Background = active ? new SolidColorBrush(Color.FromRgb(24, 48, 60)) : new SolidColorBrush(Color.FromRgb(30, 32, 40));
            btn.BorderBrush = active ? new SolidColorBrush(Color.FromRgb(34, 211, 238)) : new SolidColorBrush(Color.FromRgb(45, 49, 61));
            btn.Foreground = active ? Brushes.White : new SolidColorBrush(Color.FromRgb(180, 188, 200));
            btn.FontWeight = active ? FontWeights.Bold : FontWeights.Medium;
        }

        ShotModeDescText.Text = _selectedScreenshotMode switch
        {
            ScreenshotCaptureMode.Region => "框選螢幕範圍後即時浮出 9 種 PicPick 標註工具列，可一鍵釘選貼圖、複製或儲存 PNG (F1)。",
            ScreenshotCaptureMode.Window => "擷取「錄影與錄音」中選擇的目標視窗為高畫質 PNG 並複製到剪貼簿。",
            ScreenshotCaptureMode.FullScreen => "立即將整個螢幕擷取為高畫質 PNG，同時儲存並複製到剪貼簿。",
            ScreenshotCaptureMode.ColorPicker => "啟動像素級游標放大鏡，即時顯示座標與 HEX/RGB 色碼，點擊或按 C 鍵複製。",
            _ => string.Empty
        };
    }

    // --- Recorder Controls ---

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

    private async void RecToggle_Click(object sender, RoutedEventArgs e)
    {
        if (_recorder.Status == RecordingStatus.Idle)
            StartRecording();
        else if (_recorder.Status is RecordingStatus.Recording or RecordingStatus.Paused)
            await StopRecordingAsync();
    }

    private void StartRecording()
    {
        int fps = Fps60Radio.IsChecked == true ? 60 : 30;
        bool sysAudio = SystemAudioCheck.IsChecked == true;
        bool micAudio = MicAudioCheck.IsChecked == true;

        NativeMethods.RECT regionRect = default;
        if (_selectedCaptureMode == CaptureMode.Region)
        {
            EnsureRegionOverlayVisible();
            regionRect = _regionOverlay!.GetCapturePixelRect();
            _regionOverlay.SetRecordingMode(true);
        }

        bool started = _recorder.StartRecording(
            _selectedCaptureMode,
            fps,
            sysAudio,
            micAudio,
            MonitorCombo.SelectedItem as MonitorTargetItem,
            WindowCombo.SelectedItem as WindowTargetItem,
            regionRect);

        if (started)
        {
            _uiTimer.Start();
            SetStatus($"正在錄製 ({_selectedCaptureMode}, {fps} FPS)...");
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

    private void PauseRecord_Click(object sender, RoutedEventArgs e) => _recorder.TogglePause();

    private async Task StopRecordingAsync()
    {
        _uiTimer.Stop();
        await _recorder.StopRecordingAsync();
        _regionOverlay?.SetRecordingMode(false);
    }

    private async void ToggleRecordingByHotkey()
    {
        if (_recorder.Status == RecordingStatus.Idle)
            StartRecording();
        else if (_recorder.Status is RecordingStatus.Recording or RecordingStatus.Paused)
            await StopRecordingAsync();
    }

    private void SyncRecorderUi()
    {
        var st = _recorder.Status;
        bool active = st is RecordingStatus.Recording or RecordingStatus.Paused;

        PauseRecordBtn.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        PauseRecordBtn.Content = st == RecordingStatus.Paused ? "▶" : "⏸";

        RecToggleBtn.Content = st == RecordingStatus.Idle ? "● REC" : "■ STOP";
        RecToggleBtn.Background = st == RecordingStatus.Idle
            ? new LinearGradientBrush(Color.FromRgb(230, 38, 51), Color.FromRgb(191, 20, 31), 90)
            : new SolidColorBrush(Color.FromRgb(100, 116, 139));

        RecTimerLabel.Foreground = st switch
        {
            RecordingStatus.Recording => new SolidColorBrush(Color.FromRgb(248, 113, 113)),
            RecordingStatus.Paused => new SolidColorBrush(Color.FromRgb(250, 204, 21)),
            _ => Brushes.White
        };

        if (st == RecordingStatus.Idle)
        {
            RecTimerLabel.Text = "00:00:00";
        }
    }

    // --- Screenshot, Snipaste Pin & Color History ---

    private void TriggerSelectedShot_Click(object sender, RoutedEventArgs e)
    {
        switch (_selectedScreenshotMode)
        {
            case ScreenshotCaptureMode.Region:
                LaunchScreenshotOverlay(colorPickerOnly: false);
                break;
            case ScreenshotCaptureMode.ColorPicker:
                LaunchScreenshotOverlay(colorPickerOnly: true);
                break;
            case ScreenshotCaptureMode.FullScreen:
            case ScreenshotCaptureMode.Window:
                CaptureFullScreenNow();
                break;
        }
    }

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
            onPin: bmp => Dispatcher.Invoke(() =>
            {
                SetLatestPreview(bmp);
                OpenPinWindow(bmp);
            }),
            onSaved: path => Dispatcher.Invoke(() =>
            {
                try
                {
                    var img = new BitmapImage();
                    img.BeginInit();
                    img.CacheOption = BitmapCacheOption.OnLoad;
                    img.UriSource = new Uri(path);
                    img.EndInit();
                    img.Freeze();
                    SetLatestPreview(img);
                }
                catch { }

                SetStatus($"✅ 截圖已儲存並複製：{Path.GetFileName(path)}");
                RefreshFiles();
            }),
            onToast: msg => Dispatcher.Invoke(() =>
            {
                if (msg.Contains('#'))
                {
                    int hashIdx = msg.IndexOf('#');
                    if (hashIdx + 7 <= msg.Length)
                    {
                        AddColorHistory(msg.Substring(hashIdx, 7));
                    }
                }
                SetStatus(msg);
            }));

        overlay.Closed += (_, _) => _activeShotOverlay = null;
        _activeShotOverlay = overlay;
        overlay.Show();
    }

    public void SetLatestPreview(BitmapSource bmp)
    {
        _latestCapturedImage = bmp;
        LatestPreviewImage.Source = bmp;
        if (!_isRecorderWorkspace)
        {
            LatestPreviewCard.Visibility = Visibility.Visible;
        }
    }

    public void AddColorHistory(string hex)
    {
        hex = hex.ToUpperInvariant();
        _colorHistory.Remove(hex);
        _colorHistory.Insert(0, hex);
        if (_colorHistory.Count > 10) _colorHistory.RemoveAt(_colorHistory.Count - 1);

        ColorHistoryEmptyText.Visibility = _colorHistory.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ColorHistoryPanel.Children.Clear();

        foreach (var h in _colorHistory)
        {
            var btn = new Button
            {
                Margin = new Thickness(0, 0, 6, 6),
                Padding = new Thickness(7, 4, 7, 4),
                Background = new SolidColorBrush(Color.FromRgb(17, 19, 24)),
                BorderBrush = new SolidColorBrush(Color.FromRgb(51, 65, 85)),
                BorderThickness = new Thickness(1),
                Cursor = Cursors.Hand,
                Tag = h
            };
            var sp = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            sp.Children.Add(new Border
            {
                Width = 12,
                Height = 12,
                CornerRadius = new CornerRadius(3),
                Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString(h)),
                Margin = new Thickness(0, 0, 5, 0)
            });
            sp.Children.Add(new TextBlock
            {
                Text = h,
                Foreground = Brushes.White,
                FontFamily = new FontFamily("Consolas"),
                FontSize = 11
            });
            btn.Content = sp;
            btn.Click += (_, _) =>
            {
                try
                {
                    Clipboard.SetText(h);
                    SetStatus($"📋 已複製色碼 {h}");
                }
                catch { }
            };
            ColorHistoryPanel.Children.Add(btn);
        }
    }

    private void CaptureFullScreenNow()
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
                try { Clipboard.SetImage(bmp); } catch { }
                SetLatestPreview(bmp);
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

    private void PinLatestPreview_Click(object sender, RoutedEventArgs e)
    {
        if (_latestCapturedImage != null) OpenPinWindow(_latestCapturedImage);
    }

    private void CopyLatestPreview_Click(object sender, RoutedEventArgs e)
    {
        if (_latestCapturedImage != null)
        {
            try
            {
                Clipboard.SetImage(_latestCapturedImage);
                SetStatus("📋 已複製最新截圖至剪貼簿。");
            }
            catch { }
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
        PinCountBadge.Text = $"目前 {_pinWindows.Count} 張";
    }

    private void CloseAllPins_Click(object sender, RoutedEventArgs e)
    {
        foreach (var pin in _pinWindows.ToList()) pin.Close();
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

    public void RefreshFiles()
    {
        FilesListBox.ItemsSource = _recorder.LoadFiles(GetFileFilter());
    }

    public void PopulateDemoItemsForCapture(List<RecordedFileItem> items)
    {
        FilesListBox.ItemsSource = items;
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
        foreach (var pin in _pinWindows.ToList()) pin.Close();
    }
}
