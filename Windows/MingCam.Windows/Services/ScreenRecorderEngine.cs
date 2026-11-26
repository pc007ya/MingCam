using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using MingCam.Windows.Interop;
using MingCam.Windows.Models;

namespace MingCam.Windows.Services;

public sealed class ScreenRecorderEngine : IDisposable
{
    public string OutputDirectory { get; }

    public RecordingStatus Status { get; private set; } = RecordingStatus.Idle;
    public TimeSpan Elapsed { get; private set; } = TimeSpan.Zero;
    public string LastError { get; private set; } = string.Empty;

    public event Action? StateChanged;
    public event Action<string>? RecordingSaved;

    private MediaFoundationWriter? _writer;
    private AudioCaptureMixer? _audioMixer;
    private CancellationTokenSource? _cts;
    private Task? _videoTask;
    private string _currentOutputPath = string.Empty;

    private readonly Stopwatch _clock = new();
    private volatile bool _isPaused;

    public ScreenRecorderEngine()
    {
        string videos = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
        OutputDirectory = Path.Combine(videos, "MingCam");
        Directory.CreateDirectory(OutputDirectory);
    }

    public bool StartRecording(
        CaptureMode mode,
        int fps,
        bool captureSystemAudio,
        bool captureMic,
        MonitorTargetItem? selectedMonitor,
        WindowTargetItem? selectedWindow,
        NativeMethods.RECT regionRect)
    {
        if (Status != RecordingStatus.Idle)
            return false;

        LastError = string.Empty;
        bool isAudioOnly = mode == CaptureMode.AudioOnly;
        bool enableAudio = isAudioOnly || captureSystemAudio || captureMic;

        if (isAudioOnly && !captureSystemAudio && !captureMic)
        {
            captureSystemAudio = true;
            enableAudio = true;
        }

        int captureLeft = 0, captureTop = 0, captureWidth = 0, captureHeight = 0;
        IntPtr targetWindowHwnd = IntPtr.Zero;

        if (!isAudioOnly)
        {
            switch (mode)
            {
                case CaptureMode.FullScreen:
                    if (selectedMonitor != null)
                    {
                        captureLeft = selectedMonitor.Left;
                        captureTop = selectedMonitor.Top;
                        captureWidth = selectedMonitor.Width;
                        captureHeight = selectedMonitor.Height;
                    }
                    else
                    {
                        captureLeft = NativeMethods.GetSystemMetrics(NativeMethods.SM_XVIRTUALSCREEN);
                        captureTop = NativeMethods.GetSystemMetrics(NativeMethods.SM_YVIRTUALSCREEN);
                        captureWidth = NativeMethods.GetSystemMetrics(NativeMethods.SM_CXVIRTUALSCREEN);
                        captureHeight = NativeMethods.GetSystemMetrics(NativeMethods.SM_CYVIRTUALSCREEN);
                    }
                    break;

                case CaptureMode.Region:
                    captureLeft = regionRect.Left;
                    captureTop = regionRect.Top;
                    captureWidth = regionRect.Width;
                    captureHeight = regionRect.Height;
                    break;

                case CaptureMode.Window:
                    if (selectedWindow == null || selectedWindow.Handle == IntPtr.Zero)
                    {
                        LastError = "請先選擇要錄製的視窗。";
                        StateChanged?.Invoke();
                        return false;
                    }
                    targetWindowHwnd = selectedWindow.Handle;
                    var wRect = NativeMethods.GetAccurateWindowRect(targetWindowHwnd);
                    captureLeft = wRect.Left;
                    captureTop = wRect.Top;
                    captureWidth = wRect.Width;
                    captureHeight = wRect.Height;
                    break;
            }

            if (captureWidth < 32 || captureHeight < 32)
            {
                LastError = "擷取範圍過小，無法開始錄影。";
                StateChanged?.Invoke();
                return false;
            }
        }

        string timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        string ext = isAudioOnly ? ".m4a" : ".mp4";
        string prefix = isAudioOnly ? "MingCam_Audio_" : "MingCam_";
        _currentOutputPath = Path.Combine(OutputDirectory, $"{prefix}{timestamp}{ext}");

        try
        {
            _writer = new MediaFoundationWriter(
                _currentOutputPath,
                enableVideo: !isAudioOnly,
                width: captureWidth,
                height: captureHeight,
                fps: fps,
                enableAudio: enableAudio);

            _isPaused = false;
            _clock.Restart();
            Elapsed = TimeSpan.Zero;
            Status = RecordingStatus.Recording;

            if (enableAudio)
            {
                _audioMixer = new AudioCaptureMixer(
                    captureSystemAudio,
                    captureMic,
                    () => _isPaused,
                    (pcm, count, ts, dur) => _writer?.WriteAudioSample(pcm, count, ts, dur));
                _audioMixer.Start();
            }

            _cts = new CancellationTokenSource();
            if (!isAudioOnly)
            {
                int w = _writer.VideoWidth;
                int h = _writer.VideoHeight;
                _videoTask = Task.Run(() => VideoCaptureLoop(
                    mode, targetWindowHwnd, captureLeft, captureTop, w, h, fps, _cts.Token));
            }
            else
            {
                _videoTask = Task.Run(() => AudioTimerLoop(_cts.Token));
            }

            StateChanged?.Invoke();
            return true;
        }
        catch (Exception ex)
        {
            LastError = $"啟動錄影失敗：{ex.Message}";
            CleanupInternal();
            Status = RecordingStatus.Idle;
            StateChanged?.Invoke();
            return false;
        }
    }

    public void TogglePause()
    {
        if (Status == RecordingStatus.Recording)
        {
            _isPaused = true;
            _clock.Stop();
            Status = RecordingStatus.Paused;
            StateChanged?.Invoke();
        }
        else if (Status == RecordingStatus.Paused)
        {
            _isPaused = false;
            _clock.Start();
            Status = RecordingStatus.Recording;
            StateChanged?.Invoke();
        }
    }

    public async Task StopRecordingAsync()
    {
        if (Status is RecordingStatus.Idle or RecordingStatus.Stopping)
            return;

        Status = RecordingStatus.Stopping;
        StateChanged?.Invoke();

        string savedPath = _currentOutputPath;
        await Task.Run(() =>
        {
            _cts?.Cancel();
            try { _videoTask?.Wait(1500); } catch { }
            CleanupInternal();
        });

        _clock.Reset();
        Elapsed = TimeSpan.Zero;
        Status = RecordingStatus.Idle;
        StateChanged?.Invoke();

        if (!string.IsNullOrEmpty(savedPath) && File.Exists(savedPath))
        {
            RecordingSaved?.Invoke(savedPath);
        }
    }

    private void AudioTimerLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            Elapsed = _clock.Elapsed;
            Thread.Sleep(200);
        }
    }

    private void VideoCaptureLoop(
        CaptureMode mode,
        IntPtr targetHwnd,
        int left,
        int top,
        int width,
        int height,
        int fps,
        CancellationToken token)
    {
        long frameDurationHns = 10_000_000L / fps;
        double frameIntervalMs = 1000.0 / fps;
        int stride = width * 4;
        int bufferSize = stride * height;
        byte[] pixelBuffer = new byte[bufferSize];

        var bmi = new NativeMethods.BITMAPINFO
        {
            bmiHeader = new NativeMethods.BITMAPINFOHEADER
            {
                biSize = (uint)Marshal.SizeOf<NativeMethods.BITMAPINFOHEADER>(),
                biWidth = width,
                biHeight = -height, // Top-down RGB32 matching Media Foundation positive stride
                biPlanes = 1,
                biBitCount = 32,
                biCompression = NativeMethods.BI_RGB,
                biSizeImage = (uint)bufferSize
            }
        };

        IntPtr desktopDc = NativeMethods.GetDC(IntPtr.Zero);
        IntPtr memDc = NativeMethods.CreateCompatibleDC(desktopDc);
        IntPtr hBitmap = NativeMethods.CreateCompatibleBitmap(desktopDc, width, height);
        IntPtr oldObj = NativeMethods.SelectObject(memDc, hBitmap);

        GCHandle pinned = GCHandle.Alloc(pixelBuffer, GCHandleType.Pinned);
        IntPtr bufferPtr = pinned.AddrOfPinnedObject();

        long frameIndex = 0;
        var pacingWatch = Stopwatch.StartNew();

        try
        {
            while (!token.IsCancellationRequested)
            {
                Elapsed = _clock.Elapsed;

                if (_isPaused)
                {
                    Thread.Sleep(30);
                    pacingWatch.Restart();
                    continue;
                }

                double loopStartMs = pacingWatch.Elapsed.TotalMilliseconds;

                int srcX = left;
                int srcY = top;
                bool captured = false;

                if (mode == CaptureMode.Window && targetHwnd != IntPtr.Zero)
                {
                    var wRect = NativeMethods.GetAccurateWindowRect(targetHwnd);
                    srcX = wRect.Left;
                    srcY = wRect.Top;
                    captured = NativeMethods.PrintWindow(targetHwnd, memDc, NativeMethods.PW_RENDERFULLCONTENT);
                }

                if (!captured)
                {
                    NativeMethods.BitBlt(
                        memDc, 0, 0, width, height,
                        desktopDc, srcX, srcY,
                        NativeMethods.SRCCOPY | NativeMethods.CAPTUREBLT);
                }

                NativeMethods.GetDIBits(
                    memDc, hBitmap, 0, (uint)height,
                    bufferPtr, ref bmi, NativeMethods.DIB_RGB_COLORS);

                long timestampHns = frameIndex * frameDurationHns;
                _writer?.WriteVideoFrame(pixelBuffer, bufferSize, timestampHns, frameDurationHns);
                frameIndex++;

                double elapsedThisFrame = pacingWatch.Elapsed.TotalMilliseconds - loopStartMs;
                int sleepMs = (int)(frameIntervalMs - elapsedThisFrame);
                if (sleepMs > 1)
                {
                    Thread.Sleep(sleepMs);
                }
            }
        }
        catch (Exception ex)
        {
            LastError = $"VideoCaptureLoop error: {ex.Message}";
        }
        finally
        {
            pinned.Free();
            NativeMethods.SelectObject(memDc, oldObj);
            NativeMethods.DeleteObject(hBitmap);
            NativeMethods.DeleteDC(memDc);
            NativeMethods.ReleaseDC(IntPtr.Zero, desktopDc);
        }
    }

    private void CleanupInternal()
    {
        try { _audioMixer?.Dispose(); } catch { }
        _audioMixer = null;

        try { _writer?.Dispose(); } catch { }
        _writer = null;

        try { _cts?.Dispose(); } catch { }
        _cts = null;
    }

    public List<RecordedFileItem> LoadFiles(FileCategoryFilter filter)
    {
        if (!Directory.Exists(OutputDirectory))
            return new List<RecordedFileItem>();

        var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { ".mp4", ".m4a", ".wav", ".png", ".jpg", ".jpeg" };

        var items = new DirectoryInfo(OutputDirectory)
            .GetFiles()
            .Where(f => allowed.Contains(f.Extension))
            .OrderByDescending(f => f.CreationTime)
            .Select(f => new RecordedFileItem
            {
                FullPath = f.FullName,
                Name = f.Name,
                FileSizeString = FormatFileSize(f.Length),
                CreatedAt = f.CreationTime
            });

        return filter switch
        {
            FileCategoryFilter.VideoAudio => items.Where(i => !i.IsScreenshot).ToList(),
            FileCategoryFilter.Screenshots => items.Where(i => i.IsScreenshot).ToList(),
            _ => items.ToList()
        };
    }

    public static string FormatFileSize(long bytes)
    {
        if (bytes >= 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024 * 1024):0.00} GB";
        if (bytes >= 1024L * 1024) return $"{bytes / (1024.0 * 1024):0.0} MB";
        if (bytes >= 1024L) return $"{bytes / 1024.0:0.0} KB";
        return $"{bytes} B";
    }

    public void Dispose()
    {
        _cts?.Cancel();
        CleanupInternal();
    }
}
