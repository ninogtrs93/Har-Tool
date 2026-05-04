param(
    [string]$ConfigPath = ".\\config.json"
)

$ErrorActionPreference = 'Stop'

function Write-StatusLine([string]$Message) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}

function Expand-EnvPath([string]$PathText) {
    return [Environment]::ExpandEnvironmentVariables($PathText)
}

function Get-EdgePath {
    $checked = New-Object System.Collections.Generic.List[string]
    $appPathKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )
    foreach ($key in $appPathKeys) {
        $checked.Add("Registry: $key")
        try {
            $p = (Get-ItemProperty -Path $key -ErrorAction Stop).'(default)'
            if (-not $p) { $p = (Get-ItemProperty -Path $key -ErrorAction Stop).Path }
            if ($p -and (Test-Path $p)) { return $p }
        } catch {}
    }
    $checked.Add('PATH: msedge.exe')
    try {
        $cmd = Get-Command msedge.exe -ErrorAction Stop
        if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) { return $cmd.Source }
    } catch {}
    $stablePaths = @(
        (Join-Path $Env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path ${Env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $Env:LocalAppData 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($p in $stablePaths) {
        if ($p) { $checked.Add("Bestand: $p") }
        if ($p -and (Test-Path $p)) { return $p }
    }
    $channelPaths = @(
        (Join-Path $Env:ProgramFiles 'Microsoft\Edge Beta\Application\msedge.exe'),
        (Join-Path ${Env:ProgramFiles(x86)} 'Microsoft\Edge Beta\Application\msedge.exe'),
        (Join-Path $Env:LocalAppData 'Microsoft\Edge Beta\Application\msedge.exe'),
        (Join-Path $Env:ProgramFiles 'Microsoft\Edge Dev\Application\msedge.exe'),
        (Join-Path ${Env:ProgramFiles(x86)} 'Microsoft\Edge Dev\Application\msedge.exe'),
        (Join-Path $Env:LocalAppData 'Microsoft\Edge Dev\Application\msedge.exe'),
        (Join-Path $Env:LocalAppData 'Microsoft\Edge SxS\Application\msedge.exe')
    )
    foreach ($p in $channelPaths) {
        if ($p) { $checked.Add("Fallback: $p") }
        if ($p -and (Test-Path $p)) { return $p }
    }
    $detail = ($checked | ForEach-Object { " - $_" }) -join [Environment]::NewLine
    throw @"
Microsoft Edge kon niet worden gevonden.

Gecontroleerde locaties:
$detail

Controleer of Microsoft Edge is geïnstalleerd (bij voorkeur Stable).
Start Edge eventueel eenmalig handmatig en probeer daarna opnieuw.
"@
}

function New-CdpMessage([int]$Id, [string]$Method, [hashtable]$Params = @{}) {
    return (@{ id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 8 -Compress)
}

function Send-CdpCommand($Socket, [int]$Id, [string]$Method, [hashtable]$Params = @{}) {
    if ($Socket.State -notin @([System.Net.WebSockets.WebSocketState]::Open,[System.Net.WebSockets.WebSocketState]::CloseSent)) { return }
    $json = New-CdpMessage -Id $Id -Method $Method -Params $Params
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    [void]$Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

function Connect-CdpSocket([int]$Port, [int]$MaxAttempts = 3, [int]$DelayMs = 1200) {
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-StatusLine "CDP status: CdpReconnectAttempt ($attempt/$MaxAttempts)"
            $versionInfo = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -ErrorAction Stop
            $browserWs = $versionInfo.webSocketDebuggerUrl
            if (-not $browserWs) { throw "webSocketDebuggerUrl ontbreekt" }
            $ws = [System.Net.WebSockets.ClientWebSocket]::new()
            [void]$ws.ConnectAsync([Uri]$browserWs, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
            Write-StatusLine "CDP status: CdpConnected"
            return $ws
        } catch {
            if ($attempt -lt $MaxAttempts) {
                Write-StatusLine "Verbinding met browserlog tijdelijk verbroken. Probeert opnieuw..."
                Start-Sleep -Milliseconds $DelayMs
            }
        }
    }
    Write-StatusLine "CDP status: CdpReconnectFailed"
    return $null
}

function Read-CdpMessage($Socket, [int]$TimeoutMs = 200) {
    $invalidStates = @(
        [System.Net.WebSockets.WebSocketState]::Aborted,
        [System.Net.WebSockets.WebSocketState]::Closed,
        [System.Net.WebSockets.WebSocketState]::CloseReceived,
        [System.Net.WebSockets.WebSocketState]::Connecting,
        [System.Net.WebSockets.WebSocketState]::None
    )

    if ($invalidStates -contains $Socket.State) {
        return @{ Status = 'Disconnected'; Reason = "WebSocket state is $($Socket.State)"; Payload = '' }
    }

    $buffer = New-Object byte[] 32768
    $stream = New-Object System.IO.MemoryStream
    $cts = [Threading.CancellationTokenSource]::new($TimeoutMs)
    try {
        do {
            if ($invalidStates -contains $Socket.State) {
                return @{ Status = 'Disconnected'; Reason = "WebSocket state is $($Socket.State)"; Payload = '' }
            }
            $segment = [System.ArraySegment[byte]]::new($buffer)
            $result = $Socket.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                return @{ Status = 'Disconnected'; Reason = 'Close frame ontvangen'; Payload = '' }
            }
            if ($result.Count -gt 0) {
                $stream.Write($buffer, 0, $result.Count)
            }
        } while (-not $result.EndOfMessage)
    }
    catch [System.OperationCanceledException] {
        return @{ Status = 'Timeout'; Reason = ''; Payload = '' }
    }
    catch {
        return @{ Status = 'Disconnected'; Reason = $_.Exception.Message; Payload = '' }
    }
    finally {
        $cts.Dispose()
    }

    if ($stream.Length -eq 0) { return @{ Status = 'NoData'; Reason = ''; Payload = '' } }
    try {
        return @{ Status = 'Ok'; Reason = ''; Payload = [System.Text.Encoding]::UTF8.GetString($stream.ToArray()) }
    }
    catch {
        return @{ Status = 'DecodeError'; Reason = $_.Exception.Message; Payload = '' }
    }
    finally {
        $stream.Dispose()
    }
}

function Add-CaptureEvent($obj) { $script:Events.Add($obj) }
function Write-StatusBlock($state) {
    Write-StatusLine "Recorder draait..."
    Write-StatusLine "Roger host gezien: $(if($state.RogerHostGezien){'Ja'}else{'Nee'})"
    Write-StatusLine "SignalR host gezien: $(if($state.SignalRHostGezien){'Ja'}else{'Nee'})"
    Write-StatusLine "LoginStatus gezien: $(if($state.LoginStatusGezien){'Ja'}else{'Nee'})"
    Write-StatusLine "presenceHub/negotiate gezien: $(if($state.PresenceNegotiateGezien){'Ja'}else{'Nee'})"
    Write-StatusLine "WebSocket gezien: $(if($state.WebSocketGezien){'Ja'}else{'Nee'})"
    Write-StatusLine "Events opgeslagen: $($state.TotaalEvents)"
    Write-StatusLine "[1] Opslaan  [2] Status  [3] Annuleren"
}

$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$outputRoot = Expand-EnvPath $config.outputRoot
$sessionStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sessionFolder = Join-Path $outputRoot "session-$sessionStamp"
New-Item -ItemType Directory -Path $sessionFolder -Force | Out-Null

Write-StatusLine "Teams Web Log Capture gestart"
Write-StatusLine "Microsoft Edge wordt geopend"
$edgePath = Get-EdgePath
$port = [int]$config.edgeRemoteDebugPort
$userDataDir = Join-Path $env:TEMP "teams-capture-$sessionStamp"
New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
$edgeArgs = @("--remote-debugging-port=$port","--user-data-dir=$userDataDir","--new-window",$config.teamsStartUrl)
$null = Start-Process -FilePath $edgePath -ArgumentList $edgeArgs
Write-StatusLine "Microsoft Teams wordt geopend"
Write-StatusLine "Recorder draait vanaf browserstart"
Write-StatusLine "Log in bij Teams en open Roger365"
Write-StatusLine "Sneltoetsen: [1] Opslaan  [2] Status  [3] Annuleren"
Start-Sleep -Seconds 2

$socket = Connect-CdpSocket -Port $port
if (-not $socket) {
    Write-StatusLine "Browserlogverbinding gestopt. Sluit en start de tool opnieuw als dit blijft gebeuren."
    exit 1
}

$id = 1
Send-CdpCommand $socket $id 'Target.setDiscoverTargets' @{ discover = $true }; $id++
Send-CdpCommand $socket $id 'Target.setAutoAttach' @{ autoAttach = $true; waitForDebuggerOnStart = $false; flatten = $true }; $id++

$script:Events = New-Object System.Collections.Generic.List[object]
$targets = @{}
$hostsByTarget = @{}
$state = [ordered]@{ RogerHostGezien=$false; SignalRHostGezien=$false; LoginStatusGezien=$false; PresenceNegotiateGezien=$false; WebSocketGezien=$false; TotaalEvents=0; TotaalRequests=0; EersteMatchTimestamp=$null; LaatsteMatchTimestamp=$null; RogerHostsGezien=New-Object System.Collections.Generic.HashSet[string]; SignalRHostsGezien=New-Object System.Collections.Generic.HashSet[string] }

$nextStatus = (Get-Date).AddSeconds([int]$config.statusIntervalSeconds)
$deadline = (Get-Date).AddMinutes([int]$config.sessionTimeoutMinutes)
$running = $true
$disconnectLogged = $false
$cdpReadStopped = $false
$errorWindowSeconds = 10
$errorThreshold = 3
$recentDisconnects = @{}

while ($running) {
    while ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        switch ($k.KeyChar) {
            '1' { Write-StatusLine "Actie: Opslaan"; $running = $false }
            '2' { Write-StatusLine "Actie: Status"; Write-StatusBlock -state $state }
            '3' { Write-StatusLine "Actie: Annuleren"; Remove-Item -Path $sessionFolder -Recurse -Force -ErrorAction SilentlyContinue; exit 0 }
        }
    }

    if ($cdpReadStopped) {
        Start-Sleep -Milliseconds ([int]$config.pollIntervalMs)
    } else {
        $read = Read-CdpMessage -Socket $socket -TimeoutMs ([int]$config.pollIntervalMs)
        switch ($read.Status) {
        'Disconnected' {
            if (-not $disconnectLogged) {
                Write-StatusLine "CDP status: CdpDisconnected"
                Write-StatusLine "Verbinding met browserlog tijdelijk verbroken. Probeert opnieuw..."
                $disconnectLogged = $true
            }
            try { $socket.Dispose() } catch {}
            $socket = Connect-CdpSocket -Port $port
            if ($socket) {
                $disconnectLogged = $false
$cdpReadStopped = $false
$errorWindowSeconds = 10
$errorThreshold = 3
$recentDisconnects = @{}
                Send-CdpCommand $socket $id 'Target.setDiscoverTargets' @{ discover = $true }; $id++
                Send-CdpCommand $socket $id 'Target.setAutoAttach' @{ autoAttach = $true; waitForDebuggerOnStart = $false; flatten = $true }; $id++
            } else {
                Write-StatusLine "CDP status: CdpReadLoopStopped"
                Write-StatusLine "Browserlogverbinding gestopt. Sluit en start de tool opnieuw als dit blijft gebeuren."
                $running = $false
            }
            continue
        }
        'DecodeError' {
            Write-StatusLine "Waarschuwing: CDP decodefout, bericht overgeslagen."
            continue
        }
        'Timeout' { }
        'NoData' { }
        'Ok' {
            $raw = $read.Payload
            $msg = $raw | ConvertFrom-Json
            if ($msg.method -eq 'Target.attachedToTarget') {
                $ti = $msg.params.targetInfo
                $targets[$ti.targetId] = $ti
                Send-CdpCommand $socket $id 'Network.enable' @{ } ; $id++
            }
            if ($msg.method -like 'Network.*') {
                $state.TotaalEvents++
                $event = [ordered]@{ timestamp = (Get-Date).ToString('o'); method = $msg.method; params = $msg.params }
                Add-CaptureEvent $event
                if ($msg.method -eq 'Network.requestWillBeSent') {
                    $state.TotaalRequests++
                    $url = [string]$msg.params.request.url
                    $uri = $null; try { $uri = [Uri]$url } catch {}
                    $host = if ($uri) { $uri.Host.ToLowerInvariant() } else { '' }
                    if (-not $hostsByTarget.ContainsKey('global')) { $hostsByTarget['global'] = New-Object System.Collections.Generic.HashSet[string] }
                    if ($host) { [void]$hostsByTarget['global'].Add($host) }
                    $isRoger = $config.rogerHosts -contains $host
                    $isSignalR = $config.signalRHosts -contains $host
                    $hasLogin = $url -like "*/Account/LoginStatus*"
                    $hasPresence = $url -like "*/presenceHub/negotiate*"
                    if ($isRoger -or $isSignalR -or $hasLogin -or $hasPresence) {
                        if (-not $state.EersteMatchTimestamp) { $state.EersteMatchTimestamp = (Get-Date).ToString('o') }
                        $state.LaatsteMatchTimestamp = (Get-Date).ToString('o')
                    }
                    if ($isRoger) { $state.RogerHostGezien = $true; [void]$state.RogerHostsGezien.Add($host) }
                    if ($isSignalR) { $state.SignalRHostGezien = $true; [void]$state.SignalRHostsGezien.Add($host) }
                    if ($hasLogin) { $state.LoginStatusGezien = $true }
                    if ($hasPresence) { $state.PresenceNegotiateGezien = $true }
                }
                if ($msg.method -in @('Network.webSocketCreated','Network.webSocketWillSendHandshakeRequest','Network.webSocketHandshakeResponseReceived')) {
                    $state.WebSocketGezien = $true
                    if ($msg.method -eq 'Network.webSocketHandshakeResponseReceived' -and [int]$msg.params.response.status -eq 101) {
                        if (-not $state.EersteMatchTimestamp) { $state.EersteMatchTimestamp = (Get-Date).ToString('o') }
                        $state.LaatsteMatchTimestamp = (Get-Date).ToString('o')
                    }
                }
            }
        }
        }
    }

    if ((Get-Date) -ge $nextStatus) {
        Write-StatusBlock -state $state
        $nextStatus = (Get-Date).AddSeconds([int]$config.statusIntervalSeconds)
    }
    if ((Get-Date) -ge $deadline) { Write-StatusLine "Sessie-timeout bereikt, automatisch opslaan."; $running = $false }
}

$capturePath = Join-Path $sessionFolder 'capture.ndjson'
$Events | ForEach-Object { $_ | ConvertTo-Json -Depth 15 -Compress } | Set-Content -Path $capturePath -Encoding UTF8
$summary = [ordered]@{
    "Roger host gezien" = $(if($state.RogerHostGezien){"Ja"}else{"Nee"})
    "SignalR host gezien" = $(if($state.SignalRHostGezien){"Ja"}else{"Nee"})
    "LoginStatus gezien" = $(if($state.LoginStatusGezien){"Ja"}else{"Nee"})
    "presenceHub/negotiate gezien" = $(if($state.PresenceNegotiateGezien){"Ja"}else{"Nee"})
    "WebSocket gezien" = $(if($state.WebSocketGezien){"Ja"}else{"Nee"})
    "Totaal aantal events" = $state.TotaalEvents
    "Totaal aantal requests" = $state.TotaalRequests
    "Eerste match timestamp" = $state.EersteMatchTimestamp
    "Laatste match timestamp" = $state.LaatsteMatchTimestamp
    "Roger hosts gezien" = @($state.RogerHostsGezien)
    "SignalR hosts gezien" = @($state.SignalRHostsGezien)
    "Outputmap" = $sessionFolder
}
$summary | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $sessionFolder 'summary.json') -Encoding UTF8
$targets.Values | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $sessionFolder 'targets.json') -Encoding UTF8
$hostsByTargetOut = @{}
foreach ($k in $hostsByTarget.Keys) { $hostsByTargetOut[$k] = @($hostsByTarget[$k]) }
$hostsByTargetOut | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $sessionFolder 'hosts-by-target.json') -Encoding UTF8
$txt = @(
"Teams Web Log Capture samenvatting",
"Roger host gezien: $($summary['Roger host gezien'])",
"SignalR host gezien: $($summary['SignalR host gezien'])",
"LoginStatus gezien: $($summary['LoginStatus gezien'])",
"presenceHub/negotiate gezien: $($summary['presenceHub/negotiate gezien'])",
"WebSocket gezien: $($summary['WebSocket gezien'])",
"Totaal aantal events: $($summary['Totaal aantal events'])",
"Totaal aantal requests: $($summary['Totaal aantal requests'])",
"Eerste match timestamp: $($summary['Eerste match timestamp'])",
"Laatste match timestamp: $($summary['Laatste match timestamp'])",
"Roger hosts gezien: $((@($summary['Roger hosts gezien']) -join ', '))",
"SignalR hosts gezien: $((@($summary['SignalR hosts gezien']) -join ', '))",
"Outputmap: $($summary['Outputmap'])"
)
$txt | Set-Content -Path (Join-Path $sessionFolder 'samenvatting.txt') -Encoding UTF8
Write-StatusLine "Bestanden opgeslagen in: $sessionFolder"
