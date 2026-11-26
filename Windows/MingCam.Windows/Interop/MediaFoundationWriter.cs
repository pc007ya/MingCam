using System;
using System.Runtime.InteropServices;
using NAudio.MediaFoundation;

namespace MingCam.Windows.Interop;

/// <summary>
/// Native Windows Media Foundation writer producing H.264 .mp4 (with optional AAC audio)
/// or pure AAC .m4a without any external FFmpeg installation.
/// </summary>
internal sealed class MediaFoundationWriter : IDisposable
{
    private static readonly Guid MFMediaType_Video = new("73646976-0000-0010-8000-00AA00389B71");
    private static readonly Guid MFMediaType_Audio = new("73647561-0000-0010-8000-00AA00389B71");
    private static readonly Guid MFVideoFormat_H264 = new("34363248-0000-0010-8000-00AA00389B71");
    private static readonly Guid MFVideoFormat_RGB32 = new("00000016-0000-0010-8000-00AA00389B71");
    private static readonly Guid MFAudioFormat_AAC = new("00001610-0000-0010-8000-00AA00389B71");
    private static readonly Guid MFAudioFormat_PCM = new("00000001-0000-0010-8000-00AA00389B71");

    private static readonly Guid MF_MT_AVG_BITRATE = new("20332624-FB0D-4D9E-BD0D-CBF6786C102E");
    private static readonly Guid MF_MT_INTERLACE_MODE = new("E2724BB8-E676-4806-B4B2-A8D6EFB44CCD");
    private static readonly Guid MF_MT_FRAME_SIZE = new("1652C33D-D6B2-4012-B834-72030849A37D");
    private static readonly Guid MF_MT_FRAME_RATE = new("C459A2E8-3D2C-4E44-B132-FEE5156C7BB0");
    private static readonly Guid MF_MT_PIXEL_ASPECT_RATIO = new("C6376A1E-8D0A-4027-BE45-6D9A0AD39BB6");
    private static readonly Guid MF_MT_DEFAULT_STRIDE = new("644B4E48-1E02-4516-B0EB-C01CA9D49AC6");
    private static readonly Guid MF_MT_AAC_PAYLOAD_TYPE = new("BFBABE79-7434-4D1C-94F0-72A3B9E17188");
    private static readonly Guid MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION = new("7632F0E6-9538-4D61-ACDA-EA29C8C14456");

    private const int MFVideoInterlace_Progressive = 2;

    private readonly object _syncLock = new();
    private IMFSinkWriter? _sinkWriter;
    private int _videoStreamIndex = -1;
    private int _audioStreamIndex = -1;
    private bool _isFinalized;
    private bool _disposed;

    public int VideoWidth { get; }
    public int VideoHeight { get; }
    public int Fps { get; }
    public bool HasVideo => _videoStreamIndex >= 0;
    public bool HasAudio => _audioStreamIndex >= 0;

    [DllImport("mfplat.dll", ExactSpelling = true, PreserveSig = false)]
    private static extern void MFCreateMediaType(out IMFMediaType ppMFType);

    [DllImport("mfplat.dll", ExactSpelling = true, PreserveSig = false)]
    private static extern void MFCreateMemoryBuffer(int cbMaxLength, out IMFMediaBuffer ppBuffer);

    [DllImport("mfplat.dll", ExactSpelling = true, PreserveSig = false)]
    private static extern void MFCreateSample(out IMFSample ppIMFSample);

    public MediaFoundationWriter(
        string outputPath,
        bool enableVideo,
        int width,
        int height,
        int fps,
        bool enableAudio,
        int audioSampleRate = 48000,
        int audioChannels = 2)
    {
        MediaFoundationApi.Startup();

        // H.264 requires even width and height
        VideoWidth = enableVideo ? Math.Max(2, width & ~1) : 0;
        VideoHeight = enableVideo ? Math.Max(2, height & ~1) : 0;
        Fps = Math.Max(1, fps);

        MediaFoundationInterop.MFCreateSinkWriterFromURL(outputPath, null, null, out _sinkWriter);

        if (enableVideo)
        {
            ConfigureVideoStream(VideoWidth, VideoHeight, Fps);
        }

        if (enableAudio)
        {
            ConfigureAudioStream(audioSampleRate, audioChannels);
        }

        _sinkWriter!.BeginWriting();
    }

    private void ConfigureVideoStream(int width, int height, int fps)
    {
        MFCreateMediaType(out IMFMediaType outType);
        outType.SetGUID(MediaFoundationAttributes.MF_MT_MAJOR_TYPE, MFMediaType_Video);
        outType.SetGUID(MediaFoundationAttributes.MF_MT_SUBTYPE, MFVideoFormat_H264);
        outType.SetUINT32(MF_MT_AVG_BITRATE, CalculateBitrate(width, height, fps));
        outType.SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        outType.SetUINT64(MF_MT_FRAME_SIZE, PackUint64((uint)width, (uint)height));
        outType.SetUINT64(MF_MT_FRAME_RATE, PackUint64((uint)fps, 1));
        outType.SetUINT64(MF_MT_PIXEL_ASPECT_RATIO, PackUint64(1, 1));

        _sinkWriter!.AddStream(outType, out _videoStreamIndex);
        Marshal.ReleaseComObject(outType);

        MFCreateMediaType(out IMFMediaType inType);
        inType.SetGUID(MediaFoundationAttributes.MF_MT_MAJOR_TYPE, MFMediaType_Video);
        inType.SetGUID(MediaFoundationAttributes.MF_MT_SUBTYPE, MFVideoFormat_RGB32);
        inType.SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        inType.SetUINT64(MF_MT_FRAME_SIZE, PackUint64((uint)width, (uint)height));
        inType.SetUINT64(MF_MT_FRAME_RATE, PackUint64((uint)fps, 1));
        inType.SetUINT64(MF_MT_PIXEL_ASPECT_RATIO, PackUint64(1, 1));
        inType.SetUINT32(MF_MT_DEFAULT_STRIDE, width * 4);

        _sinkWriter.SetInputMediaType(_videoStreamIndex, inType, null);
        Marshal.ReleaseComObject(inType);
    }

    private void ConfigureAudioStream(int sampleRate, int channels)
    {
        MFCreateMediaType(out IMFMediaType outType);
        outType.SetGUID(MediaFoundationAttributes.MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        outType.SetGUID(MediaFoundationAttributes.MF_MT_SUBTYPE, MFAudioFormat_AAC);
        outType.SetUINT32(MediaFoundationAttributes.MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        outType.SetUINT32(MediaFoundationAttributes.MF_MT_AUDIO_SAMPLES_PER_SECOND, sampleRate);
        outType.SetUINT32(MediaFoundationAttributes.MF_MT_AUDIO_NUM_CHANNELS, channels);
        outType.SetUINT32(MediaFoundationAttributes.MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 24000); // 192 kbps
        outType.SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
        outType.SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);

        _sinkWriter!.AddStream(outType, out _audioStreamIndex);
        Marshal.ReleaseComObject(outType);

        int blockAlign = channels * 2;
        MFCreateMediaType(out IMFMediaType inType);
        inType.SetGUID(MediaFoundationAttributes.MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        inType.SetGUID(MediaFoundationAttributes.MF_MT_SUBTYPE, MFAudioFormat_PCM);
        inType.SetUINT32(MediaFoundationAttributes.MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        inType.SetUINT32(MediaFoundationAttributes.MF_MT_AUDIO_SAMPLES_PER_SECOND, sampleRate);
        inType.SetUINT32(MediaFoundationAttributes.MF_MT_AUDIO_NUM_CHANNELS, channels);
        inType.SetUINT32(MediaFoundationAttributes.MF_MT_AUDIO_BLOCK_ALIGNMENT, blockAlign);
        inType.SetUINT32(MediaFoundationAttributes.MF_MT_AUDIO_AVG_BYTES_PER_SECOND, sampleRate * blockAlign);

        _sinkWriter.SetInputMediaType(_audioStreamIndex, inType, null);
        Marshal.ReleaseComObject(inType);
    }

    public void WriteVideoFrame(byte[] bgraBuffer, int byteCount, long timestampHns, long durationHns)
    {
        lock (_syncLock)
        {
            if (_disposed || _isFinalized || _sinkWriter == null || _videoStreamIndex < 0)
                return;

            WriteSampleInternal(_videoStreamIndex, bgraBuffer, byteCount, timestampHns, durationHns);
        }
    }

    public void WriteAudioSample(byte[] pcmBuffer, int byteCount, long timestampHns, long durationHns)
    {
        lock (_syncLock)
        {
            if (_disposed || _isFinalized || _sinkWriter == null || _audioStreamIndex < 0 || byteCount <= 0)
                return;

            WriteSampleInternal(_audioStreamIndex, pcmBuffer, byteCount, timestampHns, durationHns);
        }
    }

    private void WriteSampleInternal(int streamIndex, byte[] data, int byteCount, long timestampHns, long durationHns)
    {
        MFCreateMemoryBuffer(byteCount, out IMFMediaBuffer buffer);
        IMFSample? sample = null;
        try
        {
            buffer.Lock(out IntPtr destPtr, out _, out _);
            try
            {
                Marshal.Copy(data, 0, destPtr, byteCount);
            }
            finally
            {
                buffer.Unlock();
            }

            buffer.SetCurrentLength(byteCount);

            MFCreateSample(out sample);
            sample!.AddBuffer(buffer);
            sample.SetSampleTime(timestampHns);
            sample.SetSampleDuration(durationHns);

            _sinkWriter!.WriteSample(streamIndex, sample);
        }
        finally
        {
            if (sample != null) Marshal.ReleaseComObject(sample);
            Marshal.ReleaseComObject(buffer);
        }
    }

    public void FinalizeRecording()
    {
        lock (_syncLock)
        {
            if (_isFinalized || _sinkWriter == null)
                return;

            _isFinalized = true;
            try
            {
                _sinkWriter.DoFinalize();
            }
            catch
            {
                // Best effort finalization if no samples were written
            }
        }
    }

    public void Dispose()
    {
        lock (_syncLock)
        {
            if (_disposed)
                return;

            FinalizeRecording();
            if (_sinkWriter != null)
            {
                Marshal.ReleaseComObject(_sinkWriter);
                _sinkWriter = null;
            }
            _disposed = true;
        }
    }

    private static int CalculateBitrate(int width, int height, int fps)
    {
        long pixelsPerSec = (long)width * height * fps;
        long bitrate = Math.Clamp(pixelsPerSec / 12, 2_500_000, 16_000_000);
        return (int)bitrate;
    }

    private static long PackUint64(uint high, uint low)
    {
        return unchecked((long)(((ulong)high << 32) | low));
    }
}
