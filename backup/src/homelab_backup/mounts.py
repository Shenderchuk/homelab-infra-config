from __future__ import annotations

import json
import shutil
from dataclasses import dataclass
from pathlib import Path

from homelab_backup.exceptions import PreflightError
from homelab_backup.utils import CommandRunner


@dataclass(frozen=True)
class MountInfo:
    target: Path
    source: str
    fstype: str
    options: list[str]

    @property
    def read_only(self) -> bool:
        return "ro" in self.options


class MountInspector:
    def __init__(self, runner: CommandRunner | None = None) -> None:
        self.runner = runner or CommandRunner()

    def find_mount(self, path: Path) -> MountInfo:
        result = self.runner.run(
            ["findmnt", "-J", "-T", str(path), "-o", "TARGET,SOURCE,FSTYPE,OPTIONS"]
        )
        if result.returncode != 0:
            raise PreflightError(f"mount not found for {path}")
        try:
            filesystems = json.loads(result.stdout).get("filesystems", [])
            item = filesystems[0]
        except (json.JSONDecodeError, IndexError, KeyError) as exc:
            raise PreflightError(f"invalid findmnt output for {path}") from exc
        options = str(item.get("options", "")).split(",") if item.get("options") else []
        return MountInfo(
            target=Path(str(item["target"])),
            source=str(item.get("source", "")),
            fstype=str(item.get("fstype", "")),
            options=options,
        )


def free_space_mb(path: Path) -> int:
    usage = shutil.disk_usage(path)
    return int(usage.free / 1024 / 1024)
