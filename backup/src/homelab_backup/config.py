from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any

import yaml
from pydantic import ValidationError

from homelab_backup.exceptions import ConfigError
from homelab_backup.models import ServiceConfig

DEFAULT_CONFIG_DIR = Path("/etc/homelab-backup")


def _deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    result = deepcopy(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = deepcopy(value)
    return result


def read_yaml(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            loaded = yaml.safe_load(handle) or {}
    except FileNotFoundError as exc:
        raise ConfigError(f"config file not found: {path}") from exc
    except yaml.YAMLError as exc:
        raise ConfigError(f"invalid YAML in {path}: {exc}") from exc
    if not isinstance(loaded, dict):
        raise ConfigError(f"YAML document must be a mapping: {path}")
    return loaded


def load_service_config(service_id: str, config_dir: Path = DEFAULT_CONFIG_DIR) -> ServiceConfig:
    defaults_path = config_dir / "defaults.yaml"
    service_path = config_dir / "services" / f"{service_id}.yaml"
    defaults = read_yaml(defaults_path) if defaults_path.exists() else {}
    service = read_yaml(service_path)
    merged = _deep_merge(defaults, service)
    try:
        return ServiceConfig.model_validate(merged)
    except ValidationError as exc:
        raise ConfigError(str(exc)) from exc


def list_services(config_dir: Path = DEFAULT_CONFIG_DIR) -> list[str]:
    services_dir = config_dir / "services"
    if not services_dir.exists():
        return []
    return sorted(path.stem for path in services_dir.glob("*.yaml"))
