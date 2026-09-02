from __future__ import annotations

import subprocess
import sys
from pathlib import Path


WORKSPACE_ROOT = Path(__file__).resolve().parents[1]
RUNNER = WORKSPACE_ROOT / "scripts" / "run.py"


def run_cli(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(RUNNER), *arguments],
        cwd=WORKSPACE_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def test_cli_help_succeeds() -> None:
    result = run_cli("--help")

    assert result.returncode == 0
    assert "show-config" in result.stdout
    assert "check" in result.stdout
    assert "data-download" in result.stdout
    assert "data-prepare" in result.stdout
    assert "dataset-build" in result.stdout
    assert "data-check" in result.stdout


def test_cli_show_config_succeeds() -> None:
    result = run_cli("show-config")

    assert result.returncode == 0
    assert "interval: 30m" in result.stdout
    assert "timezone: UTC" in result.stdout
    assert "horizon_minutes: 30" in result.stdout
    assert "frequency_minutes: 30" in result.stdout
    assert "break_even_win_rate:" in result.stdout


def test_cli_check_succeeds_before_or_after_data_setup() -> None:
    result = run_cli("check")

    assert result.returncode == 0
    assert "EVENT_PAYOUT_MATH = PASS" in result.stdout
    assert "CONFIG_CHECK = PASS" in result.stdout
    assert "CHECK = PASS" in result.stdout
