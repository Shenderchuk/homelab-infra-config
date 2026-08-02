from __future__ import annotations

import argparse
import json
from pathlib import Path

from homelab_backup.deploy import Deployer
from homelab_backup.exceptions import BackupError


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="homelab-backup-deploy")
    parser.add_argument("--repo-root", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--enable-service-timers", action="store_true")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("install", "update", "rollback", "status"):
        subparsers.add_parser(command)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    deployer = Deployer(repo_root=args.repo_root, dry_run=args.dry_run)
    try:
        if args.command in {"install", "update"}:
            report = deployer.install(enable_timers=args.enable_service_timers)
        elif args.command == "rollback":
            report = deployer.rollback()
        else:
            report = deployer.status()
        print(json.dumps(report.__dict__, indent=2, sort_keys=True))
        return 0
    except BackupError as exc:
        print(json.dumps({"status": "failure", "stage": exc.stage, "message": str(exc)}, indent=2))
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
