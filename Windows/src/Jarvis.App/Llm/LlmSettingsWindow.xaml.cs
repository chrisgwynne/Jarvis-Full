using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using Jarvis.Core.Conversation;
using Jarvis.Core.Settings;

namespace Jarvis.App.Llm;

public partial class LlmSettingsWindow : Window
{
    private readonly IJarvisSettingsStore _store;
    private readonly ILlmProviderManager _manager;
    private readonly Action? _onSaved;

    public LlmSettingsWindow(IJarvisSettingsStore store, ILlmProviderManager manager, Action? onSaved = null)
    {
        _store = store;
        _manager = manager;
        _onSaved = onSaved;
        InitializeComponent();
        Loaded += (_, _) => LoadFromSettings();
    }

    private void LoadFromSettings()
    {
        var s = _store.Current;
        ProviderCombo.SelectedIndex = (int)s.Llm.Provider;
        ApiKeyBox.Password = s.Llm.ApiKey ?? "";
        ApiKeyText.Text = s.Llm.ApiKey ?? "";
        BaseUrlBox.Text = s.Llm.BaseUrl ?? "";
        ModelBox.Text = s.Llm.Model;
        TempBox.Text = s.Llm.Temperature.ToString(CultureInfo.InvariantCulture);
        MaxTokensBox.Text = s.Llm.MaxTokens.ToString();
        TimeoutBox.Text = s.Llm.TimeoutSeconds.ToString();
        StreamCheck.IsChecked = s.Llm.Stream;
        ContextInjectionCheck.IsChecked = s.Llm.ContextInjectionEnabled;

        RedactionEnabledCheck.IsChecked = s.Redaction.Enabled;
        RedactEmailsCheck.IsChecked = s.Redaction.RedactEmails;
        RedactPhonesCheck.IsChecked = s.Redaction.RedactPhones;
        RedactPathsCheck.IsChecked = s.Redaction.RedactFilePaths;
        MaxSelChars.Text = s.Redaction.MaxSelectedTextChars.ToString();
        MaxClipChars.Text = s.Redaction.MaxClipboardChars.ToString();
        MaxOcrChars.Text = s.Redaction.MaxOcrChars.ToString();

        QuotaEnabledCheck.IsChecked = s.Quota.Enabled;
        QuotaExemptLocalCheck.IsChecked = s.Quota.ExemptLocalProviders;
        MaxReqs.Text = s.Quota.MaxRequestsPerDay.ToString();
        MaxChars.Text = s.Quota.MaxApproxCharsPerDay.ToString();

        UpdateStatus($"Active: {_manager.Status.Detail}");
    }

    private void OnProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        // Show / hide API-key for None / Ollama. Indices: 0=None, 1=OpenAI, 2=Ollama, 3=MiniMax.
        if (ProviderCombo.SelectedIndex is 0 or 2)
            ApiKeyBox.IsEnabled = ApiKeyText.IsEnabled = false;
        else
            ApiKeyBox.IsEnabled = ApiKeyText.IsEnabled = true;
    }

    private void OnToggleReveal(object sender, RoutedEventArgs e)
    {
        if (ApiKeyText.Visibility == Visibility.Collapsed)
        {
            ApiKeyText.Text = ApiKeyBox.Password;
            ApiKeyText.Visibility = Visibility.Visible;
            ApiKeyBox.Visibility = Visibility.Collapsed;
            RevealBtn.Content = "Hide";
        }
        else
        {
            ApiKeyBox.Password = ApiKeyText.Text;
            ApiKeyBox.Visibility = Visibility.Visible;
            ApiKeyText.Visibility = Visibility.Collapsed;
            RevealBtn.Content = "Reveal";
        }
    }

    private async void OnTest(object sender, RoutedEventArgs e)
    {
        UpdateStatus("Saving and testing…");
        await SaveAsync();
        var result = await _manager.TestAsync();
        UpdateStatus(result.Ok ? $"✓ {result.Message}" : $"✗ {result.Message}");
    }

    private async void OnSave(object sender, RoutedEventArgs e)
    {
        await SaveAsync();
        _onSaved?.Invoke();
        DialogResult = true;
        Close();
    }

    private void OnCancel(object sender, RoutedEventArgs e) { DialogResult = false; Close(); }

    private async Task SaveAsync()
    {
        var current = _store.Current;
        var llm = current.Llm with
        {
            Provider = (LlmProviderType)Math.Max(0, ProviderCombo.SelectedIndex),
            ApiKey = string.IsNullOrEmpty(CurrentKey()) ? null : CurrentKey(),
            BaseUrl = string.IsNullOrWhiteSpace(BaseUrlBox.Text) ? null : BaseUrlBox.Text.Trim(),
            Model = ModelBox.Text.Trim(),
            Temperature = double.TryParse(TempBox.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var t) ? t : current.Llm.Temperature,
            MaxTokens = int.TryParse(MaxTokensBox.Text, out var mt) ? mt : current.Llm.MaxTokens,
            TimeoutSeconds = int.TryParse(TimeoutBox.Text, out var to) ? to : current.Llm.TimeoutSeconds,
            Stream = StreamCheck.IsChecked == true,
            ContextInjectionEnabled = ContextInjectionCheck.IsChecked == true
        };
        var red = current.Redaction with
        {
            Enabled = RedactionEnabledCheck.IsChecked == true,
            RedactEmails = RedactEmailsCheck.IsChecked == true,
            RedactPhones = RedactPhonesCheck.IsChecked == true,
            RedactFilePaths = RedactPathsCheck.IsChecked == true,
            MaxSelectedTextChars = int.TryParse(MaxSelChars.Text, out var s1) ? s1 : current.Redaction.MaxSelectedTextChars,
            MaxClipboardChars = int.TryParse(MaxClipChars.Text, out var s2) ? s2 : current.Redaction.MaxClipboardChars,
            MaxOcrChars = int.TryParse(MaxOcrChars.Text, out var s3) ? s3 : current.Redaction.MaxOcrChars,
        };
        var quota = current.Quota with
        {
            Enabled = QuotaEnabledCheck.IsChecked == true,
            ExemptLocalProviders = QuotaExemptLocalCheck.IsChecked == true,
            MaxRequestsPerDay = int.TryParse(MaxReqs.Text, out var q1) ? q1 : current.Quota.MaxRequestsPerDay,
            MaxApproxCharsPerDay = int.TryParse(MaxChars.Text, out var q2) ? q2 : current.Quota.MaxApproxCharsPerDay,
        };
        await _store.SaveAsync(current with { Llm = llm, Redaction = red, Quota = quota });
    }

    private string CurrentKey() =>
        (ApiKeyText.Visibility == Visibility.Visible ? ApiKeyText.Text : ApiKeyBox.Password).Trim();

    private void UpdateStatus(string s) { StatusText.Text = s; }
}
