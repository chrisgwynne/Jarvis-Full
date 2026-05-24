# Stand-in for the Chrome extension — exercises token auth + the ACK protocol.
param([int]$Port = 49321)

$tokenFile = Join-Path $env:APPDATA "Jarvis\bridge-token.txt"
if (-not (Test-Path $tokenFile)) { Write-Output "ERR: token file missing at $tokenFile"; exit 2 }
$token = (Get-Content $tokenFile -Raw).Trim()

function Connect-WithToken($t) {
    $client = New-Object System.Net.WebSockets.ClientWebSocket
    $uri = New-Object Uri("ws://127.0.0.1:$Port/?token=$t")
    $cts = New-Object System.Threading.CancellationTokenSource (5000)
    try { $client.ConnectAsync($uri, $cts.Token).Wait() } catch { return $null }
    return $client
}

# Step 1: wrong token — must be rejected.
$bad = Connect-WithToken "wrong-token-here"
if ($null -ne $bad) { Write-Output "ERR: connected with bad token"; exit 1 }
Write-Output "AUTH_REJECTS_WRONG_TOKEN: ok"

# Step 2: correct token — must connect.
$client = Connect-WithToken $token
if ($null -eq $client) { Write-Output "ERR: failed to connect with correct token"; exit 1 }
Write-Output "AUTH_ACCEPTS_RIGHT_TOKEN: ok"

function Send-Json($json) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object ArraySegment[byte] (,$bytes)
    $client.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
        (New-Object System.Threading.CancellationTokenSource (2000)).Token).Wait()
}

# Step 3: hello + a fake ack to a fictional commandId (just exercises the parse path).
Send-Json '{"type":"hello","browser":"chrome","version":"0.2.0"}'
Send-Json '{"type":"context","browser":"chrome","url":"https://news.ycombinator.com/","domain":"news.ycombinator.com","title":"Hacker News","selectedText":"hello","isTextInputFocused":false}'
Start-Sleep -Milliseconds 600
$client.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done",
    (New-Object System.Threading.CancellationTokenSource (1000)).Token).Wait()
Write-Output "CONTEXT_SENT_AND_CLOSED: ok"
