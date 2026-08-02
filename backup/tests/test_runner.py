from __future__ import annotations

import homelab_backup.runner as runner_module
from homelab_backup.docker import ContainerState
from homelab_backup.models import ServiceConfig
from homelab_backup.rsync import RsyncResult, RsyncStats
from homelab_backup.runner import BackupRunner


def config(tmp_path) -> ServiceConfig:
    source = tmp_path / "source"
    source.mkdir()
    dest_root = tmp_path / "backup"
    dest_root.mkdir()
    return ServiceConfig.model_validate(
        {
            "service_id": "app-test",
            "docker": {
                "enabled": True,
                "compose_project": "test",
                "compose_service": "test",
                "consistency_mode": "stop-container",
                "require_healthy": False,
            },
            "backup": {
                "destination_root": str(dest_root),
                "destination_subdir": "app-test/data",
                "sources": [{"source": str(source)}],
            },
            "safety": {
                "expected_mountpoint": str(dest_root),
                "require_mountpoint": False,
                "allowed_destination_prefix": str(dest_root),
                "minimum_free_space_mb": 0,
            },
            "status": {"file_path": str(tmp_path / "status" / "app-test.json")},
            "logging": {"file_enabled": False},
        }
    )


class FakeDocker:
    def __init__(self, running=True):
        self.running = running
        self.stopped = False
        self.started = False

    def check_daemon(self):
        pass

    def find_container(self, docker_config):
        return "abc"

    def inspect(self, container_id):
        return ContainerState("abc", "app-test-1", self.running, "unhealthy")

    def stop(self, container_id, timeout_seconds):
        self.stopped = True
        self.running = False

    def start(self, container_id):
        self.started = True
        self.running = True

    def wait_running_or_healthy(self, container_id, *, timeout_seconds, require_healthy):
        return ContainerState("abc", "app-test-1", True, "unhealthy")


class FakeRsync:
    def __init__(self):
        self.ran = False

    def run(self, rsync_config, source, destination_root, *, dry_run=False):
        self.ran = True
        return RsyncResult([], 0, RsyncStats(1, 2), "", "")


def test_run_stops_and_restores(tmp_path, monkeypatch):
    monkeypatch.setattr(runner_module, "run_preflight", lambda *args, **kwargs: None)
    docker = FakeDocker(running=True)
    rsync = FakeRsync()
    result = BackupRunner(docker=docker, rsync=rsync, lock_root=tmp_path / "locks").run(
        config(tmp_path)
    )
    assert docker.stopped is True
    assert docker.started is True
    assert rsync.ran is True
    assert result["status"] == "success"


def test_dry_run_does_not_stop_or_rsync(tmp_path, monkeypatch):
    monkeypatch.setattr(runner_module, "run_preflight", lambda *args, **kwargs: None)
    docker = FakeDocker(running=True)
    rsync = FakeRsync()
    result = BackupRunner(docker=docker, rsync=rsync, lock_root=tmp_path / "locks").run(
        config(tmp_path), dry_run=True
    )
    assert docker.stopped is False
    assert docker.started is False
    assert rsync.ran is False
    assert result["dry_run"] is True
