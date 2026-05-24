using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Navigation;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using FontFamily = System.Windows.Media.FontFamily;
using SolidColorBrush = System.Windows.Media.SolidColorBrush;
using Button = System.Windows.Controls.Button;
using TextBox = System.Windows.Controls.TextBox;
using TextBlock = System.Windows.Controls.TextBlock;
using HorizontalAlignment = System.Windows.HorizontalAlignment;

namespace Jarvis.App.Chat;

/// <summary>
/// Tiny block-level Markdown → WPF <see cref="Block"/> converter. Deliberately small —
/// no dependencies; deterministic; safe on adversarial input (no HTML passthrough).
///
/// Supported:
///   - paragraphs
///   - bold (**x**), italic (*x* or _x_), inline code (`x`)
///   - links [text](url) → Hyperlink, http(s) only (defensive)
///   - fenced code blocks (``` or ```lang)
///   - bullet lists (- foo, * foo)
///   - numbered lists (1. foo)
///   - blockquotes (&gt; foo)
///   - thematic breaks (--- on its own line)
///
/// Unsupported (degrades gracefully): tables, images, HTML, headings beyond #
/// (they appear as bold paragraphs). Anything we don't recognise falls through as plain text.
/// </summary>
public static class MarkdownRenderer
{
    private static readonly Brush Muted = new SolidColorBrush(Color.FromRgb(0x8A, 0xA6, 0xCC));
    private static readonly Brush CodeBg = new SolidColorBrush(Color.FromRgb(0x18, 0x1F, 0x2E));
    private static readonly Brush CodeBorder = new SolidColorBrush(Color.FromRgb(0x29, 0x31, 0x4A));
    private static readonly FontFamily MonoFont = new("ui-monospace, Consolas, monospace");

    public static IList<Block> Render(string markdown, Action<string>? copyCode = null)
    {
        var blocks = new List<Block>();
        if (string.IsNullOrEmpty(markdown)) return blocks;

        var lines = markdown.Replace("\r\n", "\n").Split('\n');
        var i = 0;
        while (i < lines.Length)
        {
            var line = lines[i];

            // Fenced code block
            if (line.TrimStart().StartsWith("```", StringComparison.Ordinal))
            {
                var lang = line.TrimStart().Substring(3).Trim();
                var codeBuf = new System.Text.StringBuilder();
                i++;
                while (i < lines.Length && !lines[i].TrimStart().StartsWith("```", StringComparison.Ordinal))
                {
                    codeBuf.AppendLine(lines[i]);
                    i++;
                }
                if (i < lines.Length) i++; // skip closing fence
                blocks.Add(BuildCodeBlock(codeBuf.ToString().TrimEnd('\n'), lang, copyCode));
                continue;
            }

            // Thematic break
            if (Regex.IsMatch(line, @"^\s*(\-{3,}|\*{3,}|_{3,})\s*$"))
            {
                blocks.Add(BuildHorizontalRule());
                i++;
                continue;
            }

            // Blockquote
            if (line.StartsWith(">", StringComparison.Ordinal))
            {
                var quoted = new List<string>();
                while (i < lines.Length && lines[i].StartsWith(">", StringComparison.Ordinal))
                {
                    quoted.Add(lines[i].TrimStart('>').TrimStart());
                    i++;
                }
                blocks.Add(BuildBlockquote(string.Join("\n", quoted)));
                continue;
            }

            // Unordered list
            if (Regex.IsMatch(line, @"^\s*[\-\*]\s+"))
            {
                var items = new List<string>();
                while (i < lines.Length && Regex.IsMatch(lines[i], @"^\s*[\-\*]\s+"))
                {
                    items.Add(Regex.Replace(lines[i], @"^\s*[\-\*]\s+", ""));
                    i++;
                }
                blocks.Add(BuildList(items, ordered: false));
                continue;
            }

            // Ordered list
            if (Regex.IsMatch(line, @"^\s*\d+\.\s+"))
            {
                var items = new List<string>();
                while (i < lines.Length && Regex.IsMatch(lines[i], @"^\s*\d+\.\s+"))
                {
                    items.Add(Regex.Replace(lines[i], @"^\s*\d+\.\s+", ""));
                    i++;
                }
                blocks.Add(BuildList(items, ordered: true));
                continue;
            }

            // Heading
            var headingMatch = Regex.Match(line, @"^(#{1,6})\s+(.+)$");
            if (headingMatch.Success)
            {
                var level = headingMatch.Groups[1].Value.Length;
                var text = headingMatch.Groups[2].Value;
                blocks.Add(BuildHeading(text, level));
                i++;
                continue;
            }

            // Blank line — paragraph break
            if (string.IsNullOrWhiteSpace(line)) { i++; continue; }

            // Paragraph: collect consecutive non-empty, non-block lines
            var paragraphLines = new List<string>();
            while (i < lines.Length && !string.IsNullOrWhiteSpace(lines[i])
                && !lines[i].TrimStart().StartsWith("```", StringComparison.Ordinal)
                && !lines[i].StartsWith(">", StringComparison.Ordinal)
                && !Regex.IsMatch(lines[i], @"^\s*[\-\*]\s+")
                && !Regex.IsMatch(lines[i], @"^\s*\d+\.\s+")
                && !Regex.IsMatch(lines[i], @"^(#{1,6})\s+"))
            {
                paragraphLines.Add(lines[i]);
                i++;
            }
            blocks.Add(BuildParagraph(string.Join(" ", paragraphLines)));
        }
        return blocks;
    }

    // ── Block builders ─────────────────────────────────────────────────────

    private static Paragraph BuildParagraph(string text)
    {
        var p = new Paragraph { Margin = new Thickness(0, 0, 0, 6) };
        AppendInlines(p.Inlines, text);
        return p;
    }

    private static Paragraph BuildHeading(string text, int level)
    {
        var p = new Paragraph
        {
            FontSize = level switch { 1 => 17, 2 => 15, 3 => 14, _ => 13 },
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 8, 0, 4)
        };
        AppendInlines(p.Inlines, text);
        return p;
    }

    private static List BuildList(IList<string> items, bool ordered)
    {
        var list = new List
        {
            MarkerStyle = ordered ? TextMarkerStyle.Decimal : TextMarkerStyle.Disc,
            Margin = new Thickness(16, 0, 0, 6),
            Padding = new Thickness(0)
        };
        foreach (var item in items)
        {
            var li = new ListItem();
            var p = new Paragraph { Margin = new Thickness(0) };
            AppendInlines(p.Inlines, item);
            li.Blocks.Add(p);
            list.ListItems.Add(li);
        }
        return list;
    }

    private static Section BuildBlockquote(string text)
    {
        var section = new Section
        {
            BorderBrush = Muted,
            BorderThickness = new Thickness(3, 0, 0, 0),
            Padding = new Thickness(10, 2, 0, 2),
            Margin = new Thickness(0, 2, 0, 8)
        };
        var p = new Paragraph { Foreground = Muted, Margin = new Thickness(0) };
        AppendInlines(p.Inlines, text);
        section.Blocks.Add(p);
        return section;
    }

    private static Block BuildCodeBlock(string code, string? lang, Action<string>? copyCode)
    {
        // Wrap in a BlockUIContainer so we can host a real Border + Button.
        var container = new BlockUIContainer { Margin = new Thickness(0, 4, 0, 8) };
        var border = new Border
        {
            Background = CodeBg,
            BorderBrush = CodeBorder,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(10, 8, 10, 8)
        };
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var langText = new TextBlock { Text = string.IsNullOrEmpty(lang) ? "code" : lang, Foreground = Muted, FontSize = 10 };
        var copyBtn = new Button { Content = "Copy", Padding = new Thickness(8, 1, 8, 1), Margin = new Thickness(6, 0, 0, 0) };
        copyBtn.Click += (_, _) =>
        {
            try { System.Windows.Clipboard.SetText(code); } catch { }
            copyCode?.Invoke(code);
        };
        Grid.SetColumn(langText, 0);
        Grid.SetColumn(copyBtn, 1);
        header.Children.Add(langText);
        header.Children.Add(copyBtn);

        var codeBox = new TextBox
        {
            Text = code,
            IsReadOnly = true,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Foreground = new SolidColorBrush(Color.FromRgb(0xE6, 0xE8, 0xEE)),
            FontFamily = MonoFont,
            FontSize = 11,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            TextWrapping = TextWrapping.NoWrap,
            Margin = new Thickness(0, 6, 0, 0)
        };
        Grid.SetRow(header, 0);
        Grid.SetRow(codeBox, 1);
        grid.Children.Add(header);
        grid.Children.Add(codeBox);
        border.Child = grid;
        container.Child = border;
        return container;
    }

    private static Block BuildHorizontalRule()
    {
        var container = new BlockUIContainer { Margin = new Thickness(0, 4, 0, 4) };
        container.Child = new Border
        {
            Height = 1,
            Background = CodeBorder,
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
        return container;
    }

    // ── Inline pass ────────────────────────────────────────────────────────

    private static readonly Regex InlineRegex = new(
        @"(\*\*(?<bold>[^*]+)\*\*)|(__(?<bold>[^_]+)__)" +
        @"|(`(?<code>[^`]+)`)" +
        @"|(\*(?<italic>[^*\n]+)\*)|(_(?<italic>[^_\n]+)_)" +
        @"|(\[(?<linkText>[^\]]+)\]\((?<linkUrl>[^)]+)\))",
        RegexOptions.Compiled);

    internal static void AppendInlines(InlineCollection target, string text)
    {
        var index = 0;
        foreach (Match m in InlineRegex.Matches(text))
        {
            if (m.Index > index) target.Add(new Run(text.Substring(index, m.Index - index)));
            if (m.Groups["bold"].Success)
                target.Add(new Bold(new Run(m.Groups["bold"].Value)));
            else if (m.Groups["code"].Success)
                target.Add(new Run(m.Groups["code"].Value) { FontFamily = MonoFont, Background = CodeBg, Foreground = new SolidColorBrush(Color.FromRgb(0xE6, 0xE8, 0xEE)) });
            else if (m.Groups["italic"].Success)
                target.Add(new Italic(new Run(m.Groups["italic"].Value)));
            else if (m.Groups["linkText"].Success)
            {
                var url = m.Groups["linkUrl"].Value;
                var linkText = m.Groups["linkText"].Value;
                if (IsSafeLink(url))
                {
                    var hyperlink = new Hyperlink(new Run(linkText)) { NavigateUri = new Uri(url) };
                    hyperlink.RequestNavigate += OnHyperlinkNavigate;
                    target.Add(hyperlink);
                }
                else
                {
                    target.Add(new Run($"{linkText} ({url})"));
                }
            }
            index = m.Index + m.Length;
        }
        if (index < text.Length) target.Add(new Run(text.Substring(index)));
    }

    internal static bool IsSafeLink(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u) && (u.Scheme == "http" || u.Scheme == "https");

    private static void OnHyperlinkNavigate(object sender, RequestNavigateEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo { FileName = e.Uri.AbsoluteUri, UseShellExecute = true }); }
        catch { /* ignore */ }
        e.Handled = true;
    }
}
