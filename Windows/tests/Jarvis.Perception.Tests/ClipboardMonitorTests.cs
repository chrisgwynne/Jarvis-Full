using FluentAssertions;
using Jarvis.Core.Perception;
using Xunit;

namespace Jarvis.Perception.Tests;

// ClipboardMonitor's actual Win32 listener requires a WPF Application and is integration-tested
// at runtime. Here we cover the parts we can: classifier interaction and the contract of
// ClipboardEntry / SemanticContentType.
public class ClipboardEntryContractTests
{
    [Fact]
    public void Text_entry_is_text_not_image()
    {
        var e = new ClipboardEntry(DateTimeOffset.UtcNow, SemanticContentType.Prose, "hi", null, null, "Notepad", "h");
        e.IsText.Should().BeTrue();
        e.IsImage.Should().BeFalse();
    }

    [Fact]
    public void Image_entry_is_image_not_text()
    {
        var e = new ClipboardEntry(DateTimeOffset.UtcNow, SemanticContentType.Image, null, 100, 200, "mspaint", "h");
        e.IsText.Should().BeFalse();
        e.IsImage.Should().BeTrue();
    }
}
