# Read-only background collector. Runs in a separate, bounded runspace.
[CmdletBinding()]
param(
    [ValidateSet('Telemetry','Snapshot')][string]$Mode,
    [string]$AdapterGuid,
    [string]$OutputDirectory,
    [string[]]$EventLogs = @(),
    [hashtable]$Cursors = @{},
    [datetime]$EventStart = (Get-Date).AddMinutes(-1),
    [string]$DriverProvider
)
$ErrorActionPreference = 'Stop'
$errors = [Collections.Generic.List[string]]::new()
function Read-NwSource {
    param([string]$Name, [scriptblock]$Read)
    try { & $Read } catch { $errors.Add($Name + ': ' + $_.Exception.Message) }
}
$adapter = Read-NwSource Adapter {
    Get-NetAdapter -ErrorAction Stop -IncludeHidden | Where-Object { [string]$_.InterfaceGuid -eq $AdapterGuid } | Select-Object -First 1
}
if ($Mode -eq 'Snapshot') {
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $reads = [ordered]@{
        'adapters' = { Get-NetAdapter -ErrorAction Stop -IncludeHidden | Format-List * }
        'statistics' = { Get-NetAdapterStatistics -ErrorAction Stop | Format-List * }
        'ip-configuration' = { Get-NetIPConfiguration -ErrorAction Stop -All -Detailed | Format-List * }
        'ip-addresses' = { Get-NetIPAddress -ErrorAction Stop | Format-List * }
        'routes' = { Get-NetRoute -ErrorAction Stop | Format-Table -AutoSize }
        'dns-client' = { Get-DnsClient -ErrorAction Stop | Format-List * }
        'dns-servers' = { Get-DnsClientServerAddress -ErrorAction Stop | Format-List * }
        'ipconfig' = { ipconfig.exe /all }
        'route-print' = { route.exe print }
        'arp' = { arp.exe -a }
        'netstat-statistics' = { netstat.exe -s }
        'netstat-ethernet' = { netstat.exe -e }
        'cim-adapters' = { Get-CimInstance -ErrorAction Stop Win32_NetworkAdapter | Format-List * }
        'cim-ip' = { Get-CimInstance -ErrorAction Stop Win32_NetworkAdapterConfiguration | Format-List * }
        'pnp' = { Get-PnpDevice -ErrorAction Stop -Class Net | Format-List * }
        'bindings' = { Get-NetAdapterBinding -ErrorAction Stop -Name $adapter.Name | Format-Table -AutoSize }
        'advanced-properties' = { Get-NetAdapterAdvancedProperty -ErrorAction Stop -Name $adapter.Name | Format-List * }
        'power-management' = { Get-NetAdapterPowerManagement -ErrorAction Stop -Name $adapter.Name | Format-List * }
        'udp-endpoints' = { Get-NetUDPEndpoint -ErrorAction Stop | Format-Table -AutoSize }
        'tcp-endpoints' = { Get-NetTCPConnection -ErrorAction Stop | Format-Table -AutoSize }
        'processes' = { Get-Process | Select-Object Id,ProcessName,Handles,CPU | Format-Table -AutoSize }
        'dynamic-udp-range' = { netsh.exe int ipv4 show dynamicport udp }
    }
    foreach ($name in $reads.Keys) {
        $text = Read-NwSource $name $reads[$name] | Out-String -Width 240
        Set-Content -LiteralPath (Join-Path $OutputDirectory ($name + '.txt')) -Value $text -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'collection-errors.txt') -Value ($errors -join [Environment]::NewLine) -Encoding UTF8
    return
}
$stats = Read-NwSource Statistics { Get-NetAdapterStatistics -ErrorAction Stop -Name $adapter.Name }
$dhcp = Read-NwSource DHCP {
    Get-CimInstance -ErrorAction Stop Win32_NetworkAdapterConfiguration -Filter ("InterfaceIndex=" + $adapter.ifIndex) |
        Select-Object DHCPEnabled,DHCPServer,DHCPLeaseObtained,DHCPLeaseExpires,IPAddress,IPSubnet,DefaultIPGateway
}
$udp = @(Read-NwSource UDP { Get-NetUDPEndpoint -ErrorAction Stop })
$udpOwners = @($udp | Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 10 |
    ForEach-Object {
        $p = Get-Process -Id ([int]$_.Name) -ErrorAction SilentlyContinue
        [pscustomobject]@{ PID=[int]$_.Name; Process=$p.ProcessName; Count=$_.Count }
    })
$events = [Collections.Generic.List[object]]::new()
foreach ($log in $EventLogs) {
    try {
        $latest = Get-WinEvent -LogName $log -MaxEvents 1 -ErrorAction Stop
        $cursor = $Cursors[$log]
        if ($null -ne $cursor -and [long]$latest.RecordId -lt [long]$cursor) {
            $errors.Add("Event log cleared: $log"); $cursor = $null
        }
        if ($null -eq $cursor) {
            $stamp = $EventStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $xpath = "*[System[TimeCreated[@SystemTime >= '$stamp']]]"
        } else {
            $xpath = "*[System[EventRecordID > $cursor]]"
        }
        $batch = @(Get-WinEvent -LogName $log -FilterXPath $xpath -Oldest -MaxEvents 500 -ErrorAction Stop)
        foreach ($e in $batch) {
            $Cursors[$log] = [long]$e.RecordId
            if ($log -eq 'System' -and
                $e.ProviderName -ne $DriverProvider -and
                $e.ProviderName -notmatch 'NDIS|NetworkProfile|Dhcp|Tcpip|DNS.Client|Kernel-PnP|Kernel-Power|Power-Troubleshooter') {
                continue
            }
            if ($e.ProviderName -match 'Netwtw|Netwaw') { continue }
            $events.Add([pscustomobject]@{
                Timestamp=$e.TimeCreated.ToString('o'); Log=$log; RecordId=$e.RecordId
                Provider=$e.ProviderName; EventId=$e.Id; Level=$e.LevelDisplayName
                Message=$e.Message; Xml=$e.ToXml()
            })
        }
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
            $errors.Add("Event log $log : " + $_.Exception.Message)
        }
    }
}
[pscustomobject]@{
    Timestamp=(Get-Date).ToString('o')
    Statistics=$stats
    DHCP=$dhcp
    UdpCount=$udp.Count
    UdpOwners=$udpOwners
    Events=$events.ToArray()
    Cursors=$Cursors
    Errors=$errors.ToArray()
}


