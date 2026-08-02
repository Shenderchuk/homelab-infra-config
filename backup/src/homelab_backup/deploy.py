from __future__ import annotations

import filecmp
import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from homelab_backup.exceptions import DeployError
from homelab_backup.utils import CommandRunner, ensure_dir

REPO_URL = "ssh://git@192.168.50.42:2222/homelab/infra-config.git"
DEPLOY_KEY = Path("/root/.ssh/portainer")
KNOWN_HOSTS = Path("/root/.ssh/known_hosts")
CHECKOUT_DIR = Path("/opt/homelab-infra-config")
APP_ROOT = Path("/opt/homelab-backup")
VENV_DIR = APP_ROOT / ".venv"
CONFIG_DIR = Path("/etc/homelab-backup")
SYSTEMD_DIR = Path("/etc/systemd/system")
STATE_DIR = Path("/var/lib/homelab-backup")
LOG_DIR = Path("/var/log/homelab-backup")


@dataclass
class DeployReport:
    dry_run: bool
    changed: list[str] = field(default_factory=list)
    actions: list[str] = field(default_factory=list)


def _parse_scalar(value: str) -> Any:
    cleaned = value.strip().strip('"').strip("'")
    if cleaned.lower() == "true":
        return True
    if cleaned.lower() == "false":
        return False
    try:
        return int(cleaned)
    except ValueError:
        return cleaned


def read_deploy_service_config(path: Path) -> dict[str, Any]:
    data: dict[str, Any] = {"schedule": {}}
    in_schedule = False
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        line = raw_line.strip()
        if indent == 0:
            in_schedule = line == "schedule:"
            if ":" in line and not in_schedule:
                key, value = line.split(":", 1)
                data[key] = _parse_scalar(value)
            continue
        if in_schedule and ":" in line:
            key, value = line.split(":", 1)
            data["schedule"][key] = _parse_scalar(value)
    if "service_id" not in data:
        raise DeployError(f"service_id missing in {path}")
    return data


class Deployer:
    def __init__(
        self,
        *,
        repo_root: Path | None = None,
        runner: CommandRunner | None = None,
        dry_run: bool = False,
    ) -> None:
        if repo_root is not None:
            self.source_root = repo_root
        elif CHECKOUT_DIR.exists():
            self.source_root = CHECKOUT_DIR
        elif (Path.cwd() / "backup").exists():
            self.source_root = Path.cwd()
        else:
            self.source_root = CHECKOUT_DIR
        self.runner = runner or CommandRunner()
        self.report = DeployReport(dry_run=dry_run)

    def _record(self, action: str) -> None:
        self.report.actions.append(action)

    def _run(
        self,
        args: list[str],
        *,
        env: dict[str, str] | None = None,
        cwd: Path | None = None,
    ) -> None:
        self._record(" ".join(args))
        if self.report.dry_run:
            return
        result = self.runner.run(args, env=env, cwd=cwd)
        if result.returncode != 0:
            raise DeployError(f"command failed: {' '.join(args)}")

    def detect_os(self) -> str:
        os_release = Path("/etc/os-release")
        if not os_release.exists():
            return "unknown"
        return os_release.read_text(encoding="utf-8")

    def ensure_system_dependencies(self) -> None:
        os_release = self.detect_os()
        required = (
            "python3",
            "pip3",
            "rsync",
            "git",
            "ssh-keyscan",
            "systemctl",
            "findmnt",
            "flock",
        )
        missing = [binary for binary in required if shutil.which(binary) is None]
        venv_check = self.runner.run(["python3", "-m", "venv", "--help"])
        if venv_check.returncode != 0:
            missing.append("python3-venv")
        if not missing:
            return
        if self.report.dry_run:
            self._record(f"would install missing dependencies: {', '.join(missing)}")
            return
        if "Debian" not in os_release and "Ubuntu" not in os_release:
            raise DeployError(f"missing dependencies on unsupported OS: {', '.join(missing)}")
        self._run(["apt-get", "update"])
        self._run(
            [
                "apt-get",
                "install",
                "-y",
                "python3",
                "python3-venv",
                "python3-pip",
                "rsync",
                "git",
                "openssh-client",
            ]
        )

    def ensure_known_host(self) -> None:
        existing = KNOWN_HOSTS.read_text(encoding="utf-8") if KNOWN_HOSTS.exists() else ""
        if "[192.168.50.42]:2222" in existing:
            return
        self._record("ssh-keyscan -p 2222 192.168.50.42 >> /root/.ssh/known_hosts")
        if self.report.dry_run:
            return
        ensure_dir(KNOWN_HOSTS.parent, 0o700)
        result = self.runner.run(["ssh-keyscan", "-p", "2222", "192.168.50.42"])
        if result.returncode != 0 or not result.stdout.strip():
            raise DeployError("failed to obtain Gitea SSH host key")
        with KNOWN_HOSTS.open("a", encoding="utf-8") as handle:
            handle.write(result.stdout)
        os.chmod(KNOWN_HOSTS, 0o644)

    def git_env(self) -> dict[str, str]:
        env = dict(os.environ)
        env["GIT_SSH_COMMAND"] = (
            f"ssh -i {DEPLOY_KEY} -o IdentitiesOnly=yes "
            f"-o BatchMode=yes -o UserKnownHostsFile={KNOWN_HOSTS}"
        )
        return env

    def clone_or_update_repo(self) -> None:
        if not self.report.dry_run:
            ensure_dir(CHECKOUT_DIR.parent, 0o755)
        if not (CHECKOUT_DIR / ".git").exists():
            self._run(["git", "clone", REPO_URL, str(CHECKOUT_DIR)], env=self.git_env())
            if not self.report.dry_run:
                self.source_root = CHECKOUT_DIR
            return
        status = self.runner.run(["git", "status", "--short"], cwd=CHECKOUT_DIR)
        if status.returncode != 0:
            raise DeployError("failed to inspect checkout")
        if status.stdout.strip():
            raise DeployError("checkout is dirty; refusing to deploy")
        self._run(
            ["git", "fetch", "--prune", "origin", "main"],
            cwd=CHECKOUT_DIR,
            env=self.git_env(),
        )
        self._run(
            ["git", "merge", "--ff-only", "origin/main"],
            cwd=CHECKOUT_DIR,
            env=self.git_env(),
        )
        self.source_root = CHECKOUT_DIR

    def install_python(self) -> None:
        if not self.report.dry_run:
            ensure_dir(APP_ROOT, 0o755)
        if not VENV_DIR.exists():
            self._run(["python3", "-m", "venv", str(VENV_DIR)])
        pip = VENV_DIR / "bin" / "pip"
        python = VENV_DIR / "bin" / "python"
        self._run([str(python), "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"])
        self._run(
            [
                str(pip),
                "install",
                "--requirement",
                str(CHECKOUT_DIR / "backup" / "requirements.txt"),
            ]
        )
        self._run([str(pip), "install", str(CHECKOUT_DIR / "backup")])
        self._run([str(VENV_DIR / "bin" / "homelab-backup"), "--help"])

    def copy_if_changed(self, source: Path, destination: Path, mode: int = 0o644) -> None:
        if not self.report.dry_run:
            ensure_dir(destination.parent, 0o755)
        if not source.exists():
            if self.report.dry_run:
                self.report.changed.append(str(destination))
                self._record(f"install {source} {destination}")
                return
            raise DeployError(f"source file missing: {source}")
        if destination.exists() and filecmp.cmp(source, destination, shallow=False):
            return
        self.report.changed.append(str(destination))
        self._record(f"install {source} {destination}")
        if self.report.dry_run:
            return
        shutil.copy2(source, destination)
        os.chmod(destination, mode)

    def install_configs(self) -> None:
        source_backup = self.source_root / "backup"
        self.copy_if_changed(
            source_backup / "config" / "defaults.yaml", CONFIG_DIR / "defaults.yaml"
        )
        services_src = source_backup / "config" / "services"
        if not self.report.dry_run:
            ensure_dir(CONFIG_DIR / "services", 0o755)
        for service_config in services_src.glob("*.yaml"):
            self.copy_if_changed(service_config, CONFIG_DIR / "services" / service_config.name)

    def install_systemd(self, *, enable_timers: bool = False) -> None:
        source_systemd = self.source_root / "backup" / "systemd"
        for unit in (
            "homelab-service-backup@.service",
            "homelab-service-backup@.timer",
            "homelab-backup-deploy.service",
            "homelab-backup-deploy.timer",
        ):
            self.copy_if_changed(source_systemd / unit, SYSTEMD_DIR / unit)
        self.generate_timer_dropins()
        self._run(["systemctl", "daemon-reload"])
        self._run(["systemctl", "enable", "--now", "homelab-backup-deploy.timer"])
        if enable_timers:
            for service_id in self.enabled_services():
                self._run(
                    ["systemctl", "enable", "--now", f"homelab-service-backup@{service_id}.timer"]
                )

    def generate_timer_dropins(self) -> None:
        services_dir = self.source_root / "backup" / "config" / "services"
        for service_path in services_dir.glob("*.yaml"):
            data = read_deploy_service_config(service_path)
            if not data.get("enabled", True):
                continue
            service_id = str(data["service_id"])
            schedule = data.get("schedule", {})
            on_calendar = schedule.get("on_calendar", "*-*-* 03:20:00")
            persistent = str(schedule.get("persistent", True)).lower()
            randomized = int(schedule.get("randomized_delay_seconds", 0))
            content = (
                "[Timer]\n"
                "OnCalendar=\n"
                f"OnCalendar={on_calendar}\n"
                f"Persistent={persistent}\n"
                f"RandomizedDelaySec={randomized}\n"
            )
            dropin = SYSTEMD_DIR / f"homelab-service-backup@{service_id}.timer.d" / "schedule.conf"
            if dropin.exists() and dropin.read_text(encoding="utf-8") == content:
                continue
            self.report.changed.append(str(dropin))
            self._record(f"write {dropin}")
            if not self.report.dry_run:
                ensure_dir(dropin.parent, 0o755)
                dropin.write_text(content, encoding="utf-8")

    def enabled_services(self) -> list[str]:
        result: list[str] = []
        services_dir = self.source_root / "backup" / "config" / "services"
        for service_path in services_dir.glob("*.yaml"):
            data = read_deploy_service_config(service_path)
            if data.get("enabled", True):
                result.append(str(data["service_id"]))
        return sorted(result)

    def create_runtime_dirs(self) -> None:
        for path in (STATE_DIR / "locks", STATE_DIR / "status", STATE_DIR / "state", LOG_DIR):
            self._record(f"mkdir -p {path}")
            if not self.report.dry_run:
                ensure_dir(path, 0o755)

    def validate_configs(self) -> None:
        cli = VENV_DIR / "bin" / "homelab-backup"
        for service_id in self.enabled_services():
            self._run([str(cli), "validate", service_id])

    def install(self, *, enable_timers: bool = False) -> DeployReport:
        self.ensure_system_dependencies()
        self.ensure_known_host()
        self.clone_or_update_repo()
        self.create_runtime_dirs()
        self.install_python()
        self.install_configs()
        self.install_systemd(enable_timers=enable_timers)
        self.validate_configs()
        return self.report

    def status(self) -> DeployReport:
        self._run(["systemctl", "status", "homelab-backup-deploy.timer"])
        return self.report

    def rollback(self) -> DeployReport:
        if not CHECKOUT_DIR.exists():
            raise DeployError("checkout does not exist; nothing to roll back")
        self._run(["git", "merge", "--abort"], cwd=CHECKOUT_DIR, env=self.git_env())
        return self.report
