using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Media.Imaging;
using FluentAssertions;
using Jarvis.Perception.Clipboard;
using Xunit;

namespace Jarvis.Perception.Tests;

public class ImagePerceptualHashTests
{
    private static BitmapSource MakeBitmap(int w, int h, Action<Graphics> draw)
    {
        using var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.White);
            draw(g);
        }
        using var ms = new MemoryStream();
        bmp.Save(ms, ImageFormat.Png);
        ms.Position = 0;
        var decoder = BitmapDecoder.Create(ms, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        return decoder.Frames[0];
    }

    [Fact]
    public void Same_image_hashes_to_same_value()
    {
        var a = MakeBitmap(120, 80, g => g.FillRectangle(Brushes.Black, 20, 20, 30, 30));
        var b = MakeBitmap(120, 80, g => g.FillRectangle(Brushes.Black, 20, 20, 30, 30));
        ImagePerceptualHash.Compute(a).Should().Be(ImagePerceptualHash.Compute(b));
    }

    [Fact]
    public void Different_images_same_size_hash_differently()
    {
        var a = MakeBitmap(120, 80, g => g.FillRectangle(Brushes.Black, 5, 5, 50, 50));
        var b = MakeBitmap(120, 80, g => g.FillRectangle(Brushes.Black, 60, 20, 50, 50));
        ImagePerceptualHash.Compute(a).Should().NotBe(ImagePerceptualHash.Compute(b));
    }

    [Fact]
    public void Hash_is_16_hex_chars()
    {
        var a = MakeBitmap(60, 40, g => g.FillRectangle(Brushes.Black, 1, 1, 10, 10));
        var hash = ImagePerceptualHash.Compute(a);
        hash.Length.Should().Be(16);
    }
}
