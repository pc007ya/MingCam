using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace MingCam.Windows.Services;

/// <summary>
/// Captures Windows system audio (WASAPI Loopback) and/or microphone (WASAPI Capture),
/// resamples and mixes into 48kHz 16-bit stereo PCM, and emits steady 20ms chunks.
/// </summary>
internal sealed class AudioCaptureMixer : IDisposable
{
    public const int TargetSampleRate = 48000;
    public const int TargetChannels = 2;

    private readonly bool _captureSystemAudio;
    private readonly bool _captureMic;
    private readonly Action<byte[], int, long, long> _onPcmChunk;
    private readonly Func<bool> _isPaused;

    private WasapiLoopbackCapture? _loopback;
    private WasapiCapture? _mic;
    private BufferedWaveProvider? _loopbackBuffer;
    private BufferedWaveProvider? _micBuffer;
    private WaveOutEvent? _silencePlayer;

    private CancellationTokenSource? _cts;
    private Task? _pumpTask;
    private long _audioTimestampHns;

    public AudioCaptureMixer(
        bool captureSystemAudio,
        bool captureMic,
        Func<bool> isPaused,
        Action<byte[], int, long, long> onPcmChunk)
    {
        _captureSystemAudio = captureSystemAudio;
        _captureMic = captureMic;
        _isPaused = isPaused;
        _onPcmChunk = onPcmChunk;
    }

    public void Start()
    {
        var inputs = new List<ISampleProvider>();

        if (_captureSystemAudio)
        {
            try
            {
                _loopback = new WasapiLoopbackCapture();
                _loopbackBuffer = new BufferedWaveProvider(_loopback.WaveFormat)
                {
                    DiscardOnBufferOverflow = true,
                    ReadFully = true
                };
                _loopback.DataAvailable += (_, e) =>
                {
                    if (!_isPaused() && e.BytesRecorded > 0)
                    {
                        _loopbackBuffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
                    }
                };
                inputs.Add(NormalizeToTarget(_loopbackBuffer));
                _loopback.StartRecording();
            }
            catch
            {
                // System has no active render endpoint
            }
        }

        if (_captureMic)
        {
            try
            {
                _mic = new WasapiCapture();
                _micBuffer = new BufferedWaveProvider(_mic.WaveFormat)
                {
                    DiscardOnBufferOverflow = true,
                    ReadFully = true
                };
                _mic.DataAvailable += (_, e) =>
                {
                    if (!_isPaused() && e.BytesRecorded > 0)
                    {
                        _micBuffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
                    }
                };
                inputs.Add(NormalizeToTarget(_micBuffer));
                _mic.StartRecording();
            }
            catch
            {
                // System has no microphone
            }
        }

        var mixer = new MixingSampleProvider(WaveFormat.CreateIeeeFloatWaveFormat(TargetSampleRate, TargetChannels))
        {
            ReadFully = true
        };
        foreach (var input in inputs)
        {
            mixer.AddMixerInput(input);
        }

        var pcm16Provider = new SampleToWaveProvider16(mixer);

        _cts = new CancellationTokenSource();
        _pumpTask = Task.Run(() => PumpLoop(pcm16Provider, _cts.Token));
    }

    private static ISampleProvider NormalizeToTarget(IWaveProvider source)
    {
        ISampleProvider sample = source.ToSampleProvider();

        if (sample.WaveFormat.Channels == 1)
        {
            sample = new MonoToStereoSampleProvider(sample);
        }
        else if (sample.WaveFormat.Channels > 2)
        {
            // Downmix multi-channel to stereo
            var mux = new MultiplexingSampleProvider(new[] { sample }, 2);
            mux.ConnectInputToOutput(0, 0);
            mux.ConnectInputToOutput(1, 1);
            sample = mux;
        }

        if (sample.WaveFormat.SampleRate != TargetSampleRate)
        {
            sample = new WdlResamplingSampleProvider(sample, TargetSampleRate);
        }

        return sample;
    }

    private void PumpLoop(IWaveProvider pcm16Provider, CancellationToken token)
    {
        // 20ms chunk at 48kHz stereo 16-bit = 48000 * 0.02 * 2 * 2 = 3840 bytes
        const int chunkMs = 20;
        const int chunkBytes = TargetSampleRate * chunkMs / 1000 * TargetChannels * 2;
        const long chunkDurationHns = chunkMs * 10_000L;

        byte[] buffer = new byte[chunkBytes];

        while (!token.IsCancellationRequested)
        {
            if (_isPaused())
            {
                Thread.Sleep(chunkMs);
                continue;
            }

            int read = pcm16Provider.Read(buffer, 0, chunkBytes);
            if (read > 0)
            {
                long ts = _audioTimestampHns;
                _audioTimestampHns += chunkDurationHns;
                _onPcmChunk(buffer, read, ts, chunkDurationHns);
            }

            Thread.Sleep(chunkMs);
        }
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _pumpTask?.Wait(500); } catch { }

        try { _loopback?.StopRecording(); } catch { }
        try { _mic?.StopRecording(); } catch { }
        try { _silencePlayer?.Stop(); } catch { }
    }

    public void Dispose()
    {
        Stop();
        _loopback?.Dispose();
        _mic?.Dispose();
        _silencePlayer?.Dispose();
        _cts?.Dispose();
    }
}
