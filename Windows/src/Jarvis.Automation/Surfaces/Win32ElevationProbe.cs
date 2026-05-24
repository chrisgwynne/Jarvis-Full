using System.Diagnostics;
using System.Runtime.InteropServices;
using Jarvis.Core.Automation;

namespace Jarvis.Automation.Surfaces;

/// <summary>
/// Compares the integrity level of a target window's owning process against the
/// current process. If the target is elevated and we are not, SendInput / SetForegroundWindow
/// will be silently dropped by UIPI — we surface that as a deterministic refusal
/// instead of letting the audit log say "Succeeded".
/// </summary>
public sealed class Win32ElevationProbe : IElevationProbe
{
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr hObject);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass,
        IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, [MarshalAs(UnmanagedType.Bool)] bool bInheritHandle, uint dwProcessId);

    private const uint TOKEN_QUERY = 0x0008;
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const int TokenIntegrityLevel = 25;

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_MANDATORY_LABEL { public IntPtr Sid; public uint Attributes; }

    [DllImport("advapi32.dll", SetLastError = true)] private static extern int GetSidSubAuthorityCount(IntPtr pSid);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern IntPtr GetSidSubAuthority(IntPtr pSid, uint nSubAuthority);

    private readonly Lazy<int> _selfIntegrity = new(() => GetIntegrityOfCurrentProcess());

    public bool ForegroundRequiresElevation() => WindowRequiresElevation(GetForegroundWindow());

    public bool WindowRequiresElevation(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return false;
        if (GetWindowThreadProcessId(hwnd, out var pid) == 0 || pid == 0) return false;
        try
        {
            var target = GetIntegrityOfProcess((int)pid);
            return target > _selfIntegrity.Value;
        }
        catch
        {
            return false;
        }
    }

    private static int GetIntegrityOfCurrentProcess()
    {
        try { return GetIntegrityOfProcess(Process.GetCurrentProcess().Id); }
        catch { return 0; }
    }

    private static int GetIntegrityOfProcess(int processId)
    {
        var procHandle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)processId);
        if (procHandle == IntPtr.Zero) return 0;
        try
        {
            if (!OpenProcessToken(procHandle, TOKEN_QUERY, out var tokenHandle)) return 0;
            try
            {
                GetTokenInformation(tokenHandle, TokenIntegrityLevel, IntPtr.Zero, 0, out var size);
                if (size == 0) return 0;
                var buf = Marshal.AllocHGlobal(size);
                try
                {
                    if (!GetTokenInformation(tokenHandle, TokenIntegrityLevel, buf, size, out _)) return 0;
                    var label = Marshal.PtrToStructure<TOKEN_MANDATORY_LABEL>(buf);
                    var count = GetSidSubAuthorityCount(label.Sid);
                    var subPtr = GetSidSubAuthority(label.Sid, (uint)(count - 1));
                    return Marshal.ReadInt32(subPtr);
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            finally { CloseHandle(tokenHandle); }
        }
        finally { CloseHandle(procHandle); }
    }
}
