param([int]$TargetPid)

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class P {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int c);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
"@

$script:found = @()
$cb = [P+EnumProc]{
    param($h,$l)
    [uint32]$ownerPid = 0
    [void][P]::GetWindowThreadProcessId($h, [ref]$ownerPid)
    if ($ownerPid -eq $TargetPid -and [P]::IsWindowVisible($h)) {
        $script:found += $h
    }
    return $true
}
[void][P]::EnumWindows($cb, [IntPtr]::Zero)

if ($script:found.Count -eq 0) {
    Write-Output "RESULT: NO_WINDOW pid=$TargetPid"
    exit 2
}

foreach ($h in $script:found) {
    $sb = New-Object System.Text.StringBuilder 256
    [void][P]::GetWindowText($h, $sb, 256)
    $title = $sb.ToString()
    $ex = [P]::GetWindowLong($h, -20)
    $hex = '0x{0:X}' -f $ex
    $topmost   = ($ex -band 0x00000008) -ne 0
    $transp    = ($ex -band 0x00000020) -ne 0
    $layered   = ($ex -band 0x00080000) -ne 0
    $toolwin   = ($ex -band 0x00000080) -ne 0
    $noact     = ($ex -band 0x08000000) -ne 0
    $r = New-Object P+RECT
    [void][P]::GetWindowRect($h, [ref]$r)
    Write-Output ("HWND={0} TITLE='{1}' EX={2} topmost={3} transparent={4} layered={5} toolwindow={6} noactivate={7} rect=[{8},{9},{10},{11}]" -f $h,$title,$hex,$topmost,$transp,$layered,$toolwin,$noact,$r.L,$r.T,$r.R,$r.B)
}

$h = $script:found[0]
[void][P]::SetCursorPos(300, 300); Start-Sleep -Milliseconds 700
$r1 = New-Object P+RECT; [void][P]::GetWindowRect($h, [ref]$r1)
[void][P]::SetCursorPos(900, 700); Start-Sleep -Milliseconds 700
$r2 = New-Object P+RECT; [void][P]::GetWindowRect($h, [ref]$r2)
Write-Output ("CURSOR_FOLLOW: pos1=[{0},{1}] pos2=[{2},{3}] dx={4} dy={5}" -f $r1.L,$r1.T,$r2.L,$r2.T,($r2.L-$r1.L),($r2.T-$r1.T))

$proc = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
if ($proc) {
    $cpu = $proc.CPU
    $ws  = [math]::Round($proc.WorkingSet64/1MB,1)
    $pm  = [math]::Round($proc.PrivateMemorySize64/1MB,1)
    $threads = $proc.Threads.Count
    Write-Output ("PERF: cpuSeconds={0} workingSetMB={1} privateMB={2} threads={3}" -f $cpu,$ws,$pm,$threads)
}

$settings = Join-Path $env:APPDATA "Jarvis\settings.json"
if (Test-Path $settings) {
    $sz = (Get-Item $settings).Length
    Write-Output "SETTINGS: present path='$settings' bytes=$sz"
} else {
    Write-Output "SETTINGS: MISSING"
}
