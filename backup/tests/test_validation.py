from __future__ import annotations

from pathlib import Path

import pytest

from homelab_backup.exceptions import PreflightError
from homelab_backup.models import ServiceConfig
from homelab_backup.validation import validate_destination_paths


def make_config(destination_subdir: str = "app-test/data") -> ServiceConfig:
    return ServiceConfig.model_validate(
        {
            "service_id": "app-test",
            "docker": {"enabled": False},
            "backup": {
                "destination_root": "/mnt/backup/services",
                "destination_subdir": destination_subdir,
                "sources": [{"source": "/mnt/configs/test"}],
            },
            "safety": {
                "expected_mountpoint": "/mnt/backup/services",
                "allowed_destination_prefix": "/mnt/backup/services",
            },
            "status": {"file_path": "/var/lib/homelab-backup/status/app-test.json"},
        }
    )


def test_valid_destination():
    assert validate_destination_paths(make_config()) == Path("/mnt/backup/services/app-test/data")


@pytest.mark.parametrize("subdir", [".", "app-test", "../escape", "app-test/../../escape"])
def test_invalid_destination_subdir(subdir: str):
    with pytest.raises(ValueError):
        make_config(subdir)


def test_destination_root_only_rejected():
    with pytest.raises(ValueError):
        ServiceConfig.model_validate(
            {
                "service_id": "app-test",
                "docker": {"enabled": False},
                "backup": {
                    "destination_root": "/mnt/backup/services",
                    "destination_subdir": "app-test",
                    "sources": [{"source": "/mnt/configs/test"}],
                },
                "safety": {
                    "expected_mountpoint": "/mnt/backup/services",
                    "allowed_destination_prefix": "/mnt/backup/services",
                },
                "status": {"file_path": "/var/lib/homelab-backup/status/app-test.json"},
            }
        )


def test_validate_destination_paths_runtime_escape():
    config = make_config()
    object.__setattr__(config.backup, "destination_subdir", Path("app-test/data"))
    object.__setattr__(config.safety, "allowed_destination_prefix", Path("/other"))
    with pytest.raises(PreflightError):
        validate_destination_paths(config)
