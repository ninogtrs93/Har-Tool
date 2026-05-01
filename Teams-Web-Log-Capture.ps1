param(
    [string]$ConfigPath = ".\\config.json"
)

$ErrorActionPreference = 'Stop'

function Write-StatusLine([string]$Message) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}

function Get-EdgePath {
    $candidates = @(
        "$env:ProgramFiles(x86)\\Microsoft\\Edge\\Application\\msedge.exe",
        "$env:ProgramFiles\\Microsoft\\Edge\\Application\\msedge.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    throw "Microsoft Edge niet gevonden op verwachte paden."
}

function Expand-EnvPath([string]$PathText) {
    return [Environment]::ExpandEnvironmentVariables($PathText)
}

function New-CdpMessage([int]$Id, [string]$Method, [hashtable]$Params = @{}) {
    return (@{ id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 8 -Compress)
}

function Send-CdpCommand($Socket, [int]$Id, [string]$Method, [hashtable]$Params = @{}) {
    $json = New-CdpMessage -Id $Id -Method $Method -Params $Params
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

function Read-CdpMessage($Socket, [int]$TimeoutMs = 200) {
    $buffer = New-Object byte[] 32768
    $all = New-Object System.Collections.Generic.List[byte]
    $cts = [Threading.CancellationTokenSource]::new($TimeoutMs)
    try {
        do {
            $segment = [System.ArraySegment[byte]]::new($buffer)
            $result = $Socket.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                return $null
            }
            if ($result.Count -gt 0) {
                $all.AddRange($buffer[0..($result.Count-1)])
            }
        } while (-not $result.EndOfMessage)
    }
    catch [System.OperationCanceledException] {
        return ""
    }

    if ($all.Count -eq 0) { return "" }
    return [System.Text.Encoding]::UTF8.GetString($all.ToArray())
}

function Add-CaptureEvent($obj) {
    $script:Events.Add($obj)
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

$edgeArgs = @(
    "--remote-debugging-port=$port",
    "--user-data-dir=$userDataDir",
    "--new-window",
    $config.teamsStartUrl
)
Start-Process -FilePath $edgePath -ArgumentList $edgeArgs | Out-Null
Write-StatusLine "Microsoft Teams wordt geopend"
Write-StatusLine "Recorder draait vanaf browserstart"
Write-StatusLine "Log in bij Teams en open Roger365"

Start-Sleep -Seconds 2
$versionInfo = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version"
$browserWs = $versionInfo.webSocketDebuggerUrl
if (-not $browserWs) { throw "Kon browser WebSocket endpoint niet vinden." }

$socket = [System.Net.WebSockets.ClientWebSocket]::new()
$socket.ConnectAsync([Uri]$browserWs, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

$id = 1
Send-CdpCommand $socket $id 'Target.setDiscoverTargets' @{ discover = $true }; $id++
Send-CdpCommand $socket $id 'Target.setAutoAttach' @{ autoAttach = $true; waitForDebuggerOnStart = $false; flatten = $true }; $id++

$script:Events = New-Object System.Collections.Generic.List[object]
$targets = @{}
$hostsByTarget = @{}
$loaderToTarget = @{}
$state = [ordered]@{
    RogerHostGezien = $false
    SignalRHostGezien = $false
    LoginStatusGezien = $false
    PresenceNegotiateGezien = $false
    WebSocketGezien = $false
    TotaalEvents = 0
    TotaalRequests = 0
    EersteMatchTimestamp = $null
    LaatsteMatchTimestamp = $null
    RogerHostsGezien = New-Object System.Collections.Generic.HashSet[string]
    SignalRHostsGezien = New-Object System.Collections.Generic.HashSet[string]
}

$commandBuffer = ""
$nextStatus = (Get-Date).AddSeconds([int]$config.statusIntervalSeconds)
$deadline = (Get-Date).AddMinutes([int]$config.sessionTimeoutMinutes)
$running = $true

while ($running) {
    while ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') {
            $cmd = $commandBuffer.Trim().ToLowerInvariant()
            $commandBuffer = ""
            if ($cmd) { Write-Host ""; Write-StatusLine "Commando ontvangen: $cmd" }
            switch ($cmd) {
                'opslaan' { $running = $false; break }
                'annuleren' {
                    Write-StatusLine "Sessie geannuleerd."
                    Remove-Item -Path $sessionFolder -Recurse -Force -ErrorAction SilentlyContinue
                    exit 0
                }
                'status' {
                    Write-StatusLine ("Status => Roger host gezien: {0} | SignalR host gezien: {1} | LoginStatus gezien: {2} | presenceHub/negotiate gezien: {3} | WebSocket gezien: {4} | Events opgeslagen: {5}" -f @(
                        $(if($state.RogerHostGezien){'Ja'}else{'Nee'}),
                        $(if($state.SignalRHostGezien){'Ja'}else{'Nee'}),
                        $(if($state.LoginStatusGezien){'Ja'}else{'Nee'}),
                        $(if($state.PresenceNegotiateGezien){'Ja'}else{'Nee'}),
                        $(if($state.WebSocketGezien){'Ja'}else{'Nee'}),
                        $state.TotaalEvents
                    ))
                }
                default {
                    if ($cmd) { Write-StatusLine "Onbekend commando. Gebruik: opslaan | annuleren | status" }
                }
            }
        } elseif ($k.Key -eq 'Backspace') {
            if ($commandBuffer.Length -gt 0) { $commandBuffer = $commandBuffer.Substring(0, $commandBuffer.Length-1) }
        } elseif (-not [char]::IsControl($k.KeyChar)) {
            $commandBuffer += $k.KeyChar
        }
    }

    $raw = Read-CdpMessage -Socket $socket -TimeoutMs ([int]$config.pollIntervalMs)
    if ($null -eq $raw) { break }
    if ($raw -ne "") {
        $msg = $raw | ConvertFrom-Json
        if ($msg.method -eq 'Target.attachedToTarget') {
            $sid = $msg.params.sessionId
            $ti = $msg.params.targetInfo
            $targets[$ti.targetId] = $ti
            Send-CdpCommand $socket $id 'Network.enable' @{ } ; $id++
            Send-CdpCommand $socket $id 'Runtime.enable' @{ sessionId = $sid } ; $id++
        }

        if ($msg.method -like 'Network.*') {
            $state.TotaalEvents++
            $event = [ordered]@{ timestamp = (Get-Date).ToString('o'); method = $msg.method; params = $msg.params }
            Add-CaptureEvent $event

            if ($msg.method -eq 'Network.requestWillBeSent') {
                $state.TotaalRequests++
                $url = [string]$msg.params.request.url
                $uri = $null
                try { $uri = [Uri]$url } catch {}
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

            if ($msg.method -eq 'Network.webSocketCreated' -or $msg.method -eq 'Network.webSocketWillSendHandshakeRequest' -or $msg.method -eq 'Network.webSocketHandshakeResponseReceived') {
                $state.WebSocketGezien = $true
                if ($msg.method -eq 'Network.webSocketHandshakeResponseReceived') {
                    if ([int]$msg.params.response.status -eq 101) {
                        if (-not $state.EersteMatchTimestamp) { $state.EersteMatchTimestamp = (Get-Date).ToString('o') }
                        $state.LaatsteMatchTimestamp = (Get-Date).ToString('o')
                    }
                }
            }
        }
    }

    if ((Get-Date) -ge $nextStatus) {
        Write-StatusLine "Recorder draait..."
        Write-StatusLine "Roger host gezien: $(if($state.RogerHostGezien){'Ja'}else{'Nee'})"
        Write-StatusLine "SignalR host gezien: $(if($state.SignalRHostGezien){'Ja'}else{'Nee'})"
        Write-StatusLine "LoginStatus gezien: $(if($state.LoginStatusGezien){'Ja'}else{'Nee'})"
        Write-StatusLine "presenceHub/negotiate gezien: $(if($state.PresenceNegotiateGezien){'Ja'}else{'Nee'})"
        Write-StatusLine "WebSocket gezien: $(if($state.WebSocketGezien){'Ja'}else{'Nee'})"
        Write-StatusLine "Events opgeslagen: $($state.TotaalEvents)"
        Write-StatusLine "Typ commando: opslaan | annuleren | status"
        $nextStatus = (Get-Date).AddSeconds([int]$config.statusIntervalSeconds)
    }

    if ((Get-Date) -ge $deadline) {
        Write-StatusLine "Sessie-timeout bereikt, automatisch opslaan."
        $running = $false
    }
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
