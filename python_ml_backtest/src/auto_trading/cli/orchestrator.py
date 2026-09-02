"""Single public CLI for the Python ML Event Contract workspace."""

from __future__ import annotations

import argparse
from math import isclose
from pathlib import Path
from typing import Sequence

from auto_trading.runtime.config import (
    ConfigError,
    calculate_event_payout,
    default_config_path,
    dump_config,
    load_config,
)


def build_parser() -> argparse.ArgumentParser:
    """Build the public command parser."""

    parser = argparse.ArgumentParser(
        prog="run.py",
        description="Auto_Trading Python ML Event Contract research commands.",
    )
    parser.add_argument(
        "--config",
        dest="global_config",
        type=Path,
        default=None,
        help="Path to experiment YAML (default: configs/experiment.yaml).",
    )
    parser.add_argument("--version", action="version", version="0.1.0")

    commands = parser.add_subparsers(dest="command", metavar="COMMAND")
    for name, help_text in (
        ("show-config", "show the resolved public experiment configuration"),
        ("check", "run current configuration and workspace checks"),
    ):
        command = commands.add_parser(name, help=help_text)
        command.add_argument(
            "--config",
            dest="command_config",
            type=Path,
            default=None,
            help="Path to experiment YAML (overrides the global option).",
        )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run one public CLI command and return its process exit code."""

    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 0

    config_path = args.command_config or args.global_config or default_config_path()
    try:
        config = load_config(config_path)
    except ConfigError as exc:
        print(f"CONFIG = FAIL: {exc}")
        return 2

    if args.command == "show-config":
        print(dump_config(config), end="")
        return 0
    if args.command == "check":
        return _run_check(config, config_path)

    parser.error(f"unsupported command: {args.command}")
    return 2


def _run_check(config: dict, config_path: Path) -> int:
    workspace_root = Path(__file__).resolve().parents[3]
    repository_root = workspace_root.parent
    checks: list[tuple[str, bool, str]] = []

    checks.append(("CONFIG_READABLE", config_path.is_file(), str(config_path)))

    required_directories = [
        workspace_root / "configs",
        workspace_root / "configs" / "models",
        workspace_root / "scripts",
        workspace_root / "src" / "auto_trading",
        workspace_root / "tests",
        workspace_root / "data",
        workspace_root / "data" / "raw",
        workspace_root / "data" / "processed",
        workspace_root / "results",
    ]
    missing_directories = [
        str(path.relative_to(repository_root))
        for path in required_directories
        if not path.is_dir()
    ]
    checks.append(
        (
            "REQUIRED_DIRECTORIES",
            not missing_directories,
            "present" if not missing_directories else "missing: " + ", ".join(missing_directories),
        )
    )

    public_configuration_ok = (
        config["data"]["interval"] == "1m"
        and config["data"]["timezone"] == "UTC"
        and config["target"]["horizon_minutes"] == config["event"]["horizon_minutes"]
        and config["split"]["purge_minutes"] >= config["target"]["horizon_minutes"]
    )
    checks.append(
        (
            "PUBLIC_CONFIGURATION",
            public_configuration_ok,
            "consistent" if public_configuration_ok else "inconsistent",
        )
    )

    required_paths = [
        repository_root / "PROJECT_RULES.md",
        repository_root / "HANDOFF.md",
        workspace_root / "MODEL_INTEGRATION_INDEX.md",
        workspace_root / "configs" / "experiment.yaml",
        workspace_root / "scripts" / "run.py",
        workspace_root / "src" / "auto_trading" / "runtime" / "config.py",
        workspace_root / "src" / "auto_trading" / "models" / "base.py",
        workspace_root / "src" / "auto_trading" / "models" / "loader.py",
    ]
    missing_paths = [
        str(path.relative_to(repository_root)) for path in required_paths if not path.is_file()
    ]
    checks.append(
        (
            "MODEL_INTEGRATION_PATHS",
            not missing_paths,
            "present" if not missing_paths else "missing: " + ", ".join(missing_paths),
        )
    )

    event = config["event"]
    payout = calculate_event_payout(
        event["stake_usdt"],
        event["winning_total_return_usdt"],
    )
    payout_ok = (
        isclose(event["win_net_profit"], payout.win_net_profit, rel_tol=0, abs_tol=1e-12)
        and isclose(event["loss_net_profit"], payout.loss_net_profit, rel_tol=0, abs_tol=1e-12)
        and isclose(
            event["break_even_win_rate"],
            payout.break_even_win_rate,
            rel_tol=0,
            abs_tol=1e-12,
        )
    )
    checks.append(("EVENT_PAYOUT_MATH", payout_ok, "resolved" if payout_ok else "incorrect"))

    for name, passed, detail in checks:
        print(f"{name} = {'PASS' if passed else 'FAIL'} ({detail})")

    data_configured = _data_is_configured(workspace_root)
    print(f"DATA = {'CONFIGURED' if data_configured else 'NOT_CONFIGURED'}")

    all_passed = all(passed for _, passed, _ in checks) and payout_ok
    print(f"CHECK = {'PASS' if all_passed else 'FAIL'}")
    return 0 if all_passed else 1


def _data_is_configured(workspace_root: Path) -> bool:
    """Report whether raw or processed contains a non-placeholder file."""

    for directory_name in ("raw", "processed"):
        directory = workspace_root / "data" / directory_name
        if not directory.is_dir():
            continue
        if any(
            path.is_file() and path.name != ".gitkeep"
            for path in directory.rglob("*")
        ):
            return True
    return False


__all__ = ["build_parser", "main"]
