from __future__ import annotations

import pytest

from homelab_backup.config import load_service_config
from homelab_backup.exceptions import ConfigError


def write_service(tmp_path, text: str) -> None:
    (tmp_path / "services").mkdir()
    (tmp_path / "defaults.yaml").write_text(
        "safety:\n"
        "  expected_mountpoint: /mnt/backup/services\n"
        "  allowed_destination_prefix: /mnt/backup/services\n"
        "status:\n"
        "  file_path: /var/lib/homelab-backup/status/test.json\n",
        encoding="utf-8",
    )
    (tmp_path / "services" / "test.yaml").write_text(text, encoding="utf-8")


def test_load_service_config(tmp_path):
    write_service(
        tmp_path,
        "service_id: test\n"
        "backup:\n"
        "  destination_root: /mnt/backup/services\n"
        "  destination_subdir: app-test/data\n"
        "  sources:\n"
        "    - source: /mnt/configs/test\n"
        "docker:\n"
        "  enabled: false\n",
    )
    config = load_service_config("test", tmp_path)
    assert config.service_id == "test"
    assert config.destination_path.as_posix() == "/mnt/backup/services/app-test/data"


def test_unknown_fields_are_rejected(tmp_path):
    write_service(
        tmp_path,
        "service_id: test\n"
        "unknown: true\n"
        "backup:\n"
        "  destination_root: /mnt/backup/services\n"
        "  destination_subdir: app-test/data\n"
        "  sources:\n"
        "    - source: /mnt/configs/test\n"
        "docker:\n"
        "  enabled: false\n",
    )
    with pytest.raises(ConfigError):
        load_service_config("test", tmp_path)
