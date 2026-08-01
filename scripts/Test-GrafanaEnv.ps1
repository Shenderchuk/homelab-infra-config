[CmdletBinding()]
param(
    [string]$EnvPath = ".secrets/grafana.env",
    [string]$DashboardUid = "network-connectivity-fault-isolation"
)

$ErrorActionPreference = "Stop"

function Read-EnvFile {
    param([string]$Path)

    $values = @{}
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        if ($line.StartsWith("export ")) { $line = $line.Substring(7).Trim() }
        if ($line -match "^\s*([^#=\s]+)\s*=\s*(.*)\s*$") {
            $key = $Matches[1].Trim([char]0xFEFF)
            $value = $Matches[2].Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $values[$key] = $value
        }
    }
    return $values
}

function Invoke-HttpStatus {
    param(
        [string]$Name,
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers = @{}
    )

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Timeout = 30000

    foreach ($key in $Headers.Keys) {
        if ($key -eq "Accept") {
            $request.Accept = $Headers[$key]
        } else {
            $request.Headers[$key] = $Headers[$key]
        }
    }

    try {
        $response = $request.GetResponse()
        $result = [pscustomobject]@{
            Check = $Name
            Status = [int]$response.StatusCode
            Result = $response.StatusDescription
        }
        $response.Close()
        return $result
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $response = $_.Exception.Response
            $result = [pscustomobject]@{
                Check = $Name
                Status = [int]$response.StatusCode
                Result = $response.StatusDescription
            }
            $response.Close()
            return $result
        }

        return [pscustomobject]@{
            Check = $Name
            Status = ""
            Result = $_.Exception.Status
        }
    }
}

if (-not (Test-Path -LiteralPath $EnvPath)) {
    throw "Env file not found: $EnvPath"
}

$cfg = Read-EnvFile -Path $EnvPath
$required = @("GRAFANA_URL", "GRAFANA_TOKEN")
$optional = @("GRAFANA_API_NAME")

"Variable checks (values are not printed):"
($required + $optional) | ForEach-Object {
    $value = $cfg[$_]
    $notes = @()
    if ($_ -in $required -and [string]::IsNullOrWhiteSpace($value)) { $notes += "missing-or-empty" }
    if ($value -match "\s") { $notes += "contains-whitespace" }
    if ($_ -eq "GRAFANA_TOKEN" -and ($value.StartsWith("Bearer ") -or $value.StartsWith("Token "))) {
        $notes += "token-contains-auth-prefix"
    }
    [pscustomobject]@{
        Key = $_
        Present = -not [string]::IsNullOrWhiteSpace($value)
        Length = if ($null -eq $value) { 0 } else { $value.Length }
        Notes = ($notes -join ",")
    }
} | Format-Table -AutoSize

$missing = @($required | Where-Object { [string]::IsNullOrWhiteSpace($cfg[$_]) })
if ($missing.Count -gt 0) {
    throw "Missing required variables: $($missing -join ', ')"
}

$base = $cfg["GRAFANA_URL"].TrimEnd("/")
$headers = @{
    Authorization = "Bearer $($cfg["GRAFANA_TOKEN"])"
    Accept = "application/json"
}

"Grafana checks:"
@(
    Invoke-HttpStatus -Name "GET /api/health no auth" -Method "GET" -Uri "$base/api/health"
    Invoke-HttpStatus -Name "GET /api/health bearer" -Method "GET" -Uri "$base/api/health" -Headers $headers
    Invoke-HttpStatus -Name "GET /api/org bearer" -Method "GET" -Uri "$base/api/org" -Headers $headers
    Invoke-HttpStatus -Name "GET dashboard uid bearer" -Method "GET" -Uri "$base/api/dashboards/uid/$DashboardUid" -Headers $headers
    Invoke-HttpStatus -Name "GET search bearer" -Method "GET" -Uri "$base/api/search?query=Network%20Connectivity" -Headers $headers
) | Format-Table -AutoSize

"If health works but authenticated endpoints return 401, the URL is reachable but the service account token is wrong, expired, malformed, or not accepted by this Grafana instance."
