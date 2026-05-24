using Microsoft.Web.WebView2.Core;

namespace Jarvis.App.Overlay;

internal static class WebView2Runtime
{
    /// <summary>Returns null when no runtime is installed, otherwise the detected version string.</summary>
    public static string? DetectInstalledVersion()
    {
        try
        {
            // CoreWebView2Environment.GetAvailableBrowserVersionString returns null when the runtime
            // is missing rather than throwing — but on some preview builds it throws WebView2RuntimeNotFoundException.
            return CoreWebView2Environment.GetAvailableBrowserVersionString();
        }
        catch (WebView2RuntimeNotFoundException)
        {
            return null;
        }
        catch
        {
            return null;
        }
    }

    public const string DownloadUrl = "https://developer.microsoft.com/microsoft-edge/webview2/";
}
