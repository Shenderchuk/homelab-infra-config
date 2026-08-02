# AGENTS.md

## Environment

This workspace contains homelab infrastructure and Docker configuration repositories.

Available SSH access:

```bash
ssh -i ~/.ssh/home_pc root@portainer-host
ssh -i ~/.ssh/home_pc root@grafana-host
ssh -i ~/.ssh/home_pc root@loki-host

```

Additional host-specific SSH keys may already exist on remote systems. Inspect existing configuration before creating or replacing access methods.

## Working rules

* Inspect the existing repository structure and conventions before making changes.
* Verify actual host state before assuming paths, services, container names, ports, or mounts.
* Prefer declarative, repeatable, GitOps-compatible changes.
* Use validation and dry-run modes where available.
* Do not perform destructive actions without verifying the target.
* Do not modify unrelated services.
* Do not expose or commit secrets, private keys, tokens, passwords, or `.env` contents.
* Do not disable SSH host key verification.
* Preserve existing deployment and naming conventions unless there is a clear reason to change them.
* After changes, run relevant tests or validation and summarize the modified files.
