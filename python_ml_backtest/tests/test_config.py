from __future__ import annotations

from pathlib import Path

import pytest

from auto_trading.runtime.config import ConfigError, load_config, resolve_config


CONFIG_PATH = Path(__file__).resolve().parents[1] / "configs" / "experiment.yaml"


def test_experiment_config_resolves_public_baseline() -> None:
    config = load_config(CONFIG_PATH)

    assert config["data"]["source"] == "binance_public_data"
    assert config["data"]["market"] == "usd_m_futures"
    assert config["data"]["series"] == "index_price_klines"
    assert config["data"]["symbol"] == "BTCUSDT"
    assert config["data"]["interval"] == "30m"
    assert config["data"]["timezone"] == "UTC"
    assert str(config["data"]["start_date"]) == "2020-01-01"
    assert str(config["data"]["end_date"]) == "2026-08-31"
    assert config["target"]["horizon_minutes"] == 30
    assert config["target"]["entry_price"] == "next_bar_open"
    assert config["target"]["expiry_price"] == "next_bar_close"
    assert config["prediction"]["frequency_minutes"] == 30
    assert config["split"]["method"] == "chronological"
    assert config["split"]["train_ratio"] == pytest.approx(0.8)
    assert config["split"]["purge_minutes"] >= config["target"]["horizon_minutes"]
    assert config["signal"]["long_probability_threshold"] is None
    assert config["event"]["stake_usdt"] == pytest.approx(10.0)
    assert config["event"]["winning_total_return_usdt"] == pytest.approx(18.5)
    assert config["event"]["win_net_profit"] == pytest.approx(8.5)
    assert config["event"]["loss_net_profit"] == pytest.approx(-10.0)
    assert config["event"]["break_even_win_rate"] == pytest.approx(10 / 18.5)


def test_config_rejects_purge_shorter_than_horizon() -> None:
    config = load_config(CONFIG_PATH)
    config["split"]["purge_minutes"] = 29

    with pytest.raises(ConfigError, match="purge_minutes"):
        resolve_config(config)


@pytest.mark.parametrize(
    ("path", "value", "message"),
    [
        (("split", "train_ratio"), 0, "train_ratio"),
        (("split", "validation_ratio"), 0, "validation_ratio"),
        (("split", "test_ratio"), 0, "test_ratio"),
        (("split", "method"), "walk_forward", "chronological"),
        (("data", "interval"), "1m", "interval"),
    ],
)
def test_config_rejects_non_b0_public_values(path: tuple[str, str], value: object, message: str) -> None:
    config = load_config(CONFIG_PATH)
    config[path[0]][path[1]] = value

    with pytest.raises(ConfigError, match=message):
        resolve_config(config)


def test_config_rejects_ratio_sum_and_invalid_date_order() -> None:
    config = load_config(CONFIG_PATH)
    config["split"]["test_ratio"] = 0.2
    with pytest.raises(ConfigError, match="sum to 1.0"):
        resolve_config(config)

    config = load_config(CONFIG_PATH)
    config["data"]["start_date"] = config["data"]["end_date"]
    with pytest.raises(ConfigError, match="start_date"):
        resolve_config(config)
