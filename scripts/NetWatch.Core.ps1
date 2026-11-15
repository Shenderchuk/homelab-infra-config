# Shared by monitor and tests; importing this file has no side effects.
function Write-NwJson {
    param([string]$Path, $Value)
    $line = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    [IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
function Write-NwCsv {
    param([string]$Path, $Value)
    $lines = @($Value | ConvertTo-Csv -NoTypeInformation)
    if (-not [IO.File]::Exists($Path)) {
        [IO.File]::AppendAllText($Path, $lines[0] + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::AppendAllText($Path, $lines[1] + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
function Get-NwClassification {
    param($Sample, [int]$GatewayFailures, [int]$InternetFailures, [int]$DnsFailures,
        [int]$Threshold = 2, [long]$ExpectedSpeed = 2500000000)
    if ($Sample.Status -eq 'Unknown') { return 'MONITOR_SOURCE_ERROR' }
    if ($Sample.Status -ne 'Up' -or $Sample.MediaState -eq 'Disconnected') { return 'PHYSICAL_LINK_DROP' }
    if (-not $Sample.IPv4 -or $Sample.IPv4 -like '169.254.*' -or -not $Sample.Gateway) {
        return 'IP_CONFIGURATION_CHANGE'
    }
    if ($ExpectedSpeed -gt 0 -and $Sample.LinkSpeedBps -lt $ExpectedSpeed) { return 'LINK_SPEED_DEGRADED' }
    if ($GatewayFailures -ge $Threshold) { return 'GATEWAY_LOSS_WHILE_LINK_UP' }
    if ($Sample.GatewayPing -eq 'OK' -and $InternetFailures -ge $Threshold) {
        return 'INTERNET_UPSTREAM_LOSS'
    }
    if ($Sample.GatewayPing -eq 'OK' -and
        ($Sample.Internet1Ping -eq 'OK' -or $Sample.Internet2Ping -eq 'OK') -and
        $DnsFailures -ge $Threshold) { return 'DNS_FAILURE' }
    return 'HEALTHY'
}
function Start-NwWorker {
    param([string]$ScriptPath, [hashtable]$Parameters)
    $ps = [PowerShell]::Create()
    [void]$ps.AddCommand($ScriptPath).AddParameters($Parameters)
    [pscustomobject]@{ PowerShell=$ps; Async=$ps.BeginInvoke(); Started=[datetime]::UtcNow }
}
function Stop-NwWorker {
    param($Worker)
    if ($Worker) {
        try { $Worker.PowerShell.Stop() } finally { $Worker.PowerShell.Dispose() }
    }
}

