#requires -Version 5.1
<#
.SYNOPSIS
Continuous read-only Ethernet diagnostics. Run elevated for complete event/device access.
.DESCRIPTION
Does not reset NICs, renew DHCP, enable logs, change registry or change network settings.
Ctrl+C or a stop.request file in LogRoot stops the foreground/background monitor.
#>
[CmdletBinding()]
param(
    [string]$LogRoot = 'C:\Logs\NetWatch',
    [string]$AdapterName,
    [string]$LanTarget,
    [string[]]$InternetTargets = @('1.1.1.1','8.8.8.8'),
    [string]$DnsName = 'www.microsoft.com',
    [ValidateRange(0.25,60)][double]$PollIntervalSeconds = 1,
    [ValidateRange(100,5000)][int]$ProbeTimeoutMs = 600,
    [ValidateRange(1,300)][int]$ExtendedIntervalSeconds = 5,
    [ValidateRange(1,300)][int]$DnsIntervalSeconds = 5,
    [ValidateRange(1,20)][int]$GatewayFailureThreshold = 2,
    [ValidateRange(0,3600)][int]$PreIncidentSeconds = 60,
    [ValidateRange(0,3600)][int]$PostIncidentSeconds = 60,
    [long]$ExpectedLinkSpeedBps = 2500000000,
    [ValidateRange(0,86400)][int]$DurationSeconds = 0,
    [switch]$SkipSnapshots,
    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
if ($ConfigPath) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $allowed = @('LogRoot','AdapterName','LanTarget','InternetTargets','DnsName','PollIntervalSeconds',
        'ProbeTimeoutMs','ExtendedIntervalSeconds','DnsIntervalSeconds','GatewayFailureThreshold',
        'PreIncidentSeconds','PostIncidentSeconds','ExpectedLinkSpeedBps')
    foreach ($p in $config.PSObject.Properties) {
        if ($p.Name -notin $allowed) { throw "Unknown config key: $($p.Name)" }
        Set-Variable -Name $p.Name -Value $p.Value
    }
}
# Config files also undergo validation (parameter attributes alone do not validate Set-Variable).
if ($PollIntervalSeconds -lt 0.25 -or $PollIntervalSeconds -gt 60 -or
    $ProbeTimeoutMs -lt 100 -or $ProbeTimeoutMs -gt 5000 -or
    $ExtendedIntervalSeconds -lt 1 -or $DnsIntervalSeconds -lt 1 -or
    $GatewayFailureThreshold -lt 1 -or $PreIncidentSeconds -lt 0 -or
    $PreIncidentSeconds -gt 3600 -or $PostIncidentSeconds -lt 0 -or $PostIncidentSeconds -gt 3600) {
    throw 'Invalid monitoring intervals/configuration.'
}
if (@($InternetTargets).Count -ne 2) { throw 'Specify exactly two IPv4 InternetTargets.' }
foreach ($target in @($InternetTargets) + @($LanTarget)) {
    if ($target -and ([Net.IPAddress]::Parse($target)).AddressFamily -ne 'InterNetwork') {
        throw "IPv4 target required: $target"
    }
}
if ($DnsName -notmatch '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$') { throw 'Invalid DNS name.' }
. (Join-Path $PSScriptRoot 'NetWatch.Core.ps1')
if (-not ('NetWatch.Probes' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'NetWatch.Native.cs') }
$LogRoot = [IO.Path]::GetFullPath($LogRoot)
foreach ($dir in @('','events','snapshots','incidents','metrics')) {
    [void][IO.Directory]::CreateDirectory((Join-Path $LogRoot $dir))
}
# Exclusive file handle prevents duplicate writers, including across interactive/SYSTEM sessions.
try { $lock = [IO.File]::Open((Join-Path $LogRoot 'netwatch.lock'),'OpenOrCreate','ReadWrite','None') }
catch { throw "Another monitor owns LogRoot, or it is not writable: $LogRoot. $($_.Exception.Message)" }
$session = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID
$started = Get-Date
$collector = $null; $snapshot = $null; $incident = $null
$telemetry = $null; $lastStats = $null; $lastDhcp = $null; $previous = $null
$cursors = @{}; $eventLogs = @(); $eventRing = [Collections.Generic.Queue[object]]::new()
$ring = [Collections.Generic.Queue[object]]::new()
$ringLimit = [int][Math]::Ceiling($PreIncidentSeconds / $PollIntervalSeconds) + 5
$gatewayFailures=0; $internetFailures=0; $dnsFailures=0
$dnsResult = [pscustomobject]@{ Status='NOT_TESTED'; LatencyMs=-1; Detail='' }
$dnsTime=$null; $dnsSource=''; $lastExtended=[datetime]::MinValue
$lastHeartbeat=[datetime]::MinValue; $lastLoopErrors=@{}
$stopPath = Join-Path $LogRoot 'stop.request'
function Write-Diagnostic {
    param([string]$Source, [string]$Message)
    # Throttle identical persistent source errors to one per minute.
    $key = $Source + ':' + $Message
    if ($lastLoopErrors.ContainsKey($key) -and ((Get-Date)-$lastLoopErrors[$key]).TotalSeconds -lt 60) { return }
    if ($lastLoopErrors.Count -gt 100) { $lastLoopErrors.Clear() }
    $lastLoopErrors[$key]=Get-Date
    Write-NwJson (Join-Path $LogRoot ("diagnostics-" + (Get-Date -Format yyyy-MM-dd) + '.jsonl')) ([ordered]@{
        Timestamp=(Get-Date).ToString('o'); Session=$session; Source=$Source; Message=$Message
    })
}
function Start-Snapshot {
    param([string]$Directory)
    if ($SkipSnapshots) { return }
    if ($script:snapshot) {
        Write-Diagnostic Snapshot 'Previous snapshot still running; additional snapshot skipped.'
        return
    }
    $script:snapshot = Start-NwWorker (Join-Path $PSScriptRoot 'NetWatch.Collect.ps1') @{
        Mode='Snapshot'; AdapterGuid=$adapterGuid; OutputDirectory=$Directory
    }
}
function Write-IncidentSummary {
    param([string]$State)
    if (-not $script:incident) { return }
    $i=$script:incident
    $end = if ($i.Recovered) { $i.Recovered.ToString('o') } else { 'not observed' }
    $duration = if ($i.Recovered) { ($i.Recovered-$i.Start).TotalSeconds } else { ((Get-Date)-$i.Start).TotalSeconds }
    $summary = @(
        "State: $State", "Incident start: $($i.Start.ToString('o'))", "Incident end/recovery: $end",
        "Observed duration seconds: $duration", "Possible classifications: $($i.Classes -join ', ')",
        "Before: $($i.Before)", "Latest: $($i.Latest)",
        'Root cause is not established by classification. ICMP can be filtered/rate-limited.',
        'See timeline.txt, events.jsonl, samples-*.csv, and start/recovery-snapshot/.',
        "Pre-context requested: $PreIncidentSeconds s; post-recovery context requested: $PostIncidentSeconds s.",
        'Startup may have less pre-context; interrupted monitoring may have incomplete post-context.'
    )
    Set-Content -LiteralPath (Join-Path $i.Path 'summary.txt') -Value $summary -Encoding UTF8
}
try {
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $candidates = @(Get-NetAdapter -Physical | Where-Object {
        $_.MediaType -eq '802.3' -or $_.NdisPhysicalMedium -eq 14
    })
    if ($AdapterName) { $candidates = @($candidates | Where-Object Name -eq $AdapterName) }
    $adapter = $candidates | Sort-Object @{Expression={ if ($_.Status -eq 'Up') {0} else {1} }},
        @{Expression={
            $idx=$_.ifIndex
            $r=$routes | Where-Object InterfaceIndex -eq $idx | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
            if ($r) { [long]$r.RouteMetric + [long]$r.InterfaceMetric } else { [long]::MaxValue }
        }},ifIndex | Select-Object -First 1
    if (-not $adapter) { throw 'No physical Ethernet adapter found. Check -AdapterName or retry when device is present.' }
    $adapterGuid=[string]$adapter.InterfaceGuid
    $driverProvider=[IO.Path]::GetFileNameWithoutExtension([string]$adapter.DriverFileName)
    if (-not $driverProvider) {
        $pnp=Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.GUID -eq $adapterGuid } | Select-Object -First 1
        $driverProvider=$pnp.ServiceName
    }
    $logStatus = foreach ($name in @('System','Microsoft-Windows-NDIS/Operational',
        'Microsoft-Windows-NetworkProfile/Operational','Microsoft-Windows-Dhcp-Client/Admin',
        'Microsoft-Windows-Dhcp-Client/Operational','Microsoft-Windows-Dhcpv6-Client/Admin',
        'Microsoft-Windows-DNS-Client/Operational','Microsoft-Windows-Kernel-PnP/Configuration')) {
        try {
            $l=Get-WinEvent -ListLog $name -ErrorAction Stop
            if ($l.IsEnabled) { $eventLogs += $name }
            [pscustomobject]@{ Log=$name; Enabled=$l.IsEnabled; Error=$null }
        } catch { [pscustomobject]@{ Log=$name; Enabled=$false; Error=$_.Exception.Message } }
    }
    $checkpointPath=Join-Path $LogRoot 'event-cursors.json'
    if (Test-Path -LiteralPath $checkpointPath) {
        try {
            $saved=Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) { $cursors[$p.Name]=[long]$p.Value }
        } catch { Write-Diagnostic Events 'Cannot read event checkpoints; falling back to pre-context window.' }
    }
    $meta=[ordered]@{
        Timestamp=$started.ToString('o'); Session=$session; Computer=$env:COMPUTERNAME; PID=$PID
        Adapter=($adapter | Select-Object Name,InterfaceDescription,InterfaceGuid,ifIndex,MacAddress,DriverVersion,DriverDate,DriverFileName,LinkSpeed)
        DriverProvider=$driverProvider; Logs=$logStatus
        Config=@{PollSeconds=$PollIntervalSeconds; ProbeTimeoutMs=$ProbeTimeoutMs; InternetTargets=$InternetTargets;
            LanTarget=$LanTarget; DnsName=$DnsName; ExpectedLinkSpeedBps=$ExpectedLinkSpeedBps}
    }
    $meta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $LogRoot ("session-$session.json")) -Encoding UTF8
    Write-Host "NetWatch: $($adapter.Name), $adapterGuid -> $LogRoot. Ctrl+C or stop.request to stop."
    Start-Snapshot (Join-Path $LogRoot ("snapshots/startup-$session"))
    while (-not (Test-Path -LiteralPath $stopPath)) {
        $now=Get-Date
        if ($DurationSeconds -gt 0 -and ($now-$started).TotalSeconds -ge $DurationSeconds) { break }
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $eventClass=$null; $configMarker=$null
        if ($snapshot) {
            if ($snapshot.Async.IsCompleted) {
                try {
                    [void]$snapshot.PowerShell.EndInvoke($snapshot.Async)
                    foreach ($err in $snapshot.PowerShell.Streams.Error) { Write-Diagnostic Snapshot ([string]$err) }
                } catch { Write-Diagnostic Snapshot $_.Exception.Message }
                finally { $snapshot.PowerShell.Dispose(); $snapshot=$null }
            } elseif (([datetime]::UtcNow-$snapshot.Started).TotalSeconds -gt 45) {
                Stop-NwWorker $snapshot; $snapshot=$null; Write-Diagnostic Snapshot 'Snapshot timed out after 45 seconds; files may be partial.'
            }
        }
        if ($collector -and $collector.Async.IsCompleted) {
            try {
                $result=@($collector.PowerShell.EndInvoke($collector.Async))
                foreach ($err in $collector.PowerShell.Streams.Error) { Write-Diagnostic Collector ([string]$err) }
                if ($result.Count -gt 0) {
                    $telemetry=$result[-1]; $cursors=$telemetry.Cursors
                    foreach ($err in $telemetry.Errors) { Write-Diagnostic Collector $err }
                    $delta=[ordered]@{}; $reset=$false
                    foreach ($field in @('ReceivedBytes','SentBytes','ReceivedUnicastPackets','SentUnicastPackets',
                        'ReceivedDiscardedPackets','OutboundDiscardedPackets','ReceivedPacketErrors','OutboundPacketErrors')) {
                        $delta[$field]=$null
                        if ($lastStats -and $telemetry.Statistics) {
                            $d=[decimal]$telemetry.Statistics.$field - [decimal]$lastStats.$field
                            if ($d -lt 0) { $reset=$true } else { $delta[$field]=$d }
                        }
                    }
                    $lastStats=$telemetry.Statistics
                    $dhcpKey=$telemetry.DHCP | ConvertTo-Json -Compress -Depth 4
                    if ($lastDhcp -and $telemetry.DHCP -and $dhcpKey -ne $lastDhcp) { $configMarker='DHCP_LEASE_OR_CONFIGURATION_CHANGE' }
                    if ($telemetry.DHCP) { $lastDhcp=$dhcpKey }
                    Write-NwJson (Join-Path $LogRoot ("metrics/extended-" + $now.ToString('yyyy-MM-dd') + '.jsonl')) ([ordered]@{
                        Timestamp=$telemetry.Timestamp; Session=$session
                        Statistics=($telemetry.Statistics | Select-Object ReceivedBytes,SentBytes,ReceivedUnicastPackets,SentUnicastPackets,
                            ReceivedDiscardedPackets,OutboundDiscardedPackets,ReceivedPacketErrors,OutboundPacketErrors)
                        Delta=$delta; CounterReset=$reset; DHCP=$telemetry.DHCP
                        UdpCount=$telemetry.UdpCount; UdpOwners=$telemetry.UdpOwners
                    })
                    foreach ($e in $telemetry.Events) {
                        Write-NwJson (Join-Path $LogRoot ('events/events-' + ([datetime]$e.Timestamp).ToString('yyyy-MM-dd') + '.jsonl')) $e
                        if (($now-([datetime]$e.Timestamp)).TotalSeconds -le ($PreIncidentSeconds+30)) { $eventRing.Enqueue($e) }
                        if ($incident -and ([datetime]$e.Timestamp) -ge $incident.Start.AddSeconds(-$PreIncidentSeconds)) {
                            Write-NwJson (Join-Path $incident.Path 'events.jsonl') $e
                        }
                        # Do not turn historical startup events into new incidents.
                        if (([datetime]$e.Timestamp) -ge $started -and ($now-([datetime]$e.Timestamp)).TotalSeconds -lt 30) {
                            if (($e.Provider -eq $driverProvider -and $e.Message -match 'tx hang|reset') -or
                                ($e.Provider -match 'NDIS' -and $e.EventId -eq 10400 -and $e.Message -like "*$($adapter.InterfaceDescription)*")) {
                                $eventClass='ADAPTER_RESET'
                            }
                            if ($e.Provider -eq 'Tcpip' -and $e.EventId -in @(4231,4266)) { $eventClass='PORT_EXHAUSTION' }
                        }
                    }
                    $cursors | ConvertTo-Json | Set-Content -LiteralPath $checkpointPath -Encoding UTF8
                }
            } catch { Write-Diagnostic Collector $_.Exception.Message }
            finally { $collector.PowerShell.Dispose(); $collector=$null }
        }
        if ($collector -and ([datetime]::UtcNow-$collector.Started).TotalSeconds -gt 30) {
            Stop-NwWorker $collector; $collector=$null; Write-Diagnostic Collector 'Collector timed out; data marked stale by timestamp.'
        }
        if (-not $collector -and ($now-$lastExtended).TotalSeconds -ge $ExtendedIntervalSeconds) {
            $collector=Start-NwWorker (Join-Path $PSScriptRoot 'NetWatch.Collect.ps1') @{
                Mode='Telemetry'; AdapterGuid=$adapterGuid; EventLogs=$eventLogs; Cursors=$cursors.Clone()
                EventStart=$started.AddSeconds(-$PreIncidentSeconds); DriverProvider=$driverProvider
            }
            $lastExtended=$now
        }
        $status='Unknown'; $media='Unknown'; $speed=0L; $ip=''; $gateway=''; $dnsServer=''; $routeKey=''
        $sourceError=''; $a=$null
        try {
            $a=Get-NetAdapter -IncludeHidden | Where-Object { [string]$_.InterfaceGuid -eq $adapterGuid } | Select-Object -First 1
            if (-not $a) { $status='Missing' } else {
                $status=[string]$a.Status; $media=[string]$a.MediaConnectionState; $speed=[long]$a.ReceiveLinkSpeed
                $nic=[Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                    Where-Object { $_.Id.Trim('{}') -eq $adapterGuid.Trim('{}') } | Select-Object -First 1
                if ($nic) {
                    $props=$nic.GetIPProperties()
                    $ipEntry=$props.UnicastAddresses | Where-Object {
                        $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -notlike '169.254.*'
                    } | Select-Object -First 1
                    if (-not $ipEntry) { $ipEntry=$props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 }
                    if ($ipEntry) { $ip=$ipEntry.Address.ToString() }
                    $dnsServer=($props.DnsAddresses | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1)
                    if ($dnsServer) { $dnsServer=$dnsServer.ToString() }
                }
                $rs=@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                    Sort-Object { [long]$_.RouteMetric + [long]$_.InterfaceMetric },InterfaceIndex,NextHop)
                $own=$rs | Where-Object InterfaceIndex -eq $a.ifIndex | Select-Object -First 1
                if ($own) { $gateway=$own.NextHop }
                $routeKey=($rs | ForEach-Object { "$($_.InterfaceIndex):$($_.NextHop):$($_.RouteMetric):$($_.InterfaceMetric)" }) -join ';'
            }
        } catch { $sourceError=$_.Exception.Message; $status='Unknown'; Write-Diagnostic Sample $sourceError }
        $tasks=@{}; $probes=@{}
        $targets=[ordered]@{ Gateway=$gateway; Lan=$LanTarget; Internet1=$InternetTargets[0]; Internet2=$InternetTargets[1] }
        foreach ($key in $targets.Keys) {
            $probes[$key]=[pscustomobject]@{Status='NOT_TESTED'; LatencyMs=-1; Code=0; Detail='No connected source/target'}
            if ($status -eq 'Up' -and $ip -and $ip -notlike '169.254.*' -and $targets[$key]) {
                $tasks[$key]=[NetWatch.Probes]::Ping($ip,[string]$targets[$key],$ProbeTimeoutMs)
            }
        }
        $dnsFresh=$false
        if ($status -eq 'Up' -and $ip -and $dnsServer -and
            (-not $dnsTime -or ($now-$dnsTime).TotalSeconds -ge $DnsIntervalSeconds -or "$ip/$dnsServer" -ne $dnsSource)) {
            $tasks.Dns=[NetWatch.Probes]::Dns($ip,$dnsServer,$DnsName,$ProbeTimeoutMs)
            $dnsFresh=$true
        }
        # Native probes run concurrently, each has its own bounded timeout and closes handles.
        foreach ($key in $tasks.Keys) {
            $res=$tasks[$key].GetAwaiter().GetResult()
            if ($key -eq 'Dns') {
                $dnsResult=$res; $dnsTime=$now; $dnsSource="$ip/$dnsServer"
            } else { $probes[$key]=$res }
        }
        if ($probes.Gateway.Status -eq 'FAIL') { $gatewayFailures++ } else { $gatewayFailures=0 }
        if ($probes.Internet1.Status -eq 'FAIL' -and $probes.Internet2.Status -eq 'FAIL') { $internetFailures++ } else { $internetFailures=0 }
        if ($dnsFresh) {
            if ($dnsResult.Status -eq 'OK') { $dnsFailures=0 } else { $dnsFailures++ }
        }
        if ($status -ne 'Up' -or -not $ip) { $dnsFailures=0 }
        $s=[pscustomobject][ordered]@{
            Timestamp=$now.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'); Session=$session
            Adapter=if($a){$a.Name}else{''}; InterfaceGuid=$adapterGuid; IfIndex=if($a){$a.ifIndex}else{0}
            Status=$status; MediaState=$media; LinkSpeedBps=$speed; IPv4=$ip; Gateway=$gateway
            DefaultRoutes=$routeKey; GatewayPing=$probes.Gateway.Status; GatewayLatencyMs=$probes.Gateway.LatencyMs; GatewayCode=$probes.Gateway.Code
            LanTarget=$LanTarget; LanPing=$probes.Lan.Status; LanLatencyMs=$probes.Lan.LatencyMs
            Internet1=$InternetTargets[0]; Internet1Ping=$probes.Internet1.Status; Internet1LatencyMs=$probes.Internet1.LatencyMs
            Internet2=$InternetTargets[1]; Internet2Ping=$probes.Internet2.Status; Internet2LatencyMs=$probes.Internet2.LatencyMs
            DnsServer=$dnsServer; DnsStatus=$dnsResult.Status; DnsTimestamp=if($dnsTime){$dnsTime.ToString('o')}else{''}
            DnsDetail=$dnsResult.Detail; MetricsTimestamp=if($telemetry){$telemetry.Timestamp}else{''}
            Classification=''; Marker=$configMarker; SampleDurationMs=0; SourceError=$sourceError
        }
        $class=Get-NwClassification $s $gatewayFailures $internetFailures $dnsFailures $GatewayFailureThreshold $ExpectedLinkSpeedBps
        if ($previous -and $status -ne 'Unknown' -and
            ($previous.IPv4 -ne $ip -or $previous.Gateway -ne $gateway -or $previous.DefaultRoutes -ne $routeKey)) {
            $s.Marker=(@($s.Marker,'IP_OR_ROUTE_CHANGE') | Where-Object {$_}) -join ';'
            if ($class -eq 'HEALTHY') { $class='IP_CONFIGURATION_CHANGE' }
        }
        if ($previous -and $previous.LinkSpeedBps -ne $speed) {
            $s.Marker=(@($s.Marker,"LINK_SPEED_CHANGE:$($previous.LinkSpeedBps)->$speed") | Where-Object {$_}) -join ';'
            if ($class -eq 'HEALTHY') { $class='LINK_SPEED_CHANGE' }
        }
        if ($eventClass) { $s.Marker=(@($s.Marker,$eventClass) | Where-Object {$_}) -join ';'; if($class -eq 'HEALTHY'){$class=$eventClass} }
        if ($configMarker -and $class -eq 'HEALTHY') { $class='IP_CONFIGURATION_CHANGE' }
        if (@($probes.Values | Where-Object Status -eq 'ERROR').Count -gt 0 -and $class -eq 'HEALTHY') {
            $class='PROBE_ERROR'
        }
        $s.Classification=$class
        $s.SampleDurationMs=$clock.ElapsedMilliseconds
        Write-NwCsv (Join-Path $LogRoot ("netwatch-" + $now.ToString('yyyy-MM-dd') + '.csv')) $s
        while ($ring.Count -gt 0 -and (($now-([datetime]$ring.Peek().Timestamp)).TotalSeconds -gt $PreIncidentSeconds -or $ring.Count -ge $ringLimit)) { [void]$ring.Dequeue() }
        while ($eventRing.Count -gt 0 -and (($now-([datetime]$eventRing.Peek().Timestamp)).TotalSeconds -gt $PreIncidentSeconds -or $eventRing.Count -gt 2000)) { [void]$eventRing.Dequeue() }
        $stateText="$status / $media / $speed bps; IP=$ip; gateway=$gateway $($s.GatewayPing); routes=$routeKey; class=$class"
        if (-not $incident -and $class -ne 'HEALTHY') {
            $path=Join-Path $LogRoot ('incidents/' + $now.ToString('yyyyMMdd-HHmmss-fff') + '-' + $PID)
            [void][IO.Directory]::CreateDirectory($path)
            $incident=@{Path=$path; Start=$now; Recovered=$null; Classes=[Collections.Generic.List[string]]::new()
                Before=if($previous){"$($previous.Status) / $($previous.LinkSpeedBps) bps; IP=$($previous.IPv4); gateway=$($previous.Gateway); routes=$($previous.DefaultRoutes)"}else{'No prior sample'}
                Latest=$stateText; LastState=''}
            foreach ($old in $ring) { Write-NwCsv (Join-Path $path ('samples-' + ([datetime]$old.Timestamp).ToString('yyyy-MM-dd') + '.csv')) $old }
            foreach ($e in $eventRing) { Write-NwJson (Join-Path $path 'events.jsonl') $e }
            Start-Snapshot (Join-Path $path 'start-snapshot')
        }
        if ($incident) {
            Write-NwCsv (Join-Path $incident.Path ('samples-' + $now.ToString('yyyy-MM-dd') + '.csv')) $s
            $incident.Latest=$stateText
            if ($class -ne 'HEALTHY') {
                if (-not $incident.Classes.Contains($class)) { $incident.Classes.Add($class) }
                $incident.Recovered=$null
            } elseif (-not $incident.Recovered) {
                $incident.Recovered=$now
                Start-Snapshot (Join-Path $incident.Path 'recovery-snapshot')
            }
            if ($stateText -ne $incident.LastState -or $s.Marker) {
                Add-Content -LiteralPath (Join-Path $incident.Path 'timeline.txt') -Encoding UTF8 -Value "$($s.Timestamp) $stateText; marker=$($s.Marker)"
                $incident.LastState=$stateText
                Write-IncidentSummary 'Observing (includes post-recovery context)'
            }
            if ($incident.Recovered -and ($now-$incident.Recovered).TotalSeconds -ge $PostIncidentSeconds) {
                Write-IncidentSummary 'Complete'; $incident=$null
            }
        }
        $ring.Enqueue($s); $previous=$s
        if (($now-$lastHeartbeat).TotalSeconds -ge 5) {
            [ordered]@{Timestamp=$s.Timestamp; PID=$PID; Session=$session; Adapter=$s.Adapter
                Status=$status; LinkSpeedBps=$speed; Classification=$class; LogRoot=$LogRoot
                Incident=if($incident){$incident.Path}else{$null}} |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogRoot 'heartbeat.json') -Encoding UTF8
            $lastHeartbeat=$now
        }
        $remaining=[int]($PollIntervalSeconds*1000-$clock.ElapsedMilliseconds)
        if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
        elseif ($clock.ElapsedMilliseconds -gt ($PollIntervalSeconds*1000+250)) {
            Write-Diagnostic Timing ("Sample exceeded interval: " + $clock.ElapsedMilliseconds + ' ms')
        }
    }
} catch {
    Write-Diagnostic Fatal $_.Exception.ToString()
    throw
} finally {
    Write-IncidentSummary 'Monitor stopped; context may be incomplete'
    Stop-NwWorker $collector
    Stop-NwWorker $snapshot
    $lock.Dispose()
}

