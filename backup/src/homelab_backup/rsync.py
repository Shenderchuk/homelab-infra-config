from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from homelab_backup.exceptions import RsyncError
from homelab_backup.models import RsyncConfig, SourceConfig
from homelab_backup.utils import CommandRunner, redact


@dataclass(frozen=True)
class RsyncStats:
    files_transferred: int | None = None
    bytes_transferred: int | None = None


@dataclass(frozen=True)
class RsyncResult:
    args: list[str]
    returncode: int
    stats: RsyncStats
    stdout: str
    stderr: str


def _source_arg(path: Path) -> str:
    value = path.as_posix()
    return value if value.endswith("/") else value + "/"


def build_rsync_args(
    config: RsyncConfig,
    source: SourceConfig,
    destination_root: Path,
    *,
    dry_run: bool = False,
) -> list[str]:
    args = ["rsync"]
    if config.archive:
        args.append("-a")
    if config.hard_links:
        args.append("-H")
    if config.acls:
        args.append("-A")
    if config.xattrs:
        args.append("-X")
    if config.numeric_ids:
        args.append("--numeric-ids")
    if config.delete:
        args.append("--delete")
    if config.delete_delay:
        args.append("--delete-delay")
    if dry_run:
        args.append("--dry-run")
    args.append("--stats")
    for exclude in config.excludes:
        args.extend(["--exclude", exclude])
    destination = destination_root / source.destination
    args.extend([_source_arg(source.source), destination.as_posix() + "/"])
    return args


def parse_rsync_stats(stdout: str) -> RsyncStats:
    files: int | None = None
    bytes_count: int | None = None
    for line in stdout.splitlines():
        if line.startswith("Number of regular files transferred:"):
            files = int(re.sub(r"[^0-9]", "", line.split(":", 1)[1]) or "0")
        elif line.startswith("Total transferred file size:"):
            bytes_count = int(re.sub(r"[^0-9]", "", line.split(":", 1)[1]) or "0")
    return RsyncStats(files_transferred=files, bytes_transferred=bytes_count)


class RsyncClient:
    def __init__(self, runner: CommandRunner | None = None) -> None:
        self.runner = runner or CommandRunner()

    def run(
        self,
        config: RsyncConfig,
        source: SourceConfig,
        destination_root: Path,
        *,
        dry_run: bool = False,
    ) -> RsyncResult:
        args = build_rsync_args(config, source, destination_root, dry_run=dry_run)
        result = self.runner.run(args)
        stats = parse_rsync_stats(result.stdout)
        if result.returncode != 0:
            raise RsyncError(
                f"rsync failed with exit code {result.returncode}: {redact(result.stderr, 1000)}",
                result.returncode,
            )
        return RsyncResult(
            args=args,
            returncode=result.returncode,
            stats=stats,
            stdout=result.stdout,
            stderr=result.stderr,
        )
