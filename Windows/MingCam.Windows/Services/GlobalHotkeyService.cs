using System;
using System.Windows;
using System.Windows.Interop;
using MingCam.Windows.Interop;

namespace MingCam.Windows.Services;

public sealed class GlobalHotkeyService : IDisposable
{
    private const int IdRegionScreenshot = 1001;
    private const int IdPinClipboard = 1002;
    private const int IdColorPicker = 1003;
    private const int IdToggleRecord = 1004;

    private HwndSource? _hwndSource;
    private IntPtr _hwnd;
    private bool _registered;

    public event Action? RegionScreenshotTriggered;
    public event Action? PinClipboardTriggered;
    public event Action? ColorPickerTriggered;
    public event Action? ToggleRecordTriggered;

    public string StatusSummary { get; private set; } = "尚未註冊全域快捷鍵";

    public void Attach(Window window)
    {
        var helper = new WindowInteropHelper(window);
        _hwnd = helper.EnsureHandle();
        _hwndSource = HwndSource.FromHwnd(_hwnd);
        _hwndSource?.AddHook(WndProc);
        RegisterAll();
    }

    public void RegisterAll()
    {
        if (_hwnd == IntPtr.Zero) return;
        UnregisterAll();

        int okCount = 0;
        if (NativeMethods.RegisterHotKey(_hwnd, IdRegionScreenshot, NativeMethods.MOD_NOREPEAT, NativeMethods.VK_F1))
            okCount++;
        if (NativeMethods.RegisterHotKey(_hwnd, IdPinClipboard, NativeMethods.MOD_NOREPEAT, NativeMethods.VK_F3))
            okCount++;
        if (NativeMethods.RegisterHotKey(_hwnd, IdColorPicker, NativeMethods.MOD_CONTROL | NativeMethods.MOD_SHIFT | NativeMethods.MOD_NOREPEAT, NativeMethods.VK_C))
            okCount++;
        if (NativeMethods.RegisterHotKey(_hwnd, IdToggleRecord, NativeMethods.MOD_CONTROL | NativeMethods.MOD_SHIFT | NativeMethods.MOD_NOREPEAT, NativeMethods.VK_R))
            okCount++;

        _registered = true;
        StatusSummary = okCount == 4
            ? "全域快捷鍵已啟用（F1 截圖 / F3 貼圖 / Ctrl+Shift+C 取色 / Ctrl+Shift+R 錄影）"
            : $"全域快捷鍵部分啟用（{okCount}/4，部分按鍵可能已被其他軟體佔用）";
    }

    public void UnregisterAll()
    {
        if (_hwnd == IntPtr.Zero || !_registered) return;
        NativeMethods.UnregisterHotKey(_hwnd, IdRegionScreenshot);
        NativeMethods.UnregisterHotKey(_hwnd, IdPinClipboard);
        NativeMethods.UnregisterHotKey(_hwnd, IdColorPicker);
        NativeMethods.UnregisterHotKey(_hwnd, IdToggleRecord);
        _registered = false;
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_HOTKEY)
        {
            int id = wParam.ToInt32();
            switch (id)
            {
                case IdRegionScreenshot:
                    RegionScreenshotTriggered?.Invoke();
                    handled = true;
                    break;
                case IdPinClipboard:
                    PinClipboardTriggered?.Invoke();
                    handled = true;
                    break;
                case IdColorPicker:
                    ColorPickerTriggered?.Invoke();
                    handled = true;
                    break;
                case IdToggleRecord:
                    ToggleRecordTriggered?.Invoke();
                    handled = true;
                    break;
            }
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        UnregisterAll();
        _hwndSource?.RemoveHook(WndProc);
        _hwndSource = null;
    }
}
