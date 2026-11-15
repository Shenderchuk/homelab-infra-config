#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Stops/removes only the NetWatch scheduled task. Preserves all logs and installed files.
#>
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference='Stop'
$task=Get-ScheduledTask -TaskName 'NetWatch-Ethernet' -ErrorAction SilentlyContinue
if (-not $task) { Write-Host 'NetWatch task is not installed.'; return }
if ($task.Description -ne 'NetWatch read-only Ethernet diagnostics') { throw 'Task is not owned by NetWatch.' }
if ($PSCmdlet.ShouldProcess('NetWatch-Ethernet','Stop and remove scheduled task (keep logs/files)')) {
    $configPath=Join-Path $env:ProgramFiles 'NetWatch\NetWatch.config.json'
    if (Test-Path -LiteralPath $configPath) {
        $config=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        Set-Content -LiteralPath (Join-Path $config.LogRoot 'stop.request') -Value (Get-Date -Format o) -Encoding UTF8
        $deadline=(Get-Date).AddSeconds(10)
        while ((Get-ScheduledTask -TaskName 'NetWatch-Ethernet').State -eq 'Running' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
    }
    Stop-ScheduledTask -TaskName 'NetWatch-Ethernet'
    Unregister-ScheduledTask -TaskName 'NetWatch-Ethernet' -Confirm:$false
    Write-Host 'Task removed. Logs and installed files preserved. Remove stop.request before a manual restart.'
}

