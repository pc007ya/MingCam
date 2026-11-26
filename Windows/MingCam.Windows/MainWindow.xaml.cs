using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;

namespace MingCam.Windows;

public partial class MainWindow : Window
{
    private const int TestHotkeyId = 9001;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        bool isAdmin = CheckIsAdministrator();
        string osDesc = RuntimeInformation.OSDescription;
        string arch = RuntimeInformation.ProcessArchitecture.ToString();
        string exePath = Environment.ProcessPath ?? AppContext.BaseDirectory;

        SystemInfoText.Text =
            $"OS: {osDesc} ({arch}) | 權限: {(isAdmin ? "系統管理員" : "標準使用者 (無需 UAC)")}\n" +
            $"路徑: {exePath}";

        AppendLog("✅ MingCam.exe 啟動成功！（未被 AppLocker / WDAC 阻擋）");
        AppendLog($"   OS: {osDesc} ({arch})");
        AppendLog($"   Runtime: {RuntimeInformation.FrameworkDescription}");
        AppendLog($"   權限模式: {(isAdmin ? "Administrator" : "Standard User (asInvoker)")}");
        AppendLog("------------------------------------------------------------");
        AppendLog("點擊「▶ 一鍵執行全部檢測」以測試 MingCam 所需的全部 Windows 權限。");
    }

    private static bool CheckIsAdministrator()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    private void AppendLog(string message)
    {
        string timestamp = DateTime.Now.ToString("HH:mm:ss");
        LogTextBox.AppendText($"[{timestamp}] {message}{Environment.NewLine}");
        LogTextBox.ScrollToEnd();
    }

    private void RunAllTests_Click(object sender, RoutedEventArgs e)
    {
        AppendLog("▶ 開始執行全部環境檢測...");
        RunHotkeyTest();
        RunCaptureTest();
        RunOverlayTest();
        RunFileWriteTest();
        AppendLog("🏁 全部檢測完成！");
    }

    private void TestHotkey_Click(object sender, RoutedEventArgs e) => RunHotkeyTest();
    private void TestCapture_Click(object sender, RoutedEventArgs e) => RunCaptureTest();
    private void TestOverlay_Click(object sender, RoutedEventArgs e) => RunOverlayTest();
    private void TestFileWrite_Click(object sender, RoutedEventArgs e) => RunFileWriteTest();

    private void RunHotkeyTest()
    {
        try
        {
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            bool registered = NativeMethods.RegisterHotKey(
                hwnd,
                TestHotkeyId,
                NativeMethods.MOD_CONTROL | NativeMethods.MOD_SHIFT,
                NativeMethods.VK_F9);

            if (registered)
            {
                NativeMethods.UnregisterHotKey(hwnd, TestHotkeyId);
                AppendLog("✅ [全域快捷鍵] RegisterHotKey (Ctrl+Shift+F9) 成功！");
            }
            else
            {
                int err = Marshal.GetLastWin32Error();
                AppendLog($"⚠️ [全域快捷鍵] RegisterHotKey 失敗 (Win32 Error {err}，可能被其他軟體佔用或受限)");
            }
        }
        catch (Exception ex)
        {
            AppendLog($"❌ [全域快捷鍵] 發生例外：{ex.Message}");
        }
    }

    private void RunCaptureTest()
    {
        IntPtr desktopHwnd = IntPtr.Zero;
        IntPtr srcDc = IntPtr.Zero;
        IntPtr memDc = IntPtr.Zero;
        IntPtr hBitmap = IntPtr.Zero;
        IntPtr oldObj = IntPtr.Zero;

        try
        {
            const int width = 480;
            const int height = 300;

            desktopHwnd = NativeMethods.GetDesktopWindow();
            srcDc = NativeMethods.GetWindowDC(desktopHwnd);
            memDc = NativeMethods.CreateCompatibleDC(srcDc);
            hBitmap = NativeMethods.CreateCompatibleBitmap(srcDc, width, height);
            oldObj = NativeMethods.SelectObject(memDc, hBitmap);

            bool ok = NativeMethods.BitBlt(
                memDc, 0, 0, width, height,
                srcDc, 0, 0,
                NativeMethods.SRCCOPY | NativeMethods.CAPTUREBLT);

            if (!ok)
            {
                int err = Marshal.GetLastWin32Error();
                AppendLog($"❌ [螢幕擷取] BitBlt 失敗 (Win32 Error {err})");
                return;
            }

            BitmapSource bitmapSource = Imaging.CreateBitmapSourceFromHBitmap(
                hBitmap,
                IntPtr.Zero,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            bitmapSource.Freeze();

            CapturePreviewImage.Source = bitmapSource;
            PreviewPlaceholder.Visibility = Visibility.Collapsed;
            AppendLog($"✅ [螢幕擷取] 成功擷取 {width}×{height} 畫面，請確認右側預覽是否正常（非全黑）！");
        }
        catch (Exception ex)
        {
            AppendLog($"❌ [螢幕擷取] 發生例外：{ex.Message}");
        }
        finally
        {
            if (oldObj != IntPtr.Zero && memDc != IntPtr.Zero)
            {
                NativeMethods.SelectObject(memDc, oldObj);
            }
            if (hBitmap != IntPtr.Zero)
            {
                NativeMethods.DeleteObject(hBitmap);
            }
            if (memDc != IntPtr.Zero)
            {
                NativeMethods.DeleteDC(memDc);
            }
            if (srcDc != IntPtr.Zero)
            {
                NativeMethods.ReleaseDC(desktopHwnd, srcDc);
            }
        }
    }

    private void RunOverlayTest()
    {
        try
        {
            var overlay = new OverlayTestWindow();
            overlay.Show();
            string affinityStatus = overlay.ExcludeFromCaptureSucceeded
                ? "WDA_EXCLUDEFROMCAPTURE 成功（錄影時不會錄到綠框）"
                : "WDA_EXCLUDEFROMCAPTURE 不支援或受限";
            AppendLog($"✅ [置頂穿透框] 已顯示 3 秒綠色中空穿透框｜{affinityStatus}");
        }
        catch (Exception ex)
        {
            AppendLog($"❌ [置頂穿透框] 發生例外：{ex.Message}");
        }
    }

    private void RunFileWriteTest()
    {
        try
        {
            string videosDir = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
            string targetDir = Path.Combine(videosDir, "MingCam");
            Directory.CreateDirectory(targetDir);

            string testFile = Path.Combine(targetDir, ".mingcam_write_test.tmp");
            File.WriteAllText(testFile, $"MingCam write test {DateTime.Now:O}");
            File.Delete(testFile);

            AppendLog($"✅ [檔案寫入] 成功寫入並清理測試檔：{targetDir}");
        }
        catch (Exception ex)
        {
            AppendLog($"❌ [檔案寫入] 失敗：{ex.Message}");
        }
    }

    private void CopyReport_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(LogTextBox.Text);
            AppendLog("📋 已複製檢測報告至剪貼簿！");
        }
        catch (Exception ex)
        {
            AppendLog($"❌ 複製剪貼簿失敗：{ex.Message}");
        }
    }
}
