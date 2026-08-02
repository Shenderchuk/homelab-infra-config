from __future__ import annotations

import logging
import time
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from homelab_backup.docker import ContainerState, DockerClient
from homelab_backup.exceptions import BackupError, DockerError, RestoreError, RsyncError
from homelab_backup.locking import FileLock
from homelab_backup.models import ConsistencyMode, ServiceConfig
from homelab_backup.rsync import RsyncClient, RsyncStats, build_rsync_args
from homelab_backup.status import write_status_atomic
from homelab_backup.validation import run_preflight


class BackupRunner:
    def __init__(
        self,
        *,
        docker: DockerClient | None = None,
        rsync: RsyncClient | None = None,
        lock_root: Path = Path("/var/lib/homelab-backup/locks"),
        logger: logging.Logger | logging.LoggerAdapter[Any] | None = None,
    ) -> None:
        self.docker = docker or DockerClient()
        self.rsync = rsync or RsyncClient()
        self.lock_root = lock_root
        self.logger = logger or logging.getLogger("homelab_backup")

    @staticmethod
    def _now() -> datetime:
        try:
            return datetime.now(ZoneInfo("Europe/Kyiv"))
        except ZoneInfoNotFoundError:
            return datetime.now().astimezone()

    def inspect(self, config: ServiceConfig) -> dict[str, Any]:
        payload = config.public_dict()
        if config.docker.enabled:
            self.docker.check_daemon()
            container_id = self.docker.find_container(config.docker)
            state = self.docker.inspect(container_id)
            payload["container"] = {
                "id": state.container_id,
                "name": state.name,
                "running": state.running,
                "health": state.health,
            }
        return payload

    def run(self, config: ServiceConfig, *, dry_run: bool = False) -> dict[str, Any]:
        lock_path = self.lock_root / f"{config.service_id}.lock"
        with FileLock(lock_path):
            return self._run_locked(config, dry_run=dry_run)

    def _run_locked(self, config: ServiceConfig, *, dry_run: bool) -> dict[str, Any]:
        started = self._now()
        started_monotonic = time.monotonic()
        container_id: str | None = None
        container_before: ContainerState | None = None
        container_after: ContainerState | None = None
        container_restored = False
        primary_error: BackupError | None = None
        restore_error: RestoreError | None = None
        stats = RsyncStats()
        status_payload: dict[str, Any]

        self.logger.info("Backup started", extra={"event": "backup_started", "dry_run": dry_run})
        try:
            run_preflight(config, create_destination=not dry_run)
            if config.docker.enabled:
                self.docker.check_daemon()
                container_id = self.docker.find_container(config.docker)
                container_before = self.docker.inspect(container_id)
                self.logger.info(
                    "Container inspected",
                    extra={
                        "event": "container_inspected",
                        "container": container_before.name,
                        "running": container_before.running,
                        "health": container_before.health,
                    },
                )
                if (
                    not dry_run
                    and container_before.running
                    and config.docker.consistency_mode == ConsistencyMode.STOP_CONTAINER
                ):
                    self.docker.stop(container_id, config.docker.stop_timeout_seconds)
                    self.logger.info(
                        "Container stopped",
                        extra={"event": "container_stopped", "container": container_before.name},
                    )

            try:
                if dry_run:
                    for source in config.backup.sources:
                        args = build_rsync_args(
                            config.rsync,
                            source,
                            config.destination_path,
                            dry_run=True,
                        )
                        self.logger.info(
                            "Rsync dry-run prepared",
                            extra={
                                "event": "rsync_dry_run_prepared",
                                "command": args[:2] + ["<paths-redacted>"],
                            },
                        )
                else:
                    for source in config.backup.sources:
                        result = self.rsync.run(
                            config.rsync,
                            source,
                            config.destination_path,
                            dry_run=False,
                        )
                        stats = result.stats
                        self.logger.info(
                            "Rsync completed",
                            extra={
                                "event": "rsync_completed",
                                "returncode": result.returncode,
                                "files_transferred": stats.files_transferred,
                                "bytes_transferred": stats.bytes_transferred,
                                "command": result.args[:2] + ["<paths-redacted>"],
                            },
                        )
            except RsyncError as exc:
                primary_error = exc
                raise
        except BackupError as exc:
            primary_error = primary_error or exc
            raise
        finally:
            if (
                not dry_run
                and config.docker.enabled
                and container_id
                and container_before
                and container_before.running
                and config.docker.consistency_mode == ConsistencyMode.STOP_CONTAINER
            ):
                try:
                    self.docker.start(container_id)
                    container_after = self.docker.wait_running_or_healthy(
                        container_id,
                        timeout_seconds=config.docker.start_timeout_seconds,
                        require_healthy=config.docker.require_healthy,
                    )
                    container_restored = container_after.running
                    self.logger.info(
                        "Container restored",
                        extra={
                            "event": "container_restored",
                            "container": container_after.name,
                            "running": container_after.running,
                            "health": container_after.health,
                        },
                    )
                except DockerError as exc:
                    restore_error = RestoreError(str(exc))
                    self.logger.critical(
                        "Container could not be restarted after backup",
                        extra={"event": "container_restore_failed", "container_id": container_id},
                    )

            finished = self._now()
            duration = round(time.monotonic() - started_monotonic, 3)
            container_health = None
            if container_after is not None:
                container_health = container_after.health
            elif container_before is not None:
                container_health = container_before.health
            status_payload = {
                "service": config.service_id,
                "status": "failure" if primary_error or restore_error else "success",
                "started_at": started.isoformat(timespec="seconds"),
                "finished_at": finished.isoformat(timespec="seconds"),
                "duration_seconds": duration,
                "sources": [str(source.source) for source in config.backup.sources],
                "destination": str(config.destination_path),
                "files_transferred": stats.files_transferred,
                "bytes_transferred": stats.bytes_transferred,
                "container_was_running": container_before.running if container_before else None,
                "container_restored": container_restored,
                "container_healthy": (
                    container_after.health == "healthy"
                    if container_after and container_after.health is not None
                    else None
                ),
                "container_health": container_health,
                "dry_run": dry_run,
            }
            write_status_atomic(config.status.file_path, status_payload)
            if primary_error or restore_error:
                error = primary_error or restore_error
                assert error is not None
                self.logger.error(
                    "Backup failed",
                    extra={
                        "event": "backup_failed",
                        "stage": error.stage,
                        "duration_seconds": duration,
                    },
                )
            else:
                self.logger.info(
                    "Backup completed",
                    extra={"event": "backup_completed", "duration_seconds": duration},
                )

        if restore_error and primary_error is None:
            raise restore_error
        if restore_error and primary_error is not None:
            primary_error.add_note(f"also failed to restore container: {restore_error}")
        return status_payload
