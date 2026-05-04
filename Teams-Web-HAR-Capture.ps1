param([string]$ConfigPath = '.\\config.json')
$ErrorActionPreference='Stop'
function Log($m){ Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" }
function EdgePath {
  $keys=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe')
  foreach($k in $keys){ try{ $p=(Get-ItemProperty -Path $k -ErrorAction Stop).'(default)'; if($p -and (Test-Path $p)){return $p}}catch{} }
  try{ $c=Get-Command msedge.exe -ErrorAction Stop; if($c.Source){return $c.Source}}catch{}
  $paths=@("$Env:ProgramFiles\Microsoft\Edge\Application\msedge.exe","${Env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe","$Env:LocalAppData\Microsoft\Edge\Application\msedge.exe")
  foreach($p in $paths){ if(Test-Path $p){ return $p } }
  throw "Microsoft Edge niet gevonden. Installeer Edge of controleer App Paths/PATH."
}
function FindFreePort([int]$start){ for($p=$start;$p -lt ($start+30);$p++){ try{$l=[System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.1'),$p);$l.Start();$l.Stop();return $p}catch{} } throw 'Geen vrije localhost poort gevonden.' }

$config=Get-Content -Raw $ConfigPath|ConvertFrom-Json
$outputRoot=[Environment]::ExpandEnvironmentVariables($config.outputRoot)
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$sessionId="session-$stamp"
$sessionFolder=Join-Path $outputRoot $sessionId
New-Item -ItemType Directory -Force -Path $sessionFolder|Out-Null
$harPath=Join-Path $sessionFolder ("TeamsWeb-HAR-"+(Get-Date -Format 'yyyy-MM-dd-HHmmss')+'.har')
$statusLog=Join-Path $sessionFolder 'extension-status.log'

$state=[ordered]@{ command='idle'; extensionConnected=$false; harReady=$false; harWarnings=@(); latestUrls=New-Object System.Collections.Generic.List[string] }
$port=FindFreePort([int]$config.localhostPortStart)
$base="http://127.0.0.1:$port"

$listener=[System.Net.HttpListener]::new(); $listener.Prefixes.Add("$base/"); $listener.Start()
$job=Start-Job -ArgumentList $listener,$state,$harPath,$statusLog -ScriptBlock {
  param($listener,$state,$harPath,$statusLog)
  while($listener.IsListening){
    try{ $ctx=$listener.GetContext(); $req=$ctx.Request; $res=$ctx.Response
      $res.Headers['Access-Control-Allow-Origin']='*'; $res.Headers['Access-Control-Allow-Headers']='Content-Type'; $res.Headers['Access-Control-Allow-Methods']='GET, POST, OPTIONS'
      if($req.HttpMethod -eq 'OPTIONS'){ $res.StatusCode=200; $res.Close(); continue }
      $path=$req.Url.AbsolutePath
      if($path -eq '/command'){
        $obj=@{command=$state.command}|ConvertTo-Json -Compress
        $bytes=[Text.Encoding]::UTF8.GetBytes($obj); $res.OutputStream.Write($bytes,0,$bytes.Length); $res.Close(); continue
      }
      if($path -eq '/status'){
        $sr=New-Object IO.StreamReader($req.InputStream); $body=$sr.ReadToEnd(); Add-Content -Path $statusLog -Value ("$(Get-Date -Format o) $body")
        $state.extensionConnected=$true
        $obj=$body|ConvertFrom-Json
        if($obj.url){ if($state.latestUrls.Count -gt 100){ $state.latestUrls.RemoveAt(0)}; $state.latestUrls.Add($obj.url) }
        $res.StatusCode=200; $res.Close(); continue
      }
      if($path -eq '/har'){
        $sr=New-Object IO.StreamReader($req.InputStream); $body=$sr.ReadToEnd(); $payload=$body|ConvertFrom-Json -Depth 100
        $payload.har|ConvertTo-Json -Depth 100 | Set-Content -Path $harPath -Encoding UTF8
        $state.harWarnings=@($payload.warnings)
        $state.harReady=$true; $state.command='idle'
        $res.StatusCode=200; $res.Close(); continue
      }
      $res.StatusCode=404; $res.Close()
    } catch {}
  }
}

Log 'Teams Web HAR Capture gestart'; Log 'Edge wordt geopend'; Log 'DevTools wordt automatisch geopend'; Log 'HAR-opname draait vanaf browserstart'
Log 'Log in bij Teams en open Roger365'; Log 'Reproduceer het probleem'; Log 'Druk op 1 om de HAR op te slaan'
Log "Let op: een HAR-bestand kan gevoelige gegevens bevatten, zoals tokens, cookies, headers en URL's. Deel dit bestand alleen met vertrouwde supportmedewerkers."

$edge=EdgePath
$tempProfile=Join-Path $env:TEMP "teams-har-$stamp"; New-Item -ItemType Directory -Force -Path $tempProfile|Out-Null
$ext=(Resolve-Path (Join-Path $PSScriptRoot 'extension')).Path
$args=@("--user-data-dir=$tempProfile","--auto-open-devtools-for-tabs","--load-extension=$ext","--disable-extensions-except=$ext",$config.teamsUrl)
$p=Start-Process -FilePath $edge -ArgumentList $args -PassThru

$next=(Get-Date).AddSeconds([int]$config.statusIntervalSeconds)
$start=Get-Date
$running=$true
while($running){
  while([Console]::KeyAvailable){ $k=[Console]::ReadKey($true); switch($k.KeyChar){
    '1' { Log 'HAR export gestart...'; $state.command='exportHar'; $deadline=(Get-Date).AddSeconds([int]$config.exportTimeoutSeconds); while((Get-Date)-lt $deadline -and -not $state.harReady){ Start-Sleep -Milliseconds 250 }
          if($state.harReady){ Log "HAR ontvangen: $harPath"; $running=$false } else { Log 'Fout: timeout bij HAR export. Probeer opnieuw met 1 of annuleer met 3.'; $state.command='idle' } }
    '2' { Log "Status: Edge running: $(if($p.HasExited){'Nee'}else{'Ja'}) | extension connected: $(if($state.extensionConnected){'Ja'}else{'Nee'}) | HAR export ready: $(if($state.harReady){'Ja'}else{'Nee'})"; Log '[1] HAR opslaan  [2] Status  [3] Annuleren' }
    '3' { Log 'Geannuleerd door gebruiker.'; $running=$false; $state.harReady=$false }
  }}
  if((Get-Date)-ge $next){ $elapsed=[int]((Get-Date)-$start).TotalSeconds; Log "Recorder draait... elapsed ${elapsed}s | Edge running: $(if($p.HasExited){'Nee'}else{'Ja'}) | extension connected: $(if($state.extensionConnected){'Ja'}else{'Nee'}) | HAR export ready: $(if($state.harReady){'Ja'}else{'Nee'})"; Log '[1] HAR opslaan  [2] Status  [3] Annuleren'; $next=(Get-Date).AddSeconds([int]$config.statusIntervalSeconds) }
  Start-Sleep -Milliseconds 200
}

if(Test-Path $harPath){
  $har = Get-Content -Raw $harPath | ConvertFrom-Json -Depth 100
  $entries=@($har.log.entries)
  $urls=$entries|ForEach-Object{$_.request.url}
  $hosts=$urls|ForEach-Object{ try{([uri]$_).Host.ToLowerInvariant()}catch{''} }|Where-Object{$_}|Select-Object -Unique
  $wsSeen = ($urls | Where-Object { $_ -like 'ws*://*' }).Count -gt 0
  $status101 = (@($entries|Where-Object{$_.response.status -eq 101}).Count -gt 0)
  $matchUrls=@()
  foreach($m in $config.markerPaths){ $matchUrls += $urls | Where-Object { $_ -like "*$m*" } }
  $summary=[ordered]@{
    'HAR bestaat'='Ja'; 'HAR grootte bytes'=(Get-Item $harPath).Length; 'totaal entries'=$entries.Count;
    'Roger host gezien'=$(if($hosts -contains 'adminnfr.roger365.io'){'Ja'}else{'Nee'});
    'SignalR host gezien'=$(if($hosts -contains 'r365nfr-eu-core-signalr.service.signalr.net'){'Ja'}else{'Nee'});
    'LoginStatus gezien'=$(if(($urls|Where-Object{$_ -like '*/Account/LoginStatus*'}).Count -gt 0){'Ja'}else{'Nee'});
    'presenceHub/negotiate gezien'=$(if(($urls|Where-Object{$_ -like '*/presenceHub/negotiate*'}).Count -gt 0){'Ja'}else{'Nee'});
    'WebSocket gezien'=$(if($wsSeen){'Ja'}else{'Nee'}); 'status 101 gezien'=$(if($status101){'Ja'}else{'Nee'});
    'matched hosts'=@($hosts|Where-Object{ $config.markerHosts -contains $_ }); 'matched URLs'=@($matchUrls|Select-Object -Unique); 'warnings'=@($state.harWarnings)
  }
} else { $summary=[ordered]@{'HAR bestaat'='Nee';'warnings'=@('Geen HAR ontvangen')} }
$summary|ConvertTo-Json -Depth 10|Set-Content -Path (Join-Path $sessionFolder 'summary.json') -Encoding UTF8
@("Teams Web HAR Capture samenvatting","HAR bestaat: $($summary['HAR bestaat'])","Roger host gezien: $($summary['Roger host gezien'])","SignalR host gezien: $($summary['SignalR host gezien'])","LoginStatus gezien: $($summary['LoginStatus gezien'])","presenceHub/negotiate gezien: $($summary['presenceHub/negotiate gezien'])","WebSocket gezien: $($summary['WebSocket gezien'])","status 101 gezien: $($summary['status 101 gezien'])","Outputmap: $sessionFolder","","Let op: een HAR-bestand kan gevoelige gegevens bevatten, zoals tokens, cookies, headers en URL's. Deel dit bestand alleen met vertrouwde supportmedewerkers.") | Set-Content -Path (Join-Path $sessionFolder 'samenvatting.txt') -Encoding UTF8
"Let op: een HAR-bestand kan gevoelige gegevens bevatten, zoals tokens, cookies, headers en URL's. Deel dit bestand alleen met vertrouwde supportmedewerkers." | Set-Content -Path (Join-Path $sessionFolder 'README-VOOR-SUPPORT.txt') -Encoding UTF8

try{ if(-not $p.HasExited){ Stop-Process -Id $p.Id -Force } }catch{}
try{ $listener.Stop() }catch{}
try{ Stop-Job $job -Force | Out-Null; Remove-Job $job -Force | Out-Null }catch{}
if(-not $config.keepTempProfile){ try{ Remove-Item -Recurse -Force $tempProfile }catch{} }
Log "Klaar. Outputmap: $sessionFolder"
