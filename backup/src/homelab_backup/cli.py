from __future__ import annotations

import argparse
import json
from pathlib import Path

from homelab_backup.config import DEFAULT_CONFIG_DIR, list_services, load_service_config
from homelab_backup.exceptions import BackupError
from homelab_backup.logging_config import configure_logging
from homelab_backup.runner import BackupRunner
from homelab_backup.status import read_status


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="homelab-backup")
    parser.add_argument("--config-dir", type=Path, default=DEFAULT_CONFIG_DIR)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("list")

    validate = subparsers.add_parser("validate")
    validate.add_argument("service")

    inspect = subparsers.add_parser("inspect")
    inspect.add_argument("service")

    run = subparsers.add_parser("run")
    run.add_argument("--dry-run", action="store_true")
    run.add_argument("service")

    status = subparsers.add_parser("status")
    status.add_argument("service")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "list":
            print("\n".join(list_services(args.config_dir)))
            return 0

        config = load_service_config(args.service, args.config_dir)
        log_path = config.logging.file_path if config.logging.file_enabled else None
        logger = configure_logging(config.service_id, log_path)
        runner = BackupRunner(logger=logger)

        if args.command == "validate":
            print(f"{config.service_id}: valid")
            return 0
        if args.command == "inspect":
            print(json.dumps(runner.inspect(config), ensure_ascii=True, indent=2, sort_keys=True))
            return 0
        if args.command == "run":
            result = runner.run(config, dry_run=args.dry_run)
            print(json.dumps(result, ensure_ascii=True, indent=2, sort_keys=True))
            return 0
        if args.command == "status":
            print(
                json.dumps(
                    read_status(config.status.file_path),
                    ensure_ascii=True,
                    indent=2,
                    sort_keys=True,
                )
            )
            return 0
        parser.error(f"unknown command: {args.command}")
        return 2
    except BackupError as exc:
        logger = configure_logging(getattr(args, "service", None))
        logger.error(
            str(exc),
            extra={"event": "command_failed", "stage": exc.stage, "exit_code": exc.exit_code},
        )
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
