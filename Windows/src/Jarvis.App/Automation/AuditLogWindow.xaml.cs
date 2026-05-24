using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Jarvis.Automation;
using Jarvis.Core.Automation;

namespace Jarvis.App.Automation;

public partial class AuditLogWindow : Window
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() }
    };

    private readonly IAuditLog _audit;

    public AuditLogWindow(IAuditLog audit)
    {
        _audit = audit;
        InitializeComponent();
        Loaded += (_, _) => Render();
    }

    private void OnRefresh(object sender, RoutedEventArgs e) => Render();

    private void OnFilterChanged(object sender, SelectionChangedEventArgs e) => Render();

    private void OnOpenFolder(object sender, RoutedEventArgs e)
    {
        var dir = JsonlAuditLog.DefaultDirectory();
        Directory.CreateDirectory(dir);
        try { Process.Start(new ProcessStartInfo { FileName = "explorer.exe", Arguments = $"\"{dir}\"", UseShellExecute = true }); }
        catch { /* ignored */ }
    }

    private void OnCopyJson(object sender, RoutedEventArgs e)
    {
        if (Grid.SelectedItem is not AuditEntry entry) return;
        try { System.Windows.Clipboard.SetText(JsonSerializer.Serialize(entry, JsonOpts)); }
        catch { /* ignored */ }
    }

    private void Render()
    {
        var tier = (TierFilter.SelectedItem as ComboBoxItem)?.Content?.ToString() ?? "any";
        var outcome = (OutcomeFilter.SelectedItem as ComboBoxItem)?.Content?.ToString() ?? "any";

        IEnumerable<AuditEntry> rows = _audit.Recent(500);
        if (tier != "any") rows = rows.Where(e => e.Tier.ToString() == tier);
        if (outcome != "any") rows = rows.Where(e => e.Outcome.ToString() == outcome);
        Grid.ItemsSource = rows.OrderByDescending(e => e.At).ToList();
    }
}
