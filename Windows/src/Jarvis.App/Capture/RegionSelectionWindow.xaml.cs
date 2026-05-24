using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using JCore = Jarvis.Core.Awareness;
using Jarvis.Perception.Capture;
using Screen = System.Windows.Forms.Screen;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;
using MouseButtonEventArgs = System.Windows.Input.MouseButtonEventArgs;
using MouseButton = System.Windows.Input.MouseButton;

namespace Jarvis.App.Capture;

/// <summary>
/// Fullscreen-virtual-desktop selection overlay. The window sits across the union of all
/// monitors' working areas so the user can drag through multi-monitor edges without losing
/// hit-testing. DPI: we capture cursor positions in DIPs and convert to device pixels at
/// commit time so the resulting Rect lines up with what the screen grabber expects.
/// </summary>
public partial class RegionSelectionWindow : Window
{
    private System.Windows.Point _start;
    private bool _dragging;
    private TaskCompletionSource<RegionSelection?>? _tcs;

    public RegionSelectionWindow()
    {
        InitializeComponent();
        var bounds = Screen.AllScreens
            .Select(s => s.Bounds)
            .Aggregate((a, b) => System.Drawing.Rectangle.Union(a, b));
        // Convert virtual-screen pixel bounds to WPF DIPs using primary-screen DPI.
        var dpi = System.Windows.Media.VisualTreeHelper.GetDpi(this);
        Left = bounds.Left / dpi.DpiScaleX;
        Top = bounds.Top / dpi.DpiScaleY;
        Width = bounds.Width / dpi.DpiScaleX;
        Height = bounds.Height / dpi.DpiScaleY;

        PreviewKeyDown += OnKey;
        MouseDown += OnMouseDown;
        MouseMove += OnMouseMove;
        MouseUp += OnMouseUp;
        Loaded += (_, _) => Activate();
    }

    public Task<RegionSelection?> WaitForSelection()
    {
        _tcs = new TaskCompletionSource<RegionSelection?>(TaskCreationOptions.RunContinuationsAsynchronously);
        return _tcs.Task;
    }

    private void OnKey(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Complete(null);
            e.Handled = true;
        }
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        _start = e.GetPosition(Root);
        _dragging = true;
        SelectionRect.Visibility = Visibility.Visible;
        DimensionsText.Visibility = Visibility.Visible;
        UpdateRect(_start, _start);
        Mouse.Capture(Root);
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (!_dragging) return;
        UpdateRect(_start, e.GetPosition(Root));
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        Mouse.Capture(null);
        var end = e.GetPosition(Root);
        var rect = NormalizeDiP(_start, end);

        if (rect.Width < 6 || rect.Height < 6)
        {
            Complete(null);
            return;
        }

        // Convert DIPs back to virtual-screen pixels.
        var dpi = System.Windows.Media.VisualTreeHelper.GetDpi(this);
        var pxLeft = (int)Math.Round((Left + rect.Left) * dpi.DpiScaleX);
        var pxTop = (int)Math.Round((Top + rect.Top) * dpi.DpiScaleY);
        var pxRight = (int)Math.Round((Left + rect.Right) * dpi.DpiScaleX);
        var pxBottom = (int)Math.Round((Top + rect.Bottom) * dpi.DpiScaleY);

        var monitor = Screen.FromPoint(new System.Drawing.Point(pxLeft + (pxRight - pxLeft) / 2, pxTop + (pxBottom - pxTop) / 2));
        var idx = Array.IndexOf(Screen.AllScreens, monitor);

        var selection = new RegionSelection(
            new JCore.Rect(pxLeft, pxTop, pxRight, pxBottom),
            idx >= 0 ? idx : 0,
            dpi.DpiScaleX);
        Complete(selection);
    }

    private static System.Windows.Rect NormalizeDiP(System.Windows.Point a, System.Windows.Point b)
    {
        var x = Math.Min(a.X, b.X);
        var y = Math.Min(a.Y, b.Y);
        var w = Math.Abs(a.X - b.X);
        var h = Math.Abs(a.Y - b.Y);
        return new System.Windows.Rect(x, y, w, h);
    }

    private void UpdateRect(System.Windows.Point a, System.Windows.Point b)
    {
        var r = NormalizeDiP(a, b);
        Canvas.SetLeft(SelectionRect, r.X);
        Canvas.SetTop(SelectionRect, r.Y);
        SelectionRect.Width = r.Width;
        SelectionRect.Height = r.Height;
        DimensionsText.Text = $"{(int)r.Width} × {(int)r.Height}";
        Canvas.SetLeft(DimensionsText, r.Right + 8);
        Canvas.SetTop(DimensionsText, r.Bottom + 4);
    }

    private void Complete(RegionSelection? selection)
    {
        _tcs?.TrySetResult(selection);
        Close();
    }
}
