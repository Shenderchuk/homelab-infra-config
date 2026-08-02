from __future__ import annotations

import os
from pathlib import Path, PurePosixPath

from homelab_backup.exceptions import PreflightError
from homelab_backup.models import ServiceConfig
from homelab_backup.mounts import MountInspector, free_space_mb
from homelab_backup.utils import require_binary


def _posix(value: Path) -> PurePosixPath:
    return PurePosixPath(value.as_posix().replace("\\", "/"))


def validate_destination_paths(config: ServiceConfig) -> Path:
    destination = config.destination_path
    destination_posix = _posix(destination)
    allowed = _posix(config.safety.allowed_destination_prefix)
    root = _posix(config.backup.destination_root)
    if destination_posix in {PurePosixPath("/"), root, allowed}:
        raise PreflightError("backup destination is too broad")
    if allowed not in destination_posix.parents:
        raise PreflightError("backup destination escapes allowed prefix")
    if any(part == ".." for part in config.backup.destination_subdir.parts):
        raise PreflightError("backup destination contains path traversal")
    if (
        config.safety.reject_symlink_destination
        and destination.exists()
        and destination.is_symlink()
    ):
        raise PreflightError("backup destination must not be a symlink")
    return destination


def run_preflight(
    config: ServiceConfig,
    mount_inspector: MountInspector | None = None,
    *,
    create_destination: bool = True,
) -> None:
    require_binary("rsync")
    if config.docker.enabled:
        require_binary("docker")

    for source in config.backup.sources:
        if not source.source.exists():
            if source.required:
                raise PreflightError(f"source does not exist: {source.source}")
            continue
        if not os.access(source.source, os.R_OK):
            raise PreflightError(f"source is not readable: {source.source}")

    destination = validate_destination_paths(config)
    root = config.backup.destination_root
    if not root.exists():
        raise PreflightError(f"destination root does not exist: {root}")
    if root.is_symlink():
        raise PreflightError(f"destination root must not be a symlink: {root}")
    if create_destination:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.mkdir(parents=True, exist_ok=True)
        writable_target = destination
    else:
        writable_target = destination if destination.exists() else destination.parent
        while not writable_target.exists() and writable_target != root:
            writable_target = writable_target.parent
    if not writable_target.exists():
        raise PreflightError(f"destination parent does not exist: {writable_target}")
    if not os.access(writable_target, os.W_OK):
        raise PreflightError(f"destination is not writable: {writable_target}")

    if config.safety.require_mountpoint:
        inspector = mount_inspector or MountInspector()
        mount = inspector.find_mount(config.safety.expected_mountpoint)
        expected = config.safety.expected_mountpoint
        if not (mount.target == expected or mount.target in expected.parents):
            raise PreflightError(f"unexpected mount target for {expected}: {mount.target}")
        if mount.read_only:
            raise PreflightError(f"mount is read-only: {mount.target}")

    available = free_space_mb(root)
    if available < config.safety.minimum_free_space_mb:
        raise PreflightError(
            f"insufficient free space: {available} MiB available, "
            f"{config.safety.minimum_free_space_mb} MiB required"
        )
