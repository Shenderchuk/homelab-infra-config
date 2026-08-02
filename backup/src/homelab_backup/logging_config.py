from __future__ import annotations

import json
import logging
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from homelab_backup.utils import ensure_dir


def _now_iso() -> str:
    try:
        now = datetime.now(ZoneInfo("Europe/Kyiv"))
    except ZoneInfoNotFoundError:
        now = datetime.now().astimezone()
    return now.isoformat(timespec="seconds")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": _now_iso(),
            "level": record.levelname,
            "component": "homelab-backup",
            "message": record.getMessage(),
        }
        reserved = {
            "args",
            "asctime",
            "created",
            "exc_info",
            "exc_text",
            "filename",
            "funcName",
            "levelname",
            "levelno",
            "lineno",
            "module",
            "msecs",
            "message",
            "msg",
            "name",
            "pathname",
            "process",
            "processName",
            "relativeCreated",
            "stack_info",
            "thread",
            "threadName",
        }
        for key, value in record.__dict__.items():
            if not key.startswith("_") and key not in reserved:
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=True, sort_keys=True)


def configure_logging(
    service_id: str | None = None,
    file_path: Path | None = None,
) -> logging.Logger | logging.LoggerAdapter[Any]:
    logger = logging.getLogger("homelab_backup")
    logger.handlers.clear()
    logger.setLevel(logging.INFO)
    logger.propagate = False

    formatter = JsonFormatter()
    stream = logging.StreamHandler(sys.stdout)
    stream.setFormatter(formatter)
    logger.addHandler(stream)

    if file_path is not None:
        ensure_dir(file_path.parent, 0o755)
        file_handler = logging.FileHandler(file_path, encoding="utf-8")
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)

    if service_id:
        return logging.LoggerAdapter(logger, {"service": service_id})
    return logger
