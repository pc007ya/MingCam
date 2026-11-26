using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using MingCam.Windows.Interop;
using MingCam.Windows.Models;

namespace MingCam.Windows.Overlays;

public partial class ScreenshotOverlayWindow : Window
{
    private readonly bool _colorPickerOnly;
    private readonly string _outputDirectory;
    private readonly Action<BitmapSource>? _onPin;
    private readonly Action<string>? _onSaved;
    private readonly Action<string>? _onToast;

    private BitmapSource _frozenBitmap = null!;
    private byte[] _pixelData = Array.Empty<byte>();
    private int _pixelStride;
    private int _physWidth;
    private int _physHeight;
    private double _dpiScaleX = 1.0;
    private double _dpiScaleY = 1.0;

    private bool _isSelecting;
    private bool _hasSelection;
    private Point _selectStart;
    private Rect _selectionRect;

    private bool _isDrawingAnnotation;
    private AnnotationTool _activeTool = AnnotationTool.Arrow;
    private Color _activeColor = Color.FromRgb(239, 68, 68);
    private double _activeStrokeWidth = 4.0;
    private int _nextStepNumber = 1;
    private readonly List<AnnotationShape> _shapes = new();
    private AnnotationShape? _currentShape;
    private Point _pendingTextPoint;

    private string _currentHex = "#000000";

    public ScreenshotOverlayWindow(
        bool colorPickerOnly,
        string outputDirectory,
        Action<BitmapSource>? onPin,
        Action<string>? onSaved,
        Action<string>? onToast)
    {
        InitializeComponent();

        _colorPickerOnly = colorPickerOnly;
        _outputDirectory = outputDirectory;
        _onPin = onPin;
        _onSaved = onSaved;
        _onToast = onToast;

        CaptureVirtualDesktop();

        Loaded += OnLoaded;
    }

    private void CaptureVirtualDesktop()
    {
        int vx = NativeMethods.GetSystemMetrics(NativeMethods.SM_XVIRTUALSCREEN);
        int vy = NativeMethods.GetSystemMetrics(NativeMethods.SM_YVIRTUALSCREEN);
        int vw = NativeMethods.GetSystemMetrics(NativeMethods.SM_CXVIRTUALSCREEN);
        int vh = NativeMethods.GetSystemMetrics(NativeMethods.SM_CYVIRTUALSCREEN);

        _physWidth = Math.Max(1, vw);
        _physHeight = Math.Max(1, vh);
        _pixelStride = _physWidth * 4;
        _pixelData = new byte[_pixelStride * _physHeight];

        IntPtr desktopDc = NativeMethods.GetDC(IntPtr.Zero);
        IntPtr memDc = NativeMethods.CreateCompatibleDC(desktopDc);
        IntPtr hBitmap = NativeMethods.CreateCompatibleBitmap(desktopDc, _physWidth, _physHeight);
        IntPtr oldObj = NativeMethods.SelectObject(memDc, hBitmap);

        try
        {
            NativeMethods.BitBlt(
                memDc, 0, 0, _physWidth, _physHeight,
                desktopDc, vx, vy,
                NativeMethods.SRCCOPY | NativeMethods.CAPTUREBLT);

            var bmi = new NativeMethods.BITMAPINFO
            {
                bmiHeader = new NativeMethods.BITMAPINFOHEADER
                {
                    biSize = (uint)Marshal.SizeOf<NativeMethods.BITMAPINFOHEADER>(),
                    biWidth = _physWidth,
                    biHeight = -_physHeight,
                    biPlanes = 1,
                    biBitCount = 32,
                    biCompression = NativeMethods.BI_RGB
                }
            };

            GCHandle handle = GCHandle.Alloc(_pixelData, GCHandleType.Pinned);
            try
            {
                NativeMethods.GetDIBits(memDc, hBitmap, 0, (uint)_physHeight, handle.AddrOfPinnedObject(), ref bmi, NativeMethods.DIB_RGB_COLORS);
            }
            finally
            {
                handle.Free();
            }

            _frozenBitmap = BitmapSource.Create(
                _physWidth, _physHeight, 96, 96,
                PixelFormats.Bgr32, null, _pixelData, _pixelStride);
            _frozenBitmap.Freeze();
        }
        finally
        {
            NativeMethods.SelectObject(memDc, oldObj);
            NativeMethods.DeleteObject(hBitmap);
            NativeMethods.DeleteDC(memDc);
            NativeMethods.ReleaseDC(IntPtr.Zero, desktopDc);
        }

        Left = SystemParameters.VirtualScreenLeft;
        Top = SystemParameters.VirtualScreenTop;
        Width = SystemParameters.VirtualScreenWidth;
        Height = SystemParameters.VirtualScreenHeight;
        FrozenScreenImage.Source = _frozenBitmap;

        if (_colorPickerOnly)
        {
            LoupeHintText.Text = "點擊或按 C 複製色碼 · Esc 取消";
        }
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        var source = PresentationSource.FromVisual(this);
        _dpiScaleX = source?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        _dpiScaleY = source?.CompositionTarget?.TransformToDevice.M22 ?? 1.0;

        UpdateDimMask(Rect.Empty);
        Activate();
        Focus();
    }

    public void SetupDemoAnnotationState()
    {
        double w = Math.Max(800, ActualWidth);
        double h = Math.Max(600, ActualHeight);
        double rx = Math.Round(w * 0.14);
        double ry = Math.Round(h * 0.10);
        double rw = Math.Round(w * 0.72);
        double rh = Math.Round(h * 0.66);

        _selectionRect = new Rect(rx, ry, rw, rh);
        _hasSelection = true;

        Canvas.SetLeft(SelectionBorder, rx);
        Canvas.SetTop(SelectionBorder, ry);
        SelectionBorder.Width = rw;
        SelectionBorder.Height = rh;
        SelectionBorder.Visibility = Visibility.Visible;

        DimensionText.Text = $"{(int)Math.Round(rw * _dpiScaleX)} × {(int)Math.Round(rh * _dpiScaleY)} px";
        Canvas.SetLeft(DimensionBadge, rx);
        Canvas.SetTop(DimensionBadge, Math.Max(4, ry - 28));
        DimensionBadge.Visibility = Visibility.Visible;

        LoupePanel.Visibility = Visibility.Collapsed;
        UpdateDimMask(_selectionRect);

        _shapes.Clear();
        _shapes.Add(new AnnotationShape
        {
            Tool = AnnotationTool.Rectangle,
            Color = Color.FromRgb(56, 189, 248),
            LineWidth = 3,
            Points = new List<Point> { new(rx + 24, ry + 16), new(rx + rw * 0.42, ry + 82) }
        });
        _shapes.Add(new AnnotationShape
        {
            Tool = AnnotationTool.Arrow,
            Color = Color.FromRgb(239, 68, 68),
            LineWidth = 4,
            Points = new List<Point> { new(rx + rw * 0.56, ry + 115), new(rx + rw * 0.74, ry + 56) }
        });
        _shapes.Add(new AnnotationShape
        {
            Tool = AnnotationTool.Counter,
            Color = Color.FromRgb(239, 68, 68),
            LineWidth = 4,
            StepNumber = 1,
            Points = new List<Point> { new(rx + rw * 0.54, ry + 118) }
        });
        _shapes.Add(new AnnotationShape
        {
            Tool = AnnotationTool.Counter,
            Color = Color.FromRgb(239, 68, 68),
            LineWidth = 4,
            StepNumber = 2,
            Points = new List<Point> { new(rx + rw * 0.80, ry + 56) }
        });
        _shapes.Add(new AnnotationShape
        {
            Tool = AnnotationTool.Highlighter,
            Color = Color.FromRgb(234, 179, 8),
            LineWidth = 4,
            Points = new List<Point> { new(rx + 36, ry + 175), new(rx + rw * 0.46, ry + 175) }
        });
        _shapes.Add(new AnnotationShape
        {
            Tool = AnnotationTool.Text,
            Color = Color.FromRgb(239, 68, 68),
            LineWidth = 3,
            Text = "一鍵開始錄影 / 截圖標註",
            Points = new List<Point> { new(rx + rw * 0.50, ry + 145) }
        });

        RedrawAnnotations();
        PositionToolbar();
        AnnotationToolbar.Visibility = Visibility.Visible;
        UpdateLayout();
    }

    private void UpdateDimMask(Rect hole)
    {
        var full = new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight));
        if (hole.IsEmpty || hole.Width < 1 || hole.Height < 1)
        {
            DimMaskPath.Data = _colorPickerOnly ? null : full;
            return;
        }

        var cutout = new RectangleGeometry(hole);
        DimMaskPath.Data = new CombinedGeometry(GeometryCombineMode.Exclude, full, cutout);
    }

    private void UpdateLoupe(Point dipPos)
    {
        if (_hasSelection && !_colorPickerOnly)
        {
            LoupePanel.Visibility = Visibility.Collapsed;
            return;
        }

        LoupePanel.Visibility = Visibility.Visible;

        int px = Math.Clamp((int)Math.Round(dipPos.X * _dpiScaleX), 0, _physWidth - 1);
        int py = Math.Clamp((int)Math.Round(dipPos.Y * _dpiScaleY), 0, _physHeight - 1);

        int idx = py * _pixelStride + px * 4;
        byte b = _pixelData[idx];
        byte g = _pixelData[idx + 1];
        byte r = _pixelData[idx + 2];

        _currentHex = $"#{r:X2}{g:X2}{b:X2}";
        LoupeHexText.Text = _currentHex;
        LoupeRgbText.Text = $"RGB({r}, {g}, {b})  ({px}, {py})";
        LoupeSwatch.Background = new SolidColorBrush(Color.FromRgb(r, g, b));

        int cropSize = 15;
        int cx = Math.Clamp(px - cropSize / 2, 0, Math.Max(0, _physWidth - cropSize));
        int cy = Math.Clamp(py - cropSize / 2, 0, Math.Max(0, _physHeight - cropSize));
        int cw = Math.Min(cropSize, _physWidth - cx);
        int ch = Math.Min(cropSize, _physHeight - cy);
        if (cw > 0 && ch > 0)
        {
            LoupeImage.Source = new CroppedBitmap(_frozenBitmap, new Int32Rect(cx, cy, cw, ch));
        }

        double lx = dipPos.X + 20;
        double ly = dipPos.Y + 20;
        if (lx + 170 > ActualWidth) lx = dipPos.X - 180;
        if (ly + 190 > ActualHeight) ly = dipPos.Y - 195;
        Canvas.SetLeft(LoupePanel, Math.Max(4, lx));
        Canvas.SetTop(LoupePanel, Math.Max(4, ly));
    }

    private void RootGrid_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        Point pos = e.GetPosition(RootGrid);

        if (_colorPickerOnly)
        {
            CopyCurrentColorAndClose();
            return;
        }

        if (!_hasSelection)
        {
            _isSelecting = true;
            _selectStart = pos;
            _selectionRect = new Rect(pos, new Size(0, 0));
            SelectionBorder.Visibility = Visibility.Visible;
            DimensionBadge.Visibility = Visibility.Visible;
            RootGrid.CaptureMouse();
            return;
        }

        // Annotation mode inside selection
        if (!_selectionRect.Contains(pos))
            return;

        CommitInlineTextIfOpen();

        if (_activeTool == AnnotationTool.Counter)
        {
            _shapes.Add(new AnnotationShape
            {
                Tool = AnnotationTool.Counter,
                Points = new List<Point> { pos },
                Color = _activeColor,
                LineWidth = _activeStrokeWidth,
                StepNumber = _nextStepNumber++
            });
            RedrawAnnotations();
            return;
        }

        if (_activeTool == AnnotationTool.Text)
        {
            _pendingTextPoint = pos;
            InlineTextBox.Text = string.Empty;
            InlineTextBox.Foreground = new SolidColorBrush(_activeColor);
            Canvas.SetLeft(InlineTextBox, pos.X);
            Canvas.SetTop(InlineTextBox, pos.Y - 14);
            InlineTextBox.Visibility = Visibility.Visible;
            InlineTextBox.Focus();
            return;
        }

        _isDrawingAnnotation = true;
        _currentShape = new AnnotationShape
        {
            Tool = _activeTool,
            Points = new List<Point> { pos, pos },
            Color = _activeColor,
            LineWidth = _activeStrokeWidth
        };
        _shapes.Add(_currentShape);
        RootGrid.CaptureMouse();
        RedrawAnnotations();
    }

    private void RootGrid_MouseMove(object sender, MouseEventArgs e)
    {
        Point pos = e.GetPosition(RootGrid);
        UpdateLoupe(pos);

        if (_isSelecting)
        {
            double x = Math.Min(_selectStart.X, pos.X);
            double y = Math.Min(_selectStart.Y, pos.Y);
            double w = Math.Abs(pos.X - _selectStart.X);
            double h = Math.Abs(pos.Y - _selectStart.Y);
            _selectionRect = new Rect(x, y, w, h);

            Canvas.SetLeft(SelectionBorder, x);
            Canvas.SetTop(SelectionBorder, y);
            SelectionBorder.Width = w;
            SelectionBorder.Height = h;

            int pw = (int)Math.Round(w * _dpiScaleX);
            int ph = (int)Math.Round(h * _dpiScaleY);
            DimensionText.Text = $"{pw} × {ph} px";
            Canvas.SetLeft(DimensionBadge, x);
            Canvas.SetTop(DimensionBadge, Math.Max(4, y - 28));

            UpdateDimMask(_selectionRect);
            return;
        }

        if (_isDrawingAnnotation && _currentShape != null)
        {
            Point clamped = new(
                Math.Clamp(pos.X, _selectionRect.Left, _selectionRect.Right),
                Math.Clamp(pos.Y, _selectionRect.Top, _selectionRect.Bottom));

            if (_currentShape.Tool is AnnotationTool.Pen or AnnotationTool.Highlighter or AnnotationTool.Mosaic)
            {
                _currentShape.Points.Add(clamped);
            }
            else
            {
                _currentShape.Points[1] = clamped;
            }
            RedrawAnnotations();
        }
    }

    private void RootGrid_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_isSelecting)
        {
            _isSelecting = false;
            RootGrid.ReleaseMouseCapture();

            if (_selectionRect.Width >= 10 && _selectionRect.Height >= 10)
            {
                _hasSelection = true;
                LoupePanel.Visibility = Visibility.Collapsed;
                PositionToolbar();
                AnnotationToolbar.Visibility = Visibility.Visible;
            }
            else
            {
                SelectionBorder.Visibility = Visibility.Collapsed;
                DimensionBadge.Visibility = Visibility.Collapsed;
                UpdateDimMask(Rect.Empty);
            }
            return;
        }

        if (_isDrawingAnnotation)
        {
            _isDrawingAnnotation = false;
            _currentShape = null;
            RootGrid.ReleaseMouseCapture();
            RedrawAnnotations();
        }
    }

    private void RootGrid_MouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (_hasSelection)
        {
            // Reset selection on right-click
            _hasSelection = false;
            _shapes.Clear();
            _nextStepNumber = 1;
            AnnotationCanvas.Children.Clear();
            AnnotationToolbar.Visibility = Visibility.Collapsed;
            SelectionBorder.Visibility = Visibility.Collapsed;
            DimensionBadge.Visibility = Visibility.Collapsed;
            UpdateDimMask(Rect.Empty);
        }
        else
        {
            Close();
        }
    }

    private void PositionToolbar()
    {
        AnnotationToolbar.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double tbW = AnnotationToolbar.DesiredSize.Width > 0 ? AnnotationToolbar.DesiredSize.Width : 640;
        double tbH = AnnotationToolbar.DesiredSize.Height > 0 ? AnnotationToolbar.DesiredSize.Height : 76;

        double left = Math.Clamp(_selectionRect.Right - tbW, 8, Math.Max(8, ActualWidth - tbW - 8));
        double top = _selectionRect.Bottom + 10;
        if (top + tbH > ActualHeight - 8)
        {
            top = Math.Max(8, _selectionRect.Top - tbH - 10);
        }

        Canvas.SetLeft(AnnotationToolbar, left);
        Canvas.SetTop(AnnotationToolbar, top);
    }

    private void RedrawAnnotations()
    {
        AnnotationCanvas.Children.Clear();
        foreach (var shape in _shapes)
        {
            RenderShapeToCanvas(shape, AnnotationCanvas, 0, 0, 1.0, 1.0);
        }
    }

    private void RenderShapeToCanvas(AnnotationShape shape, Canvas canvas, double offsetX, double offsetY, double sx, double sy)
    {
        if (shape.Points.Count == 0) return;

        var brush = new SolidColorBrush(shape.Color);
        double sw = shape.LineWidth * sx;

        switch (shape.Tool)
        {
            case AnnotationTool.Rectangle when shape.Points.Count >= 2:
            {
                var p1 = shape.Points[0];
                var p2 = shape.Points[1];
                var rect = new Rectangle
                {
                    Width = Math.Abs(p2.X - p1.X) * sx,
                    Height = Math.Abs(p2.Y - p1.Y) * sy,
                    Stroke = brush,
                    StrokeThickness = sw
                };
                Canvas.SetLeft(rect, (Math.Min(p1.X, p2.X) - offsetX) * sx);
                Canvas.SetTop(rect, (Math.Min(p1.Y, p2.Y) - offsetY) * sy);
                canvas.Children.Add(rect);
                break;
            }
            case AnnotationTool.Ellipse when shape.Points.Count >= 2:
            {
                var p1 = shape.Points[0];
                var p2 = shape.Points[1];
                var ell = new Ellipse
                {
                    Width = Math.Abs(p2.X - p1.X) * sx,
                    Height = Math.Abs(p2.Y - p1.Y) * sy,
                    Stroke = brush,
                    StrokeThickness = sw
                };
                Canvas.SetLeft(ell, (Math.Min(p1.X, p2.X) - offsetX) * sx);
                Canvas.SetTop(ell, (Math.Min(p1.Y, p2.Y) - offsetY) * sy);
                canvas.Children.Add(ell);
                break;
            }
            case AnnotationTool.Line when shape.Points.Count >= 2:
            {
                var p1 = shape.Points[0];
                var p2 = shape.Points[1];
                canvas.Children.Add(new Line
                {
                    X1 = (p1.X - offsetX) * sx,
                    Y1 = (p1.Y - offsetY) * sy,
                    X2 = (p2.X - offsetX) * sx,
                    Y2 = (p2.Y - offsetY) * sy,
                    Stroke = brush,
                    StrokeThickness = sw,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round
                });
                break;
            }
            case AnnotationTool.Arrow when shape.Points.Count >= 2:
            {
                var p1 = new Point((shape.Points[0].X - offsetX) * sx, (shape.Points[0].Y - offsetY) * sy);
                var p2 = new Point((shape.Points[1].X - offsetX) * sx, (shape.Points[1].Y - offsetY) * sy);
                canvas.Children.Add(new Line
                {
                    X1 = p1.X, Y1 = p1.Y, X2 = p2.X, Y2 = p2.Y,
                    Stroke = brush, StrokeThickness = sw, StrokeStartLineCap = PenLineCap.Round
                });

                double angle = Math.Atan2(p2.Y - p1.Y, p2.X - p1.X);
                double headLen = Math.Max(12 * sx, sw * 3.8);
                double spread = 0.45;
                var h1 = new Point(p2.X - headLen * Math.Cos(angle - spread), p2.Y - headLen * Math.Sin(angle - spread));
                var h2 = new Point(p2.X - headLen * Math.Cos(angle + spread), p2.Y - headLen * Math.Sin(angle + spread));

                canvas.Children.Add(new Polygon
                {
                    Points = new PointCollection { p2, h1, h2 },
                    Fill = brush
                });
                break;
            }
            case AnnotationTool.Pen:
            case AnnotationTool.Highlighter:
            {
                bool isHl = shape.Tool == AnnotationTool.Highlighter;
                var poly = new Polyline
                {
                    Stroke = isHl ? new SolidColorBrush(Color.FromArgb(105, shape.Color.R, shape.Color.G, shape.Color.B)) : brush,
                    StrokeThickness = isHl ? sw * 4.0 : sw,
                    StrokeLineJoin = PenLineJoin.Round,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round
                };
                foreach (var pt in shape.Points)
                {
                    poly.Points.Add(new Point((pt.X - offsetX) * sx, (pt.Y - offsetY) * sy));
                }
                canvas.Children.Add(poly);
                break;
            }
            case AnnotationTool.Mosaic:
            {
                double block = Math.Max(10, shape.LineWidth * 3.5);
                var drawnCells = new HashSet<(int, int)>();
                foreach (var pt in shape.Points)
                {
                    int gx = (int)Math.Floor(pt.X / block);
                    int gy = (int)Math.Floor(pt.Y / block);
                    if (!drawnCells.Add((gx, gy))) continue;

                    Color sampled = SamplePixelColor(gx * block + block / 2, gy * block + block / 2);
                    var tile = new Rectangle
                    {
                        Width = block * sx + 0.5,
                        Height = block * sy + 0.5,
                        Fill = new SolidColorBrush(sampled)
                    };
                    Canvas.SetLeft(tile, (gx * block - offsetX) * sx);
                    Canvas.SetTop(tile, (gy * block - offsetY) * sy);
                    canvas.Children.Add(tile);
                }
                break;
            }
            case AnnotationTool.Counter:
            {
                var p = shape.Points[0];
                double size = 28 * sx;
                var grid = new Grid { Width = size, Height = size };
                grid.Children.Add(new Ellipse { Fill = brush, Stroke = Brushes.White, StrokeThickness = 1.5 * sx });
                grid.Children.Add(new TextBlock
                {
                    Text = shape.StepNumber.ToString(CultureInfo.InvariantCulture),
                    Foreground = Brushes.White,
                    FontWeight = FontWeights.Bold,
                    FontSize = 14 * sx,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center
                });
                Canvas.SetLeft(grid, (p.X - offsetX) * sx - size / 2);
                Canvas.SetTop(grid, (p.Y - offsetY) * sy - size / 2);
                canvas.Children.Add(grid);
                break;
            }
            case AnnotationTool.Text when !string.IsNullOrWhiteSpace(shape.Text):
            {
                var p = shape.Points[0];
                var tb = new TextBlock
                {
                    Text = shape.Text,
                    Foreground = brush,
                    FontSize = (14 + shape.LineWidth * 2) * sx,
                    FontWeight = FontWeights.Bold
                };
                Canvas.SetLeft(tb, (p.X - offsetX) * sx);
                Canvas.SetTop(tb, (p.Y - offsetY) * sy - 12 * sy);
                canvas.Children.Add(tb);
                break;
            }
        }
    }

    private Color SamplePixelColor(double dipX, double dipY)
    {
        int px = Math.Clamp((int)Math.Round(dipX * _dpiScaleX), 0, _physWidth - 1);
        int py = Math.Clamp((int)Math.Round(dipY * _dpiScaleY), 0, _physHeight - 1);
        int idx = py * _pixelStride + px * 4;
        return Color.FromRgb(_pixelData[idx + 2], _pixelData[idx + 1], _pixelData[idx]);
    }

    private BitmapSource RenderFinalCroppedImage()
    {
        CommitInlineTextIfOpen();

        int cx = Math.Clamp((int)Math.Round(_selectionRect.Left * _dpiScaleX), 0, _physWidth - 1);
        int cy = Math.Clamp((int)Math.Round(_selectionRect.Top * _dpiScaleY), 0, _physHeight - 1);
        int cw = Math.Clamp((int)Math.Round(_selectionRect.Width * _dpiScaleX), 1, _physWidth - cx);
        int ch = Math.Clamp((int)Math.Round(_selectionRect.Height * _dpiScaleY), 1, _physHeight - cy);

        var cropped = new CroppedBitmap(_frozenBitmap, new Int32Rect(cx, cy, cw, ch));

        var container = new Grid { Width = cw, Height = ch };
        container.Children.Add(new Image { Source = cropped, Width = cw, Height = ch, Stretch = Stretch.Fill });

        var annotCanvas = new Canvas { Width = cw, Height = ch };
        foreach (var shape in _shapes)
        {
            RenderShapeToCanvas(shape, annotCanvas, _selectionRect.Left, _selectionRect.Top, _dpiScaleX, _dpiScaleY);
        }
        container.Children.Add(annotCanvas);

        container.Measure(new Size(cw, ch));
        container.Arrange(new Rect(0, 0, cw, ch));
        container.UpdateLayout();

        var rtb = new RenderTargetBitmap(cw, ch, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(container);
        rtb.Freeze();
        return rtb;
    }

    private void CommitInlineTextIfOpen()
    {
        if (InlineTextBox.Visibility != Visibility.Visible) return;
        string txt = InlineTextBox.Text.Trim();
        InlineTextBox.Visibility = Visibility.Collapsed;
        if (!string.IsNullOrEmpty(txt))
        {
            _shapes.Add(new AnnotationShape
            {
                Tool = AnnotationTool.Text,
                Points = new List<Point> { _pendingTextPoint },
                Color = _activeColor,
                LineWidth = _activeStrokeWidth,
                Text = txt
            });
            RedrawAnnotations();
        }
    }

    private void CopyCurrentColorAndClose()
    {
        try
        {
            Clipboard.SetText(_currentHex);
            _onToast?.Invoke($"已複製色碼 {_currentHex}");
        }
        catch { }
        Close();
    }

    private void InlineTextBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            CommitInlineTextIfOpen();
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            InlineTextBox.Visibility = Visibility.Collapsed;
            e.Handled = true;
        }
    }

    private void InlineTextBox_LostFocus(object sender, RoutedEventArgs e) => CommitInlineTextIfOpen();

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (InlineTextBox.Visibility == Visibility.Visible)
            return;

        if (e.Key == Key.Escape)
        {
            Close();
        }
        else if (e.Key == Key.C && !_hasSelection)
        {
            CopyCurrentColorAndClose();
        }
        else if (e.Key == Key.Z && Keyboard.Modifiers == ModifierKeys.Control && _shapes.Count > 0)
        {
            _shapes.RemoveAt(_shapes.Count - 1);
            RedrawAnnotations();
        }
    }

    private void Toolbar_SwallowMouse(object sender, MouseButtonEventArgs e) => e.Handled = true;

    private void ToolButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string tag && Enum.TryParse<AnnotationTool>(tag, out var tool))
        {
            _activeTool = tool;
            ActiveToolIndicator.Text = $"目前：{btn.ToolTip}";
        }
    }

    private void ColorSwatch_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string hex)
        {
            _activeColor = (Color)ColorConverter.ConvertFromString(hex);
        }
    }

    private void StrokeWidth_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string s && double.TryParse(s, out double w))
        {
            _activeStrokeWidth = w;
        }
    }

    private void Undo_Click(object sender, RoutedEventArgs e)
    {
        if (_shapes.Count > 0)
        {
            _shapes.RemoveAt(_shapes.Count - 1);
            RedrawAnnotations();
        }
    }

    private void Clear_Click(object sender, RoutedEventArgs e)
    {
        _shapes.Clear();
        _nextStepNumber = 1;
        RedrawAnnotations();
    }

    private void PinSelection_Click(object sender, RoutedEventArgs e)
    {
        var bmp = RenderFinalCroppedImage();
        Close();
        _onPin?.Invoke(bmp);
    }

    private void CopySelection_Click(object sender, RoutedEventArgs e)
    {
        var bmp = RenderFinalCroppedImage();
        try { Clipboard.SetImage(bmp); } catch { }
        _onToast?.Invoke("截圖已複製到剪貼簿！");
        Close();
    }

    private void SaveSelection_Click(object sender, RoutedEventArgs e)
    {
        var bmp = RenderFinalCroppedImage();
        Directory.CreateDirectory(_outputDirectory);
        string path = System.IO.Path.Combine(_outputDirectory, $"MingCam_Shot_{DateTime.Now:yyyyMMdd_HHmmss}.png");
        using (var fs = File.Create(path))
        {
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bmp));
            encoder.Save(fs);
        }
        try { Clipboard.SetImage(bmp); } catch { }
        _onSaved?.Invoke(path);
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();
}
