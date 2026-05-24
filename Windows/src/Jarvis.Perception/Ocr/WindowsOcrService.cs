using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Perception;
using Microsoft.Extensions.Logging;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;
using OcrResult = Jarvis.Core.Perception.OcrResult;
using OcrLine = Jarvis.Core.Perception.OcrLine;
using OcrWord = Jarvis.Core.Perception.OcrWord;

namespace Jarvis.Perception.Ocr;

/// <summary>
/// OCR via the built-in Windows.Media.Ocr engine. No NuGet, no native bins.
/// Requires a language pack — TryCreateFromUserProfileLanguages() finds one that
/// matches the user locale. If none is installable the service reports IsAvailable=false
/// and RecognizeAsync returns an empty result rather than throwing.
/// </summary>
public sealed class WindowsOcrService : IOcrService
{
    private readonly IOcrPostProcessor _postProcessor;
    private readonly IDiagnostics? _diagnostics;
    private readonly ILogger<WindowsOcrService>? _logger;
    private readonly OcrEngine? _engine;

    public WindowsOcrService(
        IOcrPostProcessor postProcessor,
        IDiagnostics? diagnostics = null,
        ILogger<WindowsOcrService>? logger = null)
    {
        _postProcessor = postProcessor;
        _diagnostics = diagnostics;
        _logger = logger;
        try
        {
            _engine = OcrEngine.TryCreateFromUserProfileLanguages();
            if (_engine is null)
            {
                _diagnostics?.Record(DiagnosticLevel.Warn, "ocr", "no language pack available");
            }
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(ex, "OCR engine init failed");
            _diagnostics?.Record(DiagnosticLevel.Warn, "ocr", "engine init failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
            _engine = null;
        }
    }

    public bool IsAvailable => _engine is not null;

    public async Task<OcrResult> RecognizeAsync(byte[] pngBytes, CancellationToken cancellationToken = default)
    {
        var sw = Stopwatch.StartNew();
        if (_engine is null) return OcrResult.Empty(sw.Elapsed);
        if (pngBytes is null || pngBytes.Length == 0) return OcrResult.Empty(sw.Elapsed);

        try
        {
            using var ms = new InMemoryRandomAccessStream();
            await ms.WriteAsync(pngBytes.AsBuffer()).AsTask(cancellationToken).ConfigureAwait(false);
            ms.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(ms).AsTask(cancellationToken).ConfigureAwait(false);
            using var bitmap = await decoder.GetSoftwareBitmapAsync().AsTask(cancellationToken).ConfigureAwait(false);

            var raw = await _engine.RecognizeAsync(bitmap).AsTask(cancellationToken).ConfigureAwait(false);
            var cleaned = _postProcessor.Clean(raw.Text ?? string.Empty);

            var lines = new List<OcrLine>(raw.Lines.Count);
            double totalConf = 0;
            var wordCount = 0;
            foreach (var line in raw.Lines)
            {
                var words = new List<OcrWord>(line.Words.Count);
                foreach (var w in line.Words)
                {
                    // Windows.Media.Ocr doesn't expose per-word confidence; treat presence as 1.0.
                    words.Add(new OcrWord(w.Text, 1.0, new OcrRect(
                        w.BoundingRect.X, w.BoundingRect.Y, w.BoundingRect.Width, w.BoundingRect.Height)));
                    totalConf += 1.0;
                    wordCount++;
                }
                lines.Add(new OcrLine(line.Text, words));
            }

            var avg = wordCount > 0 ? totalConf / wordCount : 0;
            sw.Stop();
            _diagnostics?.RecordMetric("ocr.lastMs", sw.Elapsed.TotalMilliseconds);
            _diagnostics?.RecordMetric("ocr.lastWords", wordCount);
            _diagnostics?.Record(DiagnosticLevel.Debug, "ocr", "recognized",
                new Dictionary<string, object?>
                {
                    ["ms"] = sw.Elapsed.TotalMilliseconds,
                    ["lines"] = lines.Count,
                    ["words"] = wordCount,
                    ["lang"] = _engine.RecognizerLanguage.LanguageTag
                });

            return new OcrResult(
                CapturedAt: DateTimeOffset.UtcNow,
                Text: cleaned,
                Language: _engine.RecognizerLanguage.LanguageTag,
                Lines: lines,
                Duration: sw.Elapsed,
                AverageConfidence: avg);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(ex, "OCR recognize failed");
            _diagnostics?.Record(DiagnosticLevel.Warn, "ocr", "recognize failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
            return OcrResult.Empty(sw.Elapsed);
        }
    }
}
