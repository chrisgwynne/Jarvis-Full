using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Brush = System.Windows.Media.Brush;
using Color = System.Windows.Media.Color;
using Jarvis.Core.Conversation;
using Jarvis.Core.State;
using Screen = System.Windows.Forms.Screen;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;

namespace Jarvis.App.Chat;

public partial class ChatPanelWindow : Window
{
    private readonly IConversationService _conversation;
    private readonly PebbleStateMachine _state;
    private readonly ObservableCollection<ChatRow> _rows = new();
    private CancellationTokenSource? _inFlight;

    private readonly ILlmProviderManager? _providerManager;
    private DispatcherTimer? _caretTimer;
    private bool _caretOn;

    public ChatPanelWindow(IConversationService conversation, PebbleStateMachine state, ILlmProviderManager? providerManager = null)
    {
        _conversation = conversation;
        _state = state;
        _providerManager = providerManager;
        InitializeComponent();
        MessagesList.ItemsSource = _rows;
        Loaded += (_, _) => { PositionTopRight(); InputBox.Focus(); UpdateProviderText(); };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Hide(); };
        _conversation.MessageAppended += OnMessageAppended;
        _conversation.StreamChunk += OnStreamChunk;
        _conversation.TurnCompleted += OnTurnCompleted;
        Closed += (_, _) =>
        {
            _conversation.MessageAppended -= OnMessageAppended;
            _conversation.StreamChunk -= OnStreamChunk;
            _conversation.TurnCompleted -= OnTurnCompleted;
            _caretTimer?.Stop();
        };
    }

    private void UpdateProviderText()
    {
        if (_providerManager is null) { ProviderText.Text = ""; return; }
        var s = _providerManager.Status;
        ProviderText.Text = s.Configured
            ? $"{s.Type} · {s.Model}"
            : "no LLM provider (echo stub) — configure in settings.json";
    }

    private void PositionTopRight()
    {
        var screen = Screen.PrimaryScreen?.WorkingArea ?? new System.Drawing.Rectangle(0, 0, 1920, 1080);
        Left = (screen.Right - ActualWidth) - 16;
        Top = screen.Top + 60;
    }

    private void OnMessageAppended(object? sender, ChatMessage msg)
    {
        Dispatcher.BeginInvoke(() =>
        {
            _rows.Add(ChatRow.From(msg));
            ScrollToEnd();
        });
    }

    private void OnStreamChunk(object? sender, ChatMessage chunk)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (_rows.Count == 0) return;
            var last = _rows[^1];
            last.Content += chunk.Content;
            _rows[^1] = last;
            ScrollToEnd();
        });
    }

    private void OnTurnCompleted(object? sender, ConversationTurn turn)
    {
        Dispatcher.BeginInvoke(() =>
        {
            // Mark "no longer streaming" — update final content.
            if (_rows.Count > 0)
            {
                var last = _rows[^1];
                _rows[^1] = last with { Content = turn.Assistant.Content };
            }
            StatusText.Text = turn.Diagnostics.Intent == LocalIntent.Unknown
                ? $"{turn.Diagnostics.TotalMs:F0}ms · LLM"
                : $"{turn.Diagnostics.TotalMs:F0}ms · {turn.Diagnostics.Intent}";
            UpdateProviderText(); // settings may have been changed since the panel opened
            StopBtn.IsEnabled = false;
            _state.Apply(_state.LastInputs with { TtsSpeaking = false, Interrupted = false });
        });
    }

    private async void OnSend(object sender, RoutedEventArgs e) => await SendAsync();
    private async void OnInputKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.None) { await SendAsync(); e.Handled = true; }
    }

    private string? _lastUserMessage;

    private async void OnRetry(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_lastUserMessage)) return;
        InputBox.Text = _lastUserMessage;
        await SendAsync();
    }

    private async Task SendAsync()
    {
        var msg = InputBox.Text.Trim();
        if (string.IsNullOrEmpty(msg)) return;
        InputBox.Clear();
        _lastUserMessage = msg;
        EmptyHint.Visibility = Visibility.Collapsed;
        RetryBtn.IsEnabled = true;
        _inFlight?.Cancel();
        _inFlight = new CancellationTokenSource();
        StopBtn.IsEnabled = true;
        StatusText.Text = "thinking…";
        StartCaretBlink();
        _state.Apply(_state.LastInputs with { Interrupted = true });
        try
        {
            await _conversation.SendAsync(msg, _inFlight.Token);
        }
        catch (OperationCanceledException) { /* cancelled — handled in the service */ }
        finally
        {
            StopBtn.IsEnabled = false;
            StopCaretBlink();
        }
    }

    private void StartCaretBlink()
    {
        if (_rows.Count == 0) return;
        _caretTimer?.Stop();
        _caretTimer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(450) };
        _caretTimer.Tick += (_, _) =>
        {
            if (_rows.Count == 0) return;
            _caretOn = !_caretOn;
            var last = _rows[^1];
            _rows[^1] = last with { Caret = _caretOn ? " ▋" : "" };
        };
        _caretTimer.Start();
    }

    private void StopCaretBlink()
    {
        _caretTimer?.Stop();
        if (_rows.Count > 0)
        {
            var last = _rows[^1];
            _rows[^1] = last with { Caret = "" };
        }
    }

    private void OnCopyRow(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.Button btn && btn.Tag is ChatRow row)
        {
            try { System.Windows.Clipboard.SetText(row.Content); } catch { }
        }
    }

    private void OnStop(object sender, RoutedEventArgs e) => _inFlight?.Cancel();
    private void OnClear(object sender, RoutedEventArgs e)
    {
        _conversation.Clear();
        _rows.Clear();
        StatusText.Text = "";
        EmptyHint.Visibility = Visibility.Visible;
        RetryBtn.IsEnabled = false;
        _lastUserMessage = null;
    }
    private void OnMinimise(object sender, RoutedEventArgs e) => Hide();

    private void ScrollToEnd() => ScrollView.ScrollToEnd();

    public sealed record ChatRow(string Role, string RoleLabel, Brush Brush)
    {
        public string Content { get; set; } = "";
        public string Caret { get; set; } = "";

        public static ChatRow From(ChatMessage m)
        {
            var (label, brush) = m.Role switch
            {
                ChatRole.User      => ("you",   (Brush)new SolidColorBrush(Color.FromRgb(0x18, 0x1f, 0x2e))),
                ChatRole.Assistant => (m.RoutedIntent is null or "Unknown" ? "jarvis" : $"jarvis · {m.RoutedIntent}",
                                        new SolidColorBrush(Color.FromRgb(0x12, 0x1a, 0x26))),
                _                  => ("system", new SolidColorBrush(Color.FromRgb(0x0c, 0x10, 0x18))),
            };
            return new ChatRow(m.Role.ToString(), label, brush) { Content = m.Content };
        }
    }
}
