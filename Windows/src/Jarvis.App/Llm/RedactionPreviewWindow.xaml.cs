using System.Text;
using System.Windows;
using Jarvis.Core.Conversation;
using Jarvis.Perception.Conversation;

namespace Jarvis.App.Llm;

public partial class RedactionPreviewWindow : Window
{
    public RedactionPreviewWindow(IConversationService conversation, IConversationContextBuilder contextBuilder,
        IContextBudgeter budgeter)
    {
        InitializeComponent();
        var ctx = contextBuilder.Build();
        var (compact, report) = budgeter.Budget(ctx);
        RedactedText.Text = EchoLlmClient.ContextSummary(compact);

        var rows = report.Categories
            .OrderByDescending(kv => kv.Value)
            .Select(kv => new KeyValuePair<string, int>(kv.Key, kv.Value))
            .ToList();
        CategoryList.ItemsSource = rows;
        EmptyHint.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnCopyRedacted(object sender, RoutedEventArgs e)
    {
        try { System.Windows.Clipboard.SetText(RedactedText.Text); } catch { }
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
