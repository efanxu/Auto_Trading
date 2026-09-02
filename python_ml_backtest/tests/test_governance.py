from __future__ import annotations

from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PYTHON_ROOT = REPOSITORY_ROOT / "python_ml_backtest"


def test_governance_and_public_entry_files_exist() -> None:
    required_files = [
        REPOSITORY_ROOT / "PROJECT_RULES.md",
        REPOSITORY_ROOT / "HANDOFF.md",
        PYTHON_ROOT / "MODEL_INTEGRATION_INDEX.md",
        PYTHON_ROOT / "configs" / "experiment.yaml",
        PYTHON_ROOT / "scripts" / "run.py",
    ]

    assert all(path.is_file() for path in required_files)
