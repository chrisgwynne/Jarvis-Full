using System.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Jarvis.Perception.Clipboard;

/// <summary>
/// 8×8 grayscale average hash (aHash). Robust against tiny dimension/format changes,
/// strong enough to deduplicate "the same screenshot copied twice" while distinguishing
/// genuinely different images of the same size. Cost: one downscale + 64 byte reads.
/// </summary>
internal static class ImagePerceptualHash
{
    public static string Compute(BitmapSource source)
    {
        try
        {
            // Convert to a known small format we can read pixels from.
            var scaled = new TransformedBitmap(source, new ScaleTransform(8.0 / source.PixelWidth, 8.0 / source.PixelHeight));
            var converted = new FormatConvertedBitmap(scaled, PixelFormats.Gray8, BitmapPalettes.Gray256, 0);
            var pixels = new byte[64];
            converted.CopyPixels(pixels, 8, 0);
            double avg = 0;
            for (var i = 0; i < 64; i++) avg += pixels[i];
            avg /= 64.0;
            var sb = new StringBuilder(16);
            ulong bits = 0;
            for (var i = 0; i < 64; i++)
                if (pixels[i] >= avg) bits |= 1UL << i;
            return bits.ToString("X16");
        }
        catch
        {
            // Fall back to dimensions-only identity if pixel access fails (rare).
            return $"img:{source.PixelWidth}x{source.PixelHeight}:fmt{source.Format.BitsPerPixel}";
        }
    }
}
