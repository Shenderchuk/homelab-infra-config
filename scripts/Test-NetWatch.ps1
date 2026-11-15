#requires -Version 5.1
<#
.SYNOPSIS
Deterministic classification/CSV tests. -Integration also runs a replay of a link drop.
Replay mocks only Get-NetAdapter inside this test process; it never disconnects the real NIC.
Native ICMP/DNS probes and the background read-only collector remain live during replay.
#>
[CmdletBinding()]
param([switch]$Integration, [string]$TestRoot = (Join-Path $env:TEMP ('NetWatch-test-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'NetWatch.Core.ps1')
$passed=0
function Assert-Nw {
    param([bool]$Condition,[string]$Description)
    if (-not $Condition) { throw "FAILED: $Description" }
    $script:passed++
}
$healthy=@{
    Status='Up'; MediaState='Connected'; IPv4='192.168.50.100'; Gateway='192.168.50.1'
    LinkSpeedBps=2500000000; GatewayPing='OK'; Internet1Ping='OK'; Internet2Ping='OK'
}
$cases=@(
    @{Change=@{}; G=0; I=0; D=0; Expected='HEALTHY'},
    @{Change=@{Status='Disconnected'}; G=0; I=0; D=0; Expected='PHYSICAL_LINK_DROP'},
    @{Change=@{MediaState='Disconnected'}; G=0; I=0; D=0; Expected='PHYSICAL_LINK_DROP'},
    @{Change=@{Status='Unknown'}; G=2; I=2; D=2; Expected='MONITOR_SOURCE_ERROR'},
    @{Change=@{IPv4='169.254.1.2'}; G=0; I=0; D=0; Expected='IP_CONFIGURATION_CHANGE'},
    @{Change=@{Gateway=''}; G=0; I=0; D=0; Expected='IP_CONFIGURATION_CHANGE'},
    @{Change=@{LinkSpeedBps=100000000}; G=0; I=0; D=0; Expected='LINK_SPEED_DEGRADED'},
    @{Change=@{GatewayPing='FAIL'}; G=2; I=2; D=0; Expected='GATEWAY_LOSS_WHILE_LINK_UP'},
    @{Change=@{Internet1Ping='FAIL';Internet2Ping='FAIL'}; G=0; I=2; D=0; Expected='INTERNET_UPSTREAM_LOSS'},
    @{Change=@{Internet1Ping='FAIL'}; G=0; I=0; D=0; Expected='HEALTHY'},
    @{Change=@{}; G=0; I=0; D=2; Expected='DNS_FAILURE'},
    @{Change=@{GatewayPing='FAIL'}; G=1; I=0; D=0; Expected='HEALTHY'}
)
foreach ($case in $cases) {
    $s=$healthy.Clone()
    foreach ($key in $case.Change.Keys) { $s[$key]=$case.Change[$key] }
    $actual=Get-NwClassification ([pscustomobject]$s) $case.G $case.I $case.D
    Assert-Nw ($actual -eq $case.Expected) ("Classification " + $case.Expected)
}
[void][IO.Directory]::CreateDirectory($TestRoot)
$csv=Join-Path $TestRoot 'roundtrip.csv'
$row=[pscustomobject]@{Timestamp=(Get-Date -Format o); Text="comma, quote `" and newline`nnext"}
Write-NwCsv $csv $row
Write-NwCsv $csv $row
$back=@(Import-Csv -LiteralPath $csv)
Assert-Nw ($back.Count -eq 2 -and $back[0].Text -eq $row.Text) 'CSV escaping and single header'
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*NetWatch*.ps1') {
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    Assert-Nw ($parseErrors.Count -eq 0) ("PowerShell parsing " + $file.Name)
}
if ($Integration) {
    $real=NetAdapter\Get-NetAdapter -Physical | Where-Object MediaType -eq '802.3' | Select-Object -First 1
    if (-not $real) { throw 'Integration requires a physical Ethernet adapter.' }
    $replayState=@{Adapter=$real; Reads=0}

    $mockAdapter = {
        param([switch]$Physical,[switch]$IncludeHidden)
        $replayState.Reads++
        $copy=$replayState.Adapter | Select-Object Name,InterfaceDescription,InterfaceGuid,ifIndex,MacAddress,
            DriverVersion,DriverDate,DriverFileName,LinkSpeed,Status,MediaConnectionState,ReceiveLinkSpeed,MediaType,NdisPhysicalMedium
        if ($replayState.Reads -ge 4 -and $replayState.Reads -le 5) {
            $copy.Status='Disconnected'; $copy.MediaConnectionState='Disconnected'; $copy.ReceiveLinkSpeed=0
        }
        $copy
    }.GetNewClosure()
    Set-Item -Path Function:Get-NetAdapter -Value $mockAdapter
    try {
        $replayRoot=Join-Path $TestRoot 'replay'
        & (Join-Path $PSScriptRoot 'NetWatch.ps1') -LogRoot $replayRoot -DurationSeconds 12 -SkipSnapshots -PreIncidentSeconds 3 -PostIncidentSeconds 2
    } finally { Remove-Item Function:\Get-NetAdapter }
    $samples=@(Get-ChildItem $replayRoot -Filter 'netwatch-*.csv' | ForEach-Object {Import-Csv $_.FullName})
    Assert-Nw (@($samples | Where-Object Classification -eq 'PHYSICAL_LINK_DROP').Count -ge 1) 'Replay detects physical drop'
    $summaries=@(Get-ChildItem (Join-Path $replayRoot incidents) -Filter summary.txt -Recurse)
    Assert-Nw ($summaries.Count -ge 1) 'Incident summary created'
    $text=Get-Content -LiteralPath $summaries[0].FullName -Raw
    Assert-Nw ($text -match 'State: Complete') 'Recovery closes incident after post-context'
    $incidentSamples=@(Get-ChildItem $summaries[0].Directory.FullName -Filter 'samples-*.csv' | ForEach-Object {Import-Csv $_.FullName})
    Assert-Nw ($incidentSamples[0].Classification -eq 'HEALTHY') 'Pre-incident context retained'
    Assert-Nw ($incidentSamples[-1].Classification -eq 'HEALTHY') 'Post-recovery context retained'
    Assert-Nw ((NetAdapter\Get-NetAdapter -Name $real.Name).InterfaceGuid -eq $real.InterfaceGuid) 'Real adapter identity is unchanged'
}
Write-Host "$passed checks passed. Test artifacts: $TestRoot"




