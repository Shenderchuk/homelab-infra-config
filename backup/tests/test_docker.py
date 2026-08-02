from __future__ import annotations

import json

import pytest

from homelab_backup.docker import DockerClient
from homelab_backup.exceptions import DockerError
from homelab_backup.models import DockerConfig
from homelab_backup.utils import CommandResult


class FakeRunner:
    def __init__(self, results):
        self.results = list(results)
        self.calls = []

    def run(self, args, **kwargs):
        self.calls.append(list(args))
        return self.results.pop(0)


def test_find_container_by_compose_labels():
    runner = FakeRunner([CommandResult([], 0, "abc\n", "")])
    container = DockerClient(runner).find_container(
        DockerConfig(compose_project="navidrome", compose_service="navidrome")
    )
    assert container == "abc"
    assert "label=com.docker.compose.project=navidrome" in runner.calls[0]


def test_find_container_ambiguous():
    runner = FakeRunner([CommandResult([], 0, "a\nb\n", "")])
    with pytest.raises(DockerError):
        DockerClient(runner).find_container(
            DockerConfig(compose_project="navidrome", compose_service="navidrome")
        )


def test_inspect_container_state():
    output = json.dumps(
        [
            {
                "Id": "abc",
                "Name": "/navidrome-navidrome-1",
                "State": {"Running": True, "Health": {"Status": "unhealthy"}},
            }
        ]
    )
    state = DockerClient(FakeRunner([CommandResult([], 0, output, "")])).inspect("abc")
    assert state.name == "navidrome-navidrome-1"
    assert state.running is True
    assert state.health == "unhealthy"
