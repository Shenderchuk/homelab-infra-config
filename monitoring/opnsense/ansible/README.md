# OPNsense Coretemp Ansible

This Ansible entrypoint persists Intel CPU temperature support on OPNsense by
managing `/boot/loader.conf.local`:

```conf
coretemp_load="YES"
```

Do not manage `/boot/loader.conf` directly. OPNsense generates that file and
documents `/boot/loader.conf.local` or GUI tunables as the supported custom
locations.

## Run From Windows Through WSL

The wrapper uses the default WSL Ubuntu distro and the repository mounted under
`/mnt/d/Projects/01 Github/homelab-infra-config`.

Dry run:

```powershell
.\monitoring\opnsense\ansible\deploy-coretemp-from-wsl.ps1 -Check
```

Install Ansible in WSL if needed and apply. The wrapper first tries apt with non-interactive sudo; if sudo is unavailable, it falls back to a WSL user install under `$HOME/.local`:

```powershell
.\monitoring\opnsense\ansible\deploy-coretemp-from-wsl.ps1 -InstallDependencies
```

Apply when Ansible is already installed:

```powershell
.\monitoring\opnsense\ansible\deploy-coretemp-from-wsl.ps1
```

The wrapper uses `ssh-keyscan` to add the OPNsense host key to WSL
`~/.ssh/known_hosts` when missing. It does not disable SSH host key checking.

By default it uses the Windows SSH key at `%USERPROFILE%\.ssh\home_pc`. Because
WSL refuses private keys directly from DrvFS when permissions appear as `0777`,
the wrapper copies the key to a temporary WSL file, applies `chmod 600`, passes
it to Ansible with `--private-key`, and removes the temporary copy after the
run. Override with `-IdentityFile C:\path\to\key` if needed.

## Verify

On `gw01-i7505`:

```sh
cat /boot/loader.conf.local
kldstat -q -m coretemp
sysctl dev.cpu.0.temperature dev.cpu.1.temperature dev.cpu.2.temperature dev.cpu.3.temperature
/usr/local/bin/opnsense-temperature.sh
```

The temperature script should emit `type=cpu_core` lines once `coretemp` is
loaded.
