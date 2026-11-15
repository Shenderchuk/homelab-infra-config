#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Installs NetWatch as a hidden SYSTEM task. Does not change network settings or enable event logs.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$LogRoot = 'C:\Logs\NetWatch',
    [string]$AdapterName,
    [string]$LanTarget,
    [long]$ExpectedLinkSpeedBps = 2500000000,
    [switch]$StartNow
)
$ErrorActionPreference='Stop'
$taskName='NetWatch-Ethernet'
$installDirectory=Join-Path $env:ProgramFiles 'NetWatch'
$marker=Join-Path $installDirectory '.netwatch-install'
$files=@('NetWatch.ps1','NetWatch.Core.ps1','NetWatch.Collect.ps1','NetWatch.Native.cs')
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) { throw "Missing companion file: $file" }
}
if ((Test-Path -LiteralPath $installDirectory) -and -not (Test-Path -LiteralPath $marker)) {
    throw "Existing directory is not a NetWatch installation: $installDirectory"
}
$existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing -and $existing.Description -ne 'NetWatch read-only Ethernet diagnostics') {
    throw "Task $taskName already exists and is not owned by this installer."
}
$LogRoot=[IO.Path]::GetFullPath($LogRoot)
if (-not $PSCmdlet.ShouldProcess("$taskName / $installDirectory", 'Install/update NetWatch background monitoring')) { return }
if ($existing) { Stop-ScheduledTask -TaskName $taskName }
[void][IO.Directory]::CreateDirectory($installDirectory)
# SYSTEM must never execute a user-writable script/configuration.
$acl=[Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
$admins=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$acl.SetOwner($admins)
foreach ($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-32-545','ReadAndExecute'))) {
    $sid=[Security.Principal.SecurityIdentifier]::new($entry[0])
    $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,$entry[1],'ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $installDirectory -AclObject $acl
foreach ($file in $files) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $installDirectory $file) -Force
}
Set-Content -LiteralPath $marker -Value 'NetWatch installation v1' -Encoding UTF8
$configPath=Join-Path $installDirectory 'NetWatch.config.json'
@{
    LogRoot=$LogRoot; AdapterName=$AdapterName; LanTarget=$LanTarget
    ExpectedLinkSpeedBps=$ExpectedLinkSpeedBps
    PollIntervalSeconds=1; ProbeTimeoutMs=600; ExtendedIntervalSeconds=5; DnsIntervalSeconds=5
    InternetTargets=@('1.1.1.1','8.8.8.8'); DnsName='www.microsoft.com'
    PreIncidentSeconds=60; PostIncidentSeconds=60; GatewayFailureThreshold=2
} | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
[void][IO.Directory]::CreateDirectory($LogRoot)
$stopPath=Join-Path $LogRoot 'stop.request'
if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath -Force }
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f (Join-Path $installDirectory 'NetWatch.ps1'),$configPath
$action=New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $installDirectory
$triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -AtLogOn))
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description 'NetWatch read-only Ethernet diagnostics' -Force | Out-Null
if ($StartNow) { Start-ScheduledTask -TaskName $taskName }
Write-Host "Installed: $taskName. Logs: $LogRoot. Start now: Start-ScheduledTask -TaskName '$taskName'"

