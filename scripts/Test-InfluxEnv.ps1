[CmdletBinding()]
param(
    [string]$EnvPath = ".secrets/influx.env"
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
        [hashtable]$Headers = @{},
        [string]$ContentType = "",
        [string]$Body = ""
    )

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Timeout = 30000

    foreach ($key in $Headers.Keys) {
        if ($key -eq "Accept") { $request.Accept = $Headers[$key]; continue }
        $request.Headers[$key] = $Headers[$key]
    }

    if ($ContentType) { $request.ContentType = $ContentType }
    if ($Body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }

    try {
        $response = $request.GetResponse()
        [pscustomobject]@{ Check = $Name; Status = [int]$response.StatusCode; Result = $response.StatusDescription }
        $response.Close()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $response = $_.Exception.Response
            [pscustomobject]@{ Check = $Name; Status = [int]$response.StatusCode; Result = $response.StatusDescription }
            $response.Close()
        } else {
            [pscustomobject]@{ Check = $Name; Status = ""; Result = $_.Exception.Status }
        }
    }
}

if (-not (Test-Path -LiteralPath $EnvPath)) {
    throw "Env file not found: $EnvPath"
}

$cfg = Read-EnvFile -Path $EnvPath
$required = @("INFLUX_URL", "INFLUX_ORG", "INFLUX_TOKEN", "INFLUX_BUCKET_OPNSENSE")

"Variable checks (values are not printed):"
$required | ForEach-Object {
    $value = $cfg[$_]
    $notes = @()
    if ([string]::IsNullOrWhiteSpace($value)) { $notes += "missing-or-empty" }
    if ($value -match "\s") { $notes += "contains-whitespace" }
    if ($_ -eq "INFLUX_TOKEN" -and ($value.StartsWith("Token ") -or $value.StartsWith("Bearer "))) {
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

$base = $cfg["INFLUX_URL"].TrimEnd("/")
$org = $cfg["INFLUX_ORG"]
$bucket = $cfg["INFLUX_BUCKET_OPNSENSE"]
$authHeadersJson = @{ Authorization = "Token $($cfg["INFLUX_TOKEN"])"; Accept = "application/json" }
$authHeadersCsv = @{ Authorization = "Token $($cfg["INFLUX_TOKEN"])"; Accept = "application/csv" }

"Influx checks:"
try {
    $health = Invoke-RestMethod -Method Get -Uri "$base/health" -TimeoutSec 10
    [pscustomobject]@{ Check = "GET /health"; Status = ""; Result = $health.status } | Format-Table -AutoSize
} catch {
    [pscustomobject]@{ Check = "GET /health"; Status = ""; Result = $_.Exception.GetType().Name } | Format-Table -AutoSize
}

Invoke-HttpStatus `
    -Name "GET /api/v2/buckets" `
    -Method "GET" `
    -Uri "$base/api/v2/buckets?limit=1" `
    -Headers $authHeadersJson | Format-Table -AutoSize

$query = 'import "influxdata/influxdb/schema"' + "`n" +
    ('schema.measurements(bucket: "{0}", start: -24h)' -f $bucket)
$body = @{ query = $query; type = "flux" } | ConvertTo-Json -Compress

Invoke-HttpStatus `
    -Name "POST /api/v2/query" `
    -Method "POST" `
    -Uri "$base/api/v2/query?org=$([uri]::EscapeDataString($org))" `
    -Headers $authHeadersCsv `
    -ContentType "application/json" `
    -Body $body | Format-Table -AutoSize

"If /health passes but authenticated endpoints return 401, the URL is reachable but the token, org, bucket permission, or target Influx instance is wrong."
