from __future__ import annotations


class BackupError(Exception):
    """Base class for expected operational backup failures."""

    exit_code = 1
    stage = "general"


class ConfigError(BackupError):
    exit_code = 2
    stage = "config"


class PreflightError(BackupError):
    exit_code = 3
    stage = "preflight"


class LockAlreadyHeld(BackupError):
    exit_code = 4
    stage = "lock"


class DockerError(BackupError):
    exit_code = 5
    stage = "docker"


class RsyncError(BackupError):
    exit_code = 6
    stage = "rsync"

    def __init__(self, message: str, returncode: int | None = None) -> None:
        super().__init__(message)
        self.returncode = returncode


class RestoreError(BackupError):
    exit_code = 7
    stage = "restore"


class DeployError(BackupError):
    exit_code = 8
    stage = "deploy"
