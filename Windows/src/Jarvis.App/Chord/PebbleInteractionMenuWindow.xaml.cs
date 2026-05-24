using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Jarvis.App.Interop;
using Jarvis.Core.Diagnostics;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using Cursors = System.Windows.Input.Cursors;
using Orientation = System.Windows.Controls.Orientation;

namespace Jarvis.App.Chord;

/// <summary>
/// Small floating menu invoked by the left+right mouse chord. Items are wired by the
/// caller via <see cref="Items"/> before showing, so this window owns no app commands —
/// it's purely presentation.
///
/// Visual rules from the spec: rounded, translucent, topmost, fast, doesn't steal focus.
/// Closes on item-select / Esc / outside-click / explicit <see cref="Close"/>.
/// </summary>
public partial class PebbleInteractionMenuWindow : Window
{
    public sealed record MenuItem(string Label, string Glyph, Action Invoke);

    private readonly IDiagnostics? _diagnostics;
    private readonly List<MenuItem> _items;
    private string _lastSelectedLabel = "";
    /// <summary>Reason the menu closed — diagnostic field.</summary>
    public string CloseReason { get; private set; } = "unknown";
    public string LastSelectedItem => _lastSelectedLabel;

    public PebbleInteractionMenuWindow(IEnumerable<MenuItem> items, IDiagnostics? diagnostics = null)
    {
        InitializeComponent();
        _diagnostics = diagnostics;
        _items = items.ToList();
        BuildItems();
    }

    private void BuildItems()
    {
        MenuItems.Children.Clear();
        foreach (var item in _items)
        {
            var row = new Border
            {
                Padding = new Thickness(10, 7, 10, 7),
                Margin = new Thickness(0, 1, 0, 1),
                CornerRadius = new CornerRadius(6),
                Background = Brushes.Transparent,
                Cursor = Cursors.Hand
            };
            var stack = new StackPanel { Orientation = Orientation.Horizontal };
            stack.Children.Add(new TextBlock
            {
                Text = item.Glyph,
                FontSize = 14,
                Width = 22,
                Foreground = new SolidColorBrush(Color.FromRgb(0xcf, 0xe8, 0xff))
            });
            stack.Children.Add(new TextBlock
            {
                Text = item.Label,
                FontSize = 13,
                Foreground = new SolidColorBrush(Color.FromRgb(0xea, 0xf2, 0xff)),
                VerticalAlignment = VerticalAlignment.Center
            });
            row.Child = stack;

            row.MouseEnter += (_, _) => row.Background = new SolidColorBrush(Color.FromArgb(0x60, 0x4a, 0x7e, 0xc6));
            row.MouseLeave += (_, _) => row.Background = Brushes.Transparent;
            row.MouseLeftButtonUp += (_, _) => Select(item);
            MenuItems.Children.Add(row);
        }
    }

    private void Select(MenuItem item)
    {
        _lastSelectedLabel = item.Label;
        CloseReason = "item-selected";
        _diagnostics?.Record(DiagnosticLevel.Info, "chord.menu", "selected",
            new Dictionary<string, object?> { ["item"] = item.Label });
        // Close BEFORE invoking, so the user's chosen action doesn't have to fight a
        // still-visible topmost menu (e.g. ShowSettings opens a dialog).
        Close();
        try { item.Invoke(); } catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "chord.menu", "item invoke failed",
                new Dictionary<string, object?> { ["item"] = item.Label, ["error"] = ex.Message });
        }
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        // Click outside (or any other reason the window lost activation) closes.
        if (IsLoaded)
        {
            CloseReason = "deactivated";
            Close();
        }
    }

    private void OnKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { CloseReason = "escape"; Close(); }
    }

    /// <summary>Position the menu near the supplied physical-pixel cursor point, clamped
    /// to the cursor monitor's work area. DPI-aware: the supplied coords are physical px;
    /// SetWindowPos consumes physical px directly, bypassing WPF DIP bookkeeping.</summary>
    public void ShowAt(int cursorPxX, int cursorPxY)
    {
        Show();
        Activate();
        // Force a layout pass so ActualWidth/ActualHeight are populated, then convert to
        // physical pixels for SetWindowPos.
        UpdateLayout();
        var scale = CursorAnchorInterop.GetCursorScale(out _);
        var widthPx  = (int)Math.Round(ActualWidth  * scale);
        var heightPx = (int)Math.Round(ActualHeight * scale);
        // Offset down-right of the cursor (~16 DIP) so it doesn't sit under the pointer.
        var offsetPx = (int)Math.Round(16 * scale);
        var x = cursorPxX + offsetPx;
        var y = cursorPxY + offsetPx;

        var work = CursorAnchorInterop.GetCursorMonitorWorkArea(new CursorAnchorInterop.POINT { X = cursorPxX, Y = cursorPxY });
        x = Math.Clamp(x, work.Left, Math.Max(work.Left, work.Right - widthPx));
        y = Math.Clamp(y, work.Top, Math.Max(work.Top, work.Bottom - heightPx));

        var hwnd = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        const uint flags = CursorAnchorInterop.SWP_NOSIZE | CursorAnchorInterop.SWP_NOZORDER | CursorAnchorInterop.SWP_NOACTIVATE;
        CursorAnchorInterop.SetWindowPos(hwnd, 0, x, y, 0, 0, flags);
        Focus();
    }
}
