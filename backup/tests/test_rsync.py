from __future__ import annotations

from pathlib import Path

from homelab_backup.models import RsyncConfig, SourceConfig
from homelab_backup.rsync import build_rsync_args, parse_rsync_stats


def test_build_rsync_args_has_safe_options():
    args = build_rsync_args(
        RsyncConfig(),
        SourceConfig(source=Path("/mnt/configs/navidrome"), destination=Path(".")),
        Path("/mnt/backup/services/app-navidrome/data"),
        dry_run=True,
    )
    assert args[0] == "rsync"
    assert "--dry-run" in args
    assert "--delete-delay" in args
    assert "--inplace" not in args
    assert args[-2] == "/mnt/configs/navidrome/"


def test_parse_rsync_stats():
    stats = parse_rsync_stats(
        "Number of regular files transferred: 4\nTotal transferred file size: 12,345 bytes\n"
    )
    assert stats.files_transferred == 4
    assert stats.bytes_transferred == 12345
