from __future__ import annotations

import os
from pathlib import Path
from types import TracebackType
from typing import TextIO

from homelab_backup.exceptions import LockAlreadyHeld
from homelab_backup.utils import ensure_dir

if os.name == "posix":
    import fcntl
else:
    fcntl = None  # type: ignore[assignment]


class FileLock:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._handle: TextIO | None = None

    def acquire(self) -> None:
        ensure_dir(self.path.parent, 0o755)
        handle = self.path.open("a+", encoding="utf-8")
        if fcntl is None:
            self._handle = handle
            return
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)  # type: ignore[attr-defined]
        except BlockingIOError as exc:
            handle.close()
            raise LockAlreadyHeld(f"backup already running for lock {self.path}") from exc
        handle.seek(0)
        handle.truncate()
        handle.write(f"{os.getpid()}\n")
        handle.flush()
        os.fsync(handle.fileno())
        self._handle = handle

    def release(self) -> None:
        handle = self._handle
        if handle is None:
            return
        if fcntl is not None:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)  # type: ignore[attr-defined]
        handle.close()
        self._handle = None

    def __enter__(self) -> FileLock:
        self.acquire()
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.release()
