using System.Text;

namespace Jarvis.Perception.Conversation;

/// <summary>
/// Streams text through and suppresses anything between known "hidden reasoning" tags
/// (e.g. <c>&lt;thinking&gt;…&lt;/thinking&gt;</c>). Designed to span chunk boundaries:
/// the stripper keeps a tiny buffer so a tag split across two HTTP packets is still
/// caught. Public methods are stateful — instantiate one per stream.
/// </summary>
public sealed class ThinkingTagStripper
{
    private static readonly string[] OpenTags  = { "&lt;thinking&gt;", "<thinking>", "<reasoning>", "<scratchpad>", "<analysis>" };
    private static readonly string[] CloseTags = { "&lt;/thinking&gt;", "</thinking>", "</reasoning>", "</scratchpad>", "</analysis>" };
    private static readonly int LookaheadCap = Math.Max(OpenTags.Max(t => t.Length), CloseTags.Max(t => t.Length));

    private readonly StringBuilder _buffer = new();
    private bool _suppressing;

    /// <summary>Push one chunk through the filter. Returns the chunk's contribution to
    /// the visible output. May be empty if the chunk is entirely inside a tag block.</summary>
    public string Push(string chunk)
    {
        if (string.IsNullOrEmpty(chunk)) return string.Empty;
        _buffer.Append(chunk);
        return Drain(flush: false);
    }

    /// <summary>Call once at end-of-stream so any buffered tail flushes (e.g. a chunk
    /// that landed mid-tag but the close never arrived).</summary>
    public string Flush() => Drain(flush: true);

    private string Drain(bool flush)
    {
        var output = new StringBuilder();
        var data = _buffer.ToString();
        var i = 0;

        while (i < data.Length)
        {
            if (_suppressing)
            {
                var closeIdx = FindEarliest(data, i, CloseTags, out var closeLen);
                if (closeIdx < 0)
                {
                    // No close tag yet — discard everything except the last LookaheadCap chars
                    // so the next chunk can still spot a split close tag.
                    if (!flush && data.Length - i <= LookaheadCap)
                    {
                        _buffer.Clear();
                        _buffer.Append(data, i, data.Length - i);
                    }
                    else
                    {
                        _buffer.Clear();
                    }
                    return output.ToString();
                }
                _suppressing = false;
                i = closeIdx + closeLen;
                continue;
            }

            var openIdx = FindEarliest(data, i, OpenTags, out var openLen);
            if (openIdx < 0)
            {
                // No open tag in the visible window. Emit everything except the trailing
                // lookahead (which might be the prefix of an open tag split across chunks).
                int safeEnd;
                if (flush) safeEnd = data.Length;
                else safeEnd = Math.Max(i, data.Length - LookaheadCap);
                if (safeEnd > i) output.Append(data, i, safeEnd - i);
                _buffer.Clear();
                _buffer.Append(data, safeEnd, data.Length - safeEnd);
                return output.ToString();
            }

            // Emit text up to the tag, then enter suppression mode.
            output.Append(data, i, openIdx - i);
            _suppressing = true;
            i = openIdx + openLen;
        }
        _buffer.Clear();
        return output.ToString();
    }

    private static int FindEarliest(string data, int start, string[] needles, out int matchedLength)
    {
        var bestIdx = -1;
        var bestLen = 0;
        foreach (var n in needles)
        {
            var idx = data.IndexOf(n, start, StringComparison.OrdinalIgnoreCase);
            if (idx >= 0 && (bestIdx < 0 || idx < bestIdx))
            {
                bestIdx = idx;
                bestLen = n.Length;
            }
        }
        matchedLength = bestLen;
        return bestIdx;
    }
}
