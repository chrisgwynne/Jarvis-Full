using System.Diagnostics;
using System.IO;
using Jarvis.Core.Automation;

namespace Jarvis.Automation.Surfaces;

public sealed class FileSurface : IFileAutomationSurface
{
    public Task<string?> OpenAppAsync(string executable, string? arguments, CancellationToken cancellationToken)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = executable,
                Arguments = arguments ?? string.Empty,
                UseShellExecute = true
            };
            Process.Start(psi);
            return Task.FromResult<string?>(null);
        }
        catch (Exception ex)
        {
            return Task.FromResult<string?>(ex.Message);
        }
    }

    public Task<string?> OpenFileAsync(string path, CancellationToken cancellationToken)
    {
        try
        {
            if (!File.Exists(path) && !Directory.Exists(path))
                return Task.FromResult<string?>($"path not found: {path}");
            Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
            return Task.FromResult<string?>(null);
        }
        catch (Exception ex)
        {
            return Task.FromResult<string?>(ex.Message);
        }
    }

    public Task<string?> RevealAsync(string path, CancellationToken cancellationToken)
    {
        try
        {
            if (!File.Exists(path) && !Directory.Exists(path))
                return Task.FromResult<string?>($"path not found: {path}");
            Process.Start(new ProcessStartInfo { FileName = "explorer.exe", Arguments = $"/select,\"{path}\"", UseShellExecute = true });
            return Task.FromResult<string?>(null);
        }
        catch (Exception ex)
        {
            return Task.FromResult<string?>(ex.Message);
        }
    }

    public async Task<string?> CreateDraftAsync(string path, string content, bool overwrite, CancellationToken cancellationToken)
    {
        try
        {
            if (File.Exists(path) && !overwrite) return $"file exists and overwrite=false: {path}";
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            await File.WriteAllTextAsync(path, content, cancellationToken).ConfigureAwait(false);
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }
}
