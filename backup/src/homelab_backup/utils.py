from __future__ import annotations

import os
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from shutil import which


@dataclass(frozen=True)
class CommandResult:
    args: list[str]
    returncode: int
    stdout: str
    stderr: str


class CommandRunner:
    """Small injectable wrapper around subprocess without shell execution."""

    def run(
        self,
        args: Sequence[str | os.PathLike[str]],
        *,
        check: bool = False,
        env: Mapping[str, str] | None = None,
        cwd: Path | None = None,
        timeout: int | None = None,
    ) -> CommandResult:
        str_args = [os.fspath(arg) for arg in args]
        completed = subprocess.run(
            str_args,
            check=False,
            capture_output=True,
            text=True,
            env=dict(env) if env is not None else None,
            cwd=cwd,
            timeout=timeout,
        )
        result = CommandResult(
            args=str_args,
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
        )
        if check and result.returncode != 0:
            raise subprocess.CalledProcessError(
                result.returncode,
                result.args,
                output=result.stdout,
                stderr=result.stderr,
            )
        return result


def require_binary(name: str) -> str:
    path = which(name)
    if not path:
        raise FileNotFoundError(f"required binary not found: {name}")
    return path


def ensure_dir(path: Path, mode: int = 0o755) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, mode)


def redact(value: str, max_len: int = 4000) -> str:
    if len(value) <= max_len:
        return value
    return value[:max_len] + "...<truncated>"
