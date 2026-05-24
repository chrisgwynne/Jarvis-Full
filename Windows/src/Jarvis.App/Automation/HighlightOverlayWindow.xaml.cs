using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Screen = System.Windows.Forms.Screen;

namespace Jarvis.App.Automation;

/// <summary>
/// Click-through overlay covering the full virtual desktop. Pulses a rect at the given
/// device-pixel bounds for a fixed duration then closes itself. Does not steal focus
/// (<c>ShowActivated=false</c>, <c>IsHitTestVisible=false</c>).
/// </summary>
public partial class HighlightOverlayWindow : Window
{
    public HighlightOverlayWindow(int x, int y, int width, int height, string? label, TimeSpan duration)
    {
        InitializeComponent();
        ShowActivated = false;

        var virtualBounds = Screen.AllScreens.Select(s => s.Bounds)
            .Aggregate((a, b) => System.Drawing.Rectangle.Union(a, b));
        var dpi = VisualTreeHelper.GetDpi(this);
        Left = virtualBounds.Left / dpi.DpiScaleX;
        Top = virtualBounds.Top / dpi.DpiScaleY;
        Width = virtualBounds.Width / dpi.DpiScaleX;
        Height = virtualBounds.Height / dpi.DpiScaleY;

        // Translate device-pixel target rect into DIPs *relative to* this window's origin.
        var diX = (x - virtualBounds.Left) / dpi.DpiScaleX;
        var diY = (y - virtualBounds.Top) / dpi.DpiScaleY;
        var diW = width / dpi.DpiScaleX;
        var diH = height / dpi.DpiScaleY;

        Canvas.SetLeft(HighlightRect, diX);
        Canvas.SetTop(HighlightRect, diY);
        HighlightRect.Width = diW;
        HighlightRect.Height = diH;

        if (!string.IsNullOrEmpty(label))
        {
            LabelText.Text = label!;
            Canvas.SetLeft(LabelText, diX);
            Canvas.SetTop(LabelText, Math.Max(0, diY - 22));
        }
        else
        {
            LabelText.Visibility = Visibility.Collapsed;
        }

        // Three-pulse fade-out animation.
        var pulse = new DoubleAnimationUsingKeyFrames
        {
            Duration = duration,
            KeyFrames =
            {
                new LinearDoubleKeyFrame(1.0,   KeyTime.FromPercent(0.00)),
                new LinearDoubleKeyFrame(0.55,  KeyTime.FromPercent(0.20)),
                new LinearDoubleKeyFrame(1.0,   KeyTime.FromPercent(0.40)),
                new LinearDoubleKeyFrame(0.55,  KeyTime.FromPercent(0.60)),
                new LinearDoubleKeyFrame(1.0,   KeyTime.FromPercent(0.80)),
                new LinearDoubleKeyFrame(0.0,   KeyTime.FromPercent(1.00))
            }
        };
        pulse.Completed += (_, _) => Close();
        HighlightRect.BeginAnimation(OpacityProperty, pulse);
        LabelText.BeginAnimation(OpacityProperty, pulse);
    }
}
