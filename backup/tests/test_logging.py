from __future__ import annotations

import json
import logging

from homelab_backup.logging_config import JsonFormatter


def test_json_log_structure():
    record = logging.LogRecord("x", logging.INFO, __file__, 1, "hello", (), None)
    record.event = "backup_started"
    record.service = "app-test"
    payload = json.loads(JsonFormatter().format(record))
    assert payload["component"] == "homelab-backup"
    assert payload["event"] == "backup_started"
    assert payload["service"] == "app-test"
