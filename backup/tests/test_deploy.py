from __future__ import annotations

import homelab_backup.deploy as deploy_module
from homelab_backup.deploy import Deployer


def test_generate_timer_dropin(tmp_path, monkeypatch):
    checkout = tmp_path / "checkout"
    services = checkout / "backup" / "config" / "services"
    services.mkdir(parents=True)
    (services / "app-test.yaml").write_text(
        "service_id: app-test\n"
        "enabled: true\n"
        "schedule:\n"
        "  on_calendar: '*-*-* 04:00:00'\n"
        "  persistent: true\n"
        "  randomized_delay_seconds: 12\n",
        encoding="utf-8",
    )
    systemd = tmp_path / "systemd"
    monkeypatch.setattr(deploy_module, "CHECKOUT_DIR", checkout)
    monkeypatch.setattr(deploy_module, "SYSTEMD_DIR", systemd)
    deployer = Deployer(dry_run=False)
    deployer.generate_timer_dropins()
    content = (systemd / "homelab-service-backup@app-test.timer.d" / "schedule.conf").read_text(
        encoding="utf-8"
    )
    assert "OnCalendar=*-*-* 04:00:00" in content
    assert "RandomizedDelaySec=12" in content
