using System;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace MingCam.Windows.Overlays;

public partial class SnipastePinWindow : Window
{
    private readonly BitmapSource? _image;
    private readonly string? _text;
    private readonly double _baseWidth;
    private readonly double _baseHeight;
    private double _zoom = 1.0;
    private readonly DispatcherTimer _hudTimer;

    public SnipastePinWindow(BitmapSource image)
    {
        InitializeComponent();
        _image = image;
        PinnedImage.Source = image;
        PinnedImage.Visibility = Visibility.Visible;

        double dipW = image.PixelWidth * 96.0 / Math.Max(96.0, image.DpiX);
        double dipH = image.PixelHeight * 96.0 / Math.Max(96.0, image.DpiY);

        double maxW = SystemParameters.PrimaryScreenWidth * 0.7;
        double maxH = SystemParameters.PrimaryScreenHeight * 0.7;
        double scale = Math.Min(1.0, Math.Min(maxW / Math.Max(1, dipW), maxH / Math.Max(1, dipH)));

        _baseWidth = Math.Max(80, dipW * scale);
        _baseHeight = Math.Max(60, dipH * scale);
        Width = _baseWidth + 14;
        Height = _baseHeight + 14;

        _hudTimer = CreateHudTimer();
    }

    public SnipastePinWindow(string text)
    {
        InitializeComponent();
        _text = text;
        PinnedText.Text = text;
        TextContainer.Visibility = Visibility.Visible;
        SizeToContent = SizeToContent.WidthAndHeight;

        Loaded += (_, _) =>
        {
            SizeToContent = SizeToContent.Manual;
        };

        _baseWidth = 320;
        _baseHeight = 140;
        _hudTimer = CreateHudTimer();
    }

    private DispatcherTimer CreateHudTimer()
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(900) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            HudBadge.Visibility = Visibility.Collapsed;
        };
        return timer;
    }

    private void ShowHud(string message)
    {
        HudText.Text = message;
        HudBadge.Visibility = Visibility.Visible;
        _hudTimer.Stop();
        _hudTimer.Start();
    }

    private void Window_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 1 && e.ButtonState == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void Window_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        Close();
    }

    private void Window_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt))
        {
            double delta = e.Delta > 0 ? 0.08 : -0.08;
            Opacity = Math.Clamp(Opacity + delta, 0.2, 1.0);
            ShowHud($"透明度 {(int)Math.Round(Opacity * 100)}%");
            e.Handled = true;
            return;
        }

        if (_image != null)
        {
            double factor = e.Delta > 0 ? 1.1 : 0.9;
            double newZoom = Math.Clamp(_zoom * factor, 0.25, 4.0);
            double ratio = newZoom / _zoom;
            _zoom = newZoom;

            double centerX = Left + Width / 2;
            double centerY = Top + Height / 2;
            Width = _baseWidth * _zoom + 14;
            Height = _baseHeight * _zoom + 14;
            Left = centerX - Width / 2;
            Top = centerY - Height / 2;

            ShowHud($"縮放 {(int)Math.Round(_zoom * 100)}%");
            e.Handled = true;
        }
    }

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Close();
        }
        else if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Control)
        {
            CopyToClipboard();
        }
        else if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control)
        {
            SaveAsPng();
        }
    }

    private void Copy_Click(object sender, RoutedEventArgs e) => CopyToClipboard();
    private void SavePng_Click(object sender, RoutedEventArgs e) => SaveAsPng();

    private void Reset_Click(object sender, RoutedEventArgs e)
    {
        Opacity = 1.0;
        if (_image != null)
        {
            _zoom = 1.0;
            Width = _baseWidth + 14;
            Height = _baseHeight + 14;
        }
        ShowHud("已重設 100%");
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();

    private void CopyToClipboard()
    {
        try
        {
            if (_image != null)
            {
                Clipboard.SetImage(_image);
                ShowHud("已複製圖片");
            }
            else if (_text != null)
            {
                Clipboard.SetText(_text);
                ShowHud("已複製文字");
            }
        }
        catch { }
    }

    private void SaveAsPng()
    {
        if (_image == null) return;
        var dlg = new SaveFileDialog
        {
            Filter = "PNG 圖片 (*.png)|*.png",
            FileName = $"MingCam_Pin_{DateTime.Now:yyyyMMdd_HHmmss}.png"
        };
        if (dlg.ShowDialog() == true)
        {
            using var fs = File.Create(dlg.FileName);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(_image));
            encoder.Save(fs);
            ShowHud("已儲存 PNG");
        }
    }
}
