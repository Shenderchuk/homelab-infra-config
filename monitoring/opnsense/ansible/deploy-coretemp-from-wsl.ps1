[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$InstallDependencies,
    [string]$Distro = "Ubuntu",
    [string]$TargetHost = "gw01-i7505",
    [string]$IdentityFile = (Join-Path $env:USERPROFILE ".ssh\home_pc")
)

$ErrorActionPreference = "Stop"

function Convert-ToWslPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if ($resolved -notmatch "^([A-Za-z]):\\(.*)$") {
        throw "Only local drive paths can be converted to WSL paths: $resolved"
    }

    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2] -replace "\\", "/"
    return "/mnt/$drive/$rest"
}

function Quote-Sh {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..")).Path
$wslRepoRoot = Convert-ToWslPath -Path $repoRoot
$ansibleDir = "$wslRepoRoot/monitoring/opnsense/ansible"
$playbook = "playbooks/coretemp.yml"
$limitArg = $TargetHost
$checkArg = if ($Check) { "--check" } else { "" }
$wslIdentityFile = if ($IdentityFile -and (Test-Path -LiteralPath $IdentityFile)) { Convert-ToWslPath -Path $IdentityFile } else { "" }

if ($InstallDependencies) {
    $installBlockLines = @(
        'ANSIBLE_VENV="$HOME/.local/share/homelab-infra-ansible-venv"',
        'PATH="$HOME/.local/bin:$PATH"',
        'if [ -x "$ANSIBLE_VENV/bin/ansible-playbook" ]; then',
        '  PATH="$ANSIBLE_VENV/bin:$PATH"',
        'fi',
        'if ! command -v ansible-playbook >/dev/null 2>&1; then',
        '  if sudo -n true 2>/dev/null; then',
        '    sudo apt-get update',
        '    sudo apt-get install -y ansible',
        '  else',
        '    if python3 -m venv "$ANSIBLE_VENV"; then',
        '      "$ANSIBLE_VENV/bin/python" -m pip install --upgrade pip',
        '      "$ANSIBLE_VENV/bin/python" -m pip install ansible',
        '      PATH="$ANSIBLE_VENV/bin:$PATH"',
        '    else',
        '      python3 -m pip install --user --break-system-packages ansible',
        '      PATH="$HOME/.local/bin:$PATH"',
        '    fi',
        '  fi',
        'fi'
    )
} else {
    $installBlockLines = @(
        'ANSIBLE_VENV="$HOME/.local/share/homelab-infra-ansible-venv"',
        'PATH="$HOME/.local/bin:$PATH"',
        'if [ -x "$ANSIBLE_VENV/bin/ansible-playbook" ]; then',
        '  PATH="$ANSIBLE_VENV/bin:$PATH"',
        'fi',
        'if ! command -v ansible-playbook >/dev/null 2>&1; then',
        "  echo 'ansible-playbook not found in WSL. Install it with: sudo apt-get update && sudo apt-get install -y ansible, or rerun this wrapper with -InstallDependencies to create a user venv.' >&2",
        '  exit 20',
        'fi'
    )
}
$installBlock = $installBlockLines -join "`n"

$shellScript = @"
set -eu
cd $(Quote-Sh $ansibleDir)
export ANSIBLE_CONFIG="`$PWD/ansible.cfg"
$installBlock
mkdir -p "`$HOME/.ssh"
chmod 700 "`$HOME/.ssh"
if ! ssh-keygen -F $(Quote-Sh $TargetHost) >/dev/null 2>&1; then
  ssh-keyscan -H $(Quote-Sh $TargetHost) >> "`$HOME/.ssh/known_hosts"
fi
KEY_ARG=""
if [ -n $(Quote-Sh $wslIdentityFile) ]; then
  KEY_FILE="`$(mktemp)"
  cp $(Quote-Sh $wslIdentityFile) "`$KEY_FILE"
  chmod 600 "`$KEY_FILE"
  trap 'rm -f "`$KEY_FILE"' EXIT
  KEY_ARG="--private-key `$KEY_FILE"
fi
ansible-playbook -i inventory.yml $(Quote-Sh $playbook) --limit $(Quote-Sh $limitArg) `$KEY_ARG $checkArg
"@

$tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "opnsense-coretemp-ansible-$PID.sh"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
    $normalizedScript = ($shellScript -replace "`r`n?", "`n")
    [System.IO.File]::WriteAllText($tempScript, $normalizedScript, $utf8NoBom)
    $wslTempScript = Convert-ToWslPath -Path $tempScript
    wsl.exe -d $Distro sh $wslTempScript
    if ($LASTEXITCODE -ne 0) {
        throw "WSL Ansible deploy failed with exit code $LASTEXITCODE"
    }
} finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}