from __future__ import annotations

from homelab_backup.status import read_status, write_status_atomic


def test_status_atomic_write(tmp_path):
    path = tmp_path / "status" / "app-test.json"
    write_status_atomic(path, {"service": "app-test", "status": "success"})
    assert read_status(path)["status"] == "success"
    assert not list(path.parent.glob("*.tmp"))
