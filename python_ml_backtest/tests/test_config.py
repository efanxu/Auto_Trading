from __future__ import annotations

from pathlib import Path

import pytest

from auto_trading.runtime.config import ConfigError, load_config, resolve_config


CONFIG_PATH = Path(__file__).resolve().parents[1] / "configs" / "experiment.yaml"


def test_experiment_config_resolves_public_baseline() -> None:
    config = load_config(CONFIG_PATH)

    assert config["data"]["interval"] == "1m"
    assert config["data"]["timezone"] == "UTC"
    assert config["target"]["horizon_minutes"] == 30
    assert config["split"]["purge_minutes"] >= config["target"]["horizon_minutes"]
    assert config["signal"]["long_probability_threshold"] is None
    assert config["event"]["win_net_profit"] == pytest.approx(4.25)


def test_config_rejects_purge_shorter_than_horizon() -> None:
    config = load_config(CONFIG_PATH)
    config["split"]["purge_minutes"] = 29

    with pytest.raises(ConfigError, match="purge_minutes"):
        resolve_config(config)
