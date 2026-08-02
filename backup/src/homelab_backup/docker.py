from __future__ import annotations

import json
import time
from dataclasses import dataclass

from homelab_backup.exceptions import DockerError
from homelab_backup.models import DockerConfig
from homelab_backup.utils import CommandRunner


@dataclass(frozen=True)
class ContainerState:
    container_id: str
    name: str
    running: bool
    health: str | None


class DockerClient:
    def __init__(self, runner: CommandRunner | None = None) -> None:
        self.runner = runner or CommandRunner()

    def check_daemon(self) -> None:
        result = self.runner.run(["docker", "info"])
        if result.returncode != 0:
            raise DockerError("Docker daemon is not available")

    def find_container(self, config: DockerConfig) -> str:
        if config.container_name:
            result = self.runner.run(
                ["docker", "ps", "-aq", "--filter", f"name=^{config.container_name}$"]
            )
        else:
            result = self.runner.run(
                [
                    "docker",
                    "ps",
                    "-aq",
                    "--filter",
                    f"label=com.docker.compose.project={config.compose_project}",
                    "--filter",
                    f"label=com.docker.compose.service={config.compose_service}",
                ]
            )
        if result.returncode != 0:
            raise DockerError("failed to query Docker containers")
        ids = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if not ids:
            raise DockerError("container not found")
        if len(ids) > 1:
            raise DockerError(f"container identity is ambiguous: {', '.join(ids)}")
        return ids[0]

    def inspect(self, container_id: str) -> ContainerState:
        result = self.runner.run(["docker", "inspect", container_id])
        if result.returncode != 0:
            raise DockerError(f"failed to inspect container {container_id}")
        try:
            data = json.loads(result.stdout)[0]
        except (json.JSONDecodeError, IndexError, KeyError) as exc:
            raise DockerError(f"invalid docker inspect output for {container_id}") from exc
        state = data.get("State", {})
        health = (
            state.get("Health", {}).get("Status") if isinstance(state.get("Health"), dict) else None
        )
        return ContainerState(
            container_id=data["Id"],
            name=str(data["Name"]).lstrip("/"),
            running=bool(state.get("Running")),
            health=health,
        )

    def stop(self, container_id: str, timeout_seconds: int) -> None:
        result = self.runner.run(["docker", "stop", "--time", str(timeout_seconds), container_id])
        if result.returncode != 0:
            raise DockerError(f"failed to stop container {container_id}")

    def start(self, container_id: str) -> None:
        result = self.runner.run(["docker", "start", container_id])
        if result.returncode != 0:
            raise DockerError(f"failed to start container {container_id}")

    def wait_running_or_healthy(
        self,
        container_id: str,
        *,
        timeout_seconds: int,
        require_healthy: bool,
    ) -> ContainerState:
        deadline = time.monotonic() + timeout_seconds
        last = self.inspect(container_id)
        while True:
            last = self.inspect(container_id)
            if not last.running:
                pass
            elif require_healthy:
                if last.health == "healthy":
                    return last
            else:
                return last
            if time.monotonic() >= deadline:
                raise DockerError(
                    "container did not reach required state; "
                    f"running={last.running} health={last.health}"
                )
            time.sleep(2)
