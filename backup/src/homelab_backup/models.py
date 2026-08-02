from __future__ import annotations

from enum import StrEnum
from pathlib import Path, PurePosixPath
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


def _path_text(value: Path) -> str:
    return value.as_posix().replace("\\", "/")


def _is_absolute(value: Path) -> bool:
    text = _path_text(value)
    return value.is_absolute() or text.startswith("/")


def _posix(value: Path) -> PurePosixPath:
    return PurePosixPath(_path_text(value))


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", validate_assignment=True)


class ConsistencyMode(StrEnum):
    NONE = "none"
    STOP_CONTAINER = "stop-container"
    DOCKER_EXEC = "docker-exec"
    COMMAND_HOOKS = "command-hooks"


class DockerConfig(StrictModel):
    enabled: bool = True
    compose_project: str | None = None
    compose_service: str | None = None
    container_name: str | None = None
    consistency_mode: ConsistencyMode = ConsistencyMode.STOP_CONTAINER
    stop_timeout_seconds: int = Field(default=30, ge=1)
    start_timeout_seconds: int = Field(default=60, ge=1)
    health_timeout_seconds: int = Field(default=120, ge=0)
    require_healthy: bool = False

    @model_validator(mode="after")
    def validate_identity(self) -> DockerConfig:
        if not self.enabled or self.container_name:
            return self
        if not self.compose_project or not self.compose_service:
            raise ValueError(
                "docker.compose_project and docker.compose_service are required "
                "without container_name"
            )
        return self


class SourceConfig(StrictModel):
    source: Path
    destination: Path = Path(".")
    required: bool = True

    @field_validator("source")
    @classmethod
    def source_must_be_absolute(cls, value: Path) -> Path:
        if not _is_absolute(value):
            raise ValueError("source path must be absolute")
        return value

    @field_validator("destination")
    @classmethod
    def destination_must_be_relative(cls, value: Path) -> Path:
        if _is_absolute(value):
            raise ValueError("source destination must be relative to backup destination")
        if any(part == ".." for part in value.parts):
            raise ValueError("source destination must not contain path traversal")
        return value


class BackupConfig(StrictModel):
    destination_root: Path
    destination_subdir: Path
    sources: list[SourceConfig]

    @field_validator("destination_root")
    @classmethod
    def destination_root_absolute(cls, value: Path) -> Path:
        if not _is_absolute(value):
            raise ValueError("backup.destination_root must be absolute")
        if _posix(value) == PurePosixPath("/"):
            raise ValueError("backup.destination_root must not be /")
        return value

    @field_validator("destination_subdir")
    @classmethod
    def destination_subdir_relative(cls, value: Path) -> Path:
        if _is_absolute(value):
            raise ValueError("backup.destination_subdir must be relative")
        if value in (Path("."), Path("")):
            raise ValueError("backup.destination_subdir must include a service-specific directory")
        if any(part == ".." for part in value.parts):
            raise ValueError("backup.destination_subdir must not contain path traversal")
        if len(value.parts) < 2:
            raise ValueError("backup.destination_subdir must not point at root only")
        return value

    @field_validator("sources")
    @classmethod
    def sources_not_empty(cls, value: list[SourceConfig]) -> list[SourceConfig]:
        if not value:
            raise ValueError("at least one source is required")
        return value


class RsyncConfig(StrictModel):
    archive: bool = True
    hard_links: bool = True
    acls: bool = True
    xattrs: bool = True
    numeric_ids: bool = True
    delete: bool = True
    delete_delay: bool = True
    inplace: bool = False
    excludes: list[str] = Field(default_factory=list)

    @field_validator("inplace")
    @classmethod
    def inplace_disabled(cls, value: bool) -> bool:
        if value:
            raise ValueError("rsync.inplace is intentionally unsupported")
        return value


class SafetyConfig(StrictModel):
    expected_mountpoint: Path
    require_mountpoint: bool = True
    minimum_free_space_mb: int = Field(default=1024, ge=0)
    allowed_destination_prefix: Path
    preserve_last_successful_copy: bool = True
    reject_symlink_destination: bool = True

    @field_validator("expected_mountpoint", "allowed_destination_prefix")
    @classmethod
    def safety_paths_absolute(cls, value: Path) -> Path:
        if not _is_absolute(value):
            raise ValueError("safety paths must be absolute")
        if _posix(value) == PurePosixPath("/"):
            raise ValueError("safety paths must not be /")
        return value


class LoggingConfig(StrictModel):
    format: Literal["json"] = "json"
    file_enabled: bool = True
    file_path: Path | None = None


class StatusConfig(StrictModel):
    file_path: Path

    @field_validator("file_path")
    @classmethod
    def status_path_absolute(cls, value: Path) -> Path:
        if not _is_absolute(value):
            raise ValueError("status.file_path must be absolute")
        return value


class ScheduleConfig(StrictModel):
    on_calendar: str = "*-*-* 03:20:00"
    persistent: bool = True
    randomized_delay_seconds: int = Field(default=0, ge=0)


class HookConfig(StrictModel):
    before: list[list[str]] = Field(default_factory=list)
    after: list[list[str]] = Field(default_factory=list)


class ServiceConfig(StrictModel):
    service_id: str
    enabled: bool = True
    docker: DockerConfig = Field(default_factory=DockerConfig)
    backup: BackupConfig
    rsync: RsyncConfig = Field(default_factory=RsyncConfig)
    safety: SafetyConfig
    logging: LoggingConfig = Field(default_factory=LoggingConfig)
    status: StatusConfig
    schedule: ScheduleConfig = Field(default_factory=ScheduleConfig)
    hooks: HookConfig = Field(default_factory=HookConfig)

    @field_validator("service_id")
    @classmethod
    def validate_service_id(cls, value: str) -> str:
        if not value or any(ch.isspace() for ch in value):
            raise ValueError("service_id must be non-empty and contain no whitespace")
        return value

    @model_validator(mode="after")
    def validate_destination_allowlist(self) -> ServiceConfig:
        destination = _posix(self.backup.destination_root / self.backup.destination_subdir)
        allowed = _posix(self.safety.allowed_destination_prefix)
        root = _posix(self.backup.destination_root)
        if destination == allowed:
            raise ValueError("backup destination must not be the allowed destination prefix")
        if allowed not in destination.parents:
            raise ValueError("backup destination must stay inside allowed prefix")
        if root != allowed and allowed not in root.parents:
            raise ValueError("backup.destination_root must be inside allowed prefix")
        if self.docker.consistency_mode in {
            ConsistencyMode.DOCKER_EXEC,
            ConsistencyMode.COMMAND_HOOKS,
        }:
            raise ValueError(
                f"consistency mode {self.docker.consistency_mode.value} is validated "
                "but not executable in v1"
            )
        return self

    @property
    def destination_path(self) -> Path:
        return self.backup.destination_root / self.backup.destination_subdir

    def public_dict(self) -> dict[str, Any]:
        data = self.model_dump(mode="json")
        data["destination_path"] = str(self.destination_path)
        return data
