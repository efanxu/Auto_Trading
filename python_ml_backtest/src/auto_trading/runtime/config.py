"""Load, validate, and resolve the public experiment configuration.

This module deliberately owns only configuration concerns.  It does not load
market data, construct labels, select thresholds, or instantiate models.
"""

from __future__ import annotations

from copy import deepcopy
from datetime import date, datetime
from math import isclose, isfinite
from pathlib import Path
from typing import Any, Mapping

import yaml

from auto_trading.backtest.payout import (
    EventPayout,
    calculate_event_payout as _calculate_event_payout,
)


class ConfigError(ValueError):
    """Raised when the public experiment configuration is invalid."""


_REQUIRED_FIELDS: tuple[tuple[str, ...], ...] = (
    ("project", "seed"),
    ("data", "source"),
    ("data", "market"),
    ("data", "series"),
    ("data", "symbol"),
    ("data", "interval"),
    ("data", "timezone"),
    ("data", "start_date"),
    ("data", "end_date"),
    ("target", "type"),
    ("target", "horizon_minutes"),
    ("target", "entry_price"),
    ("target", "expiry_price"),
    ("split", "method"),
    ("split", "train_ratio"),
    ("split", "validation_ratio"),
    ("split", "test_ratio"),
    ("split", "purge_minutes"),
    ("prediction", "frequency_minutes"),
    ("calibration", "method"),
    ("signal", "long_probability_threshold"),
    ("signal", "short_probability_threshold"),
    ("signal", "cooldown_minutes"),
    ("signal", "rearm_probability_threshold"),
    ("event", "horizon_minutes"),
    ("event", "stake_usdt"),
    ("event", "winning_total_return_usdt"),
    ("features", "set"),
    ("features", "max_lag_bars"),
    ("features", "require_contiguous_history"),
    ("training", "early_stopping", "enabled"),
    ("training", "early_stopping", "internal_fraction"),
    ("training", "early_stopping", "purge_minutes"),
    ("training", "early_stopping", "stopping_rounds"),
    ("training", "early_stopping", "metric"),
)

_SIGNAL_FIELDS = {
    "long_probability_threshold",
    "short_probability_threshold",
    "rearm_probability_threshold",
    "cooldown_minutes",
}


def default_config_path() -> Path:
    """Return the checked-in public experiment configuration path."""

    workspace_root = Path(__file__).resolve().parents[3]
    return workspace_root / "configs" / "experiment.yaml"


def load_config(path: str | Path | None = None) -> dict[str, Any]:
    """Read and resolve a YAML experiment configuration.

    Args:
        path: YAML path.  When omitted, use ``configs/experiment.yaml`` in
            the Python workspace.

    Returns:
        A deep-copied mapping containing the public values and derived Event
        payout values.  The input YAML file is never modified.

    Raises:
        ConfigError: If the file cannot be read, parsed, or validated.
    """

    config_path = Path(path) if path is not None else default_config_path()
    try:
        with config_path.open("r", encoding="utf-8") as handle:
            loaded = yaml.safe_load(handle)
    except OSError as exc:
        raise ConfigError(f"Cannot read config '{config_path}': {exc}") from exc
    except yaml.YAMLError as exc:
        raise ConfigError(f"Cannot parse config '{config_path}': {exc}") from exc

    return resolve_config(loaded, source=config_path)


def resolve_config(
    config: Mapping[str, Any] | None,
    *,
    source: str | Path | None = None,
) -> dict[str, Any]:
    """Validate a loaded mapping and add resolved Event payout values."""

    if not isinstance(config, Mapping):
        raise ConfigError(_source_prefix(source) + "top-level YAML value must be a mapping")

    resolved = deepcopy(dict(config))
    _add_multires_defaults(resolved)
    _validate_required_fields(resolved, source=source)
    _validate_public_values(resolved, source=source)

    event = resolved["event"]
    payout = calculate_event_payout(
        event["stake_usdt"],
        event["winning_total_return_usdt"],
    )
    event.update(
        {
            "win_net_profit": payout.win_net_profit,
            "loss_net_profit": payout.loss_net_profit,
            "break_even_win_rate": payout.break_even_win_rate,
        }
    )
    return resolved


def calculate_event_payout(
    stake_usdt: Any,
    winning_total_return_usdt: Any,
) -> EventPayout:
    """Calculate payout through the shared backtest-layer implementation.

    The wrapper keeps configuration errors consistently typed as ``ConfigError``
    while leaving Event Contract math owned by ``auto_trading.backtest``.
    """

    try:
        return _calculate_event_payout(stake_usdt, winning_total_return_usdt)
    except ValueError as exc:
        raise ConfigError(str(exc)) from exc


def dump_config(config: Mapping[str, Any]) -> str:
    """Serialize a resolved configuration for stable human-readable output."""

    return yaml.safe_dump(
        dict(config),
        allow_unicode=True,
        sort_keys=False,
        default_flow_style=False,
    )


def _validate_required_fields(
    config: Mapping[str, Any],
    *,
    source: str | Path | None,
) -> None:
    for path in _REQUIRED_FIELDS:
        current: Any = config
        for key in path:
            if not isinstance(current, Mapping) or key not in current:
                joined = ".".join(path)
                raise ConfigError(_source_prefix(source) + f"missing required field: {joined}")
            current = current[key]


def _add_multires_defaults(config: dict[str, Any]) -> None:
    """Add B1 interval keys while keeping old B0 mappings loadable."""

    data = config.setdefault("data", {})
    if isinstance(data, dict):
        intervals = data.setdefault("intervals", {})
        if isinstance(intervals, dict):
            intervals.setdefault("fine", "5m")
            intervals.setdefault("coarse", data.get("interval", "30m"))

    features = config.setdefault("features", {})
    if isinstance(features, dict):
        features.setdefault("fine_interval", "5m")
        features.setdefault("coarse_interval", data.get("interval", "30m"))
        features.setdefault("fine_max_lookback_bars", 288)
        features.setdefault("coarse_max_lookback_bars", features.get("max_lag_bars", 48))


def _validate_public_values(
    config: Mapping[str, Any],
    *,
    source: str | Path | None,
) -> None:
    project = config["project"]
    data = config["data"]
    target = config["target"]
    split = config["split"]
    prediction = config["prediction"]
    calibration = config["calibration"]
    signal = config["signal"]
    event = config["event"]
    intervals = data["intervals"]

    if isinstance(project["seed"], bool) or not isinstance(project["seed"], int):
        raise ConfigError(_source_prefix(source) + "project.seed must be an integer")
    expected_data_fields = {
        "source": "binance_public_data",
        "market": "usd_m_futures",
        "series": "index_price_klines",
        "symbol": "BTCUSDT",
        "interval": "30m",
        "timezone": "UTC",
    }
    for field, expected in expected_data_fields.items():
        if data[field] != expected:
            raise ConfigError(
                _source_prefix(source)
                + f"data.{field} must be {expected!r} for the current B0 protocol"
            )
    if not isinstance(intervals, Mapping):
        raise ConfigError(_source_prefix(source) + "data.intervals must be a mapping")
    if intervals.get("fine") != "5m":
        raise ConfigError(_source_prefix(source) + "data.intervals.fine must be '5m'")
    if intervals.get("coarse") != "30m":
        raise ConfigError(_source_prefix(source) + "data.intervals.coarse must be '30m'")
    if target["type"] != "binary_direction":
        raise ConfigError(_source_prefix(source) + "target.type must be 'binary_direction'")
    if target["entry_price"] != "next_bar_open":
        raise ConfigError(_source_prefix(source) + "target.entry_price must be 'next_bar_open'")
    if target["expiry_price"] != "next_bar_close":
        raise ConfigError(_source_prefix(source) + "target.expiry_price must be 'next_bar_close'")

    target_horizon = _positive_number(target["horizon_minutes"], "target.horizon_minutes")
    if target_horizon != 30:
        raise ConfigError(_source_prefix(source) + "target.horizon_minutes must be 30 for the current B0 protocol")
    event_horizon = _positive_number(event["horizon_minutes"], "event.horizon_minutes")
    if event_horizon != target_horizon:
        raise ConfigError(
            _source_prefix(source)
            + "event.horizon_minutes must equal target.horizon_minutes"
        )

    purge = _non_negative_number(split["purge_minutes"], "split.purge_minutes")
    if purge < target_horizon:
        raise ConfigError(
            _source_prefix(source)
            + "split.purge_minutes must be >= target.horizon_minutes"
        )

    if split["method"] != "chronological":
        raise ConfigError(_source_prefix(source) + "split.method must be 'chronological'")
    ratios = {
        "train_ratio": _positive_number(split["train_ratio"], "split.train_ratio"),
        "validation_ratio": _positive_number(
            split["validation_ratio"], "split.validation_ratio"
        ),
        "test_ratio": _positive_number(split["test_ratio"], "split.test_ratio"),
    }
    if not isclose(sum(ratios.values()), 1.0, rel_tol=0, abs_tol=1e-12):
        raise ConfigError("split ratios must sum to 1.0")

    prediction_frequency = _positive_number(
        prediction["frequency_minutes"], "prediction.frequency_minutes"
    )
    if prediction_frequency != 30:
        raise ConfigError(
            _source_prefix(source)
            + "prediction.frequency_minutes must be 30 for the current B0 protocol"
        )
    if calibration["method"] not in {"none", "platt", "isotonic"}:
        raise ConfigError(
            _source_prefix(source)
            + "calibration.method must be 'none', 'platt', or 'isotonic'"
        )

    calculate_event_payout(
        event["stake_usdt"],
        event["winning_total_return_usdt"],
    )
    for field in _SIGNAL_FIELDS:
        value = signal[field]
        if value is None:
            continue
        if field == "cooldown_minutes":
            _non_negative_number(value, f"signal.{field}")
        else:
            threshold = _finite_number(value, f"signal.{field}")
            if not 0 <= threshold <= 1:
                raise ConfigError(f"signal.{field} must be between 0 and 1 or null")

    start_date = _config_date(data["start_date"], "data.start_date")
    end_date = _config_date(data["end_date"], "data.end_date")
    if start_date >= end_date:
        raise ConfigError(_source_prefix(source) + "data.start_date must be before data.end_date")

    features = config["features"]
    training = config["training"]

    if features["set"] not in {"price_ohlc_v1", "price_multires_v1"}:
        raise ConfigError(
            _source_prefix(source)
            + "features.set must be 'price_ohlc_v1' or 'price_multires_v1'"
        )
    max_lag = features["max_lag_bars"]
    if isinstance(max_lag, bool) or not isinstance(max_lag, int) or max_lag != 48:
        raise ConfigError(_source_prefix(source) + "features.max_lag_bars must be integer 48")
    if not isinstance(features["require_contiguous_history"], bool):
        raise ConfigError(_source_prefix(source) + "features.require_contiguous_history must be boolean")
    if features["set"] == "price_multires_v1":
        if features["fine_interval"] != "5m":
            raise ConfigError(_source_prefix(source) + "features.fine_interval must be '5m'")
        if features["coarse_interval"] != "30m":
            raise ConfigError(_source_prefix(source) + "features.coarse_interval must be '30m'")
        if features["fine_max_lookback_bars"] != 288:
            raise ConfigError(
                _source_prefix(source) + "features.fine_max_lookback_bars must be integer 288"
            )
        if features["coarse_max_lookback_bars"] != 48:
            raise ConfigError(
                _source_prefix(source) + "features.coarse_max_lookback_bars must be integer 48"
            )

    if not isinstance(training.get("early_stopping"), Mapping):
        raise ConfigError(_source_prefix(source) + "training.early_stopping must be a mapping")
    es = training["early_stopping"]
    if not isinstance(es["enabled"], bool):
        raise ConfigError(_source_prefix(source) + "training.early_stopping.enabled must be boolean")
    internal_fraction = _positive_number(es["internal_fraction"], "training.early_stopping.internal_fraction")
    if not 0 < internal_fraction < 1:
        raise ConfigError(_source_prefix(source) + "training.early_stopping.internal_fraction must be between 0 and 1")
    _non_negative_number(es["purge_minutes"], "training.early_stopping.purge_minutes")
    stopping_rounds = es["stopping_rounds"]
    if isinstance(stopping_rounds, bool) or not isinstance(stopping_rounds, int) or stopping_rounds <= 0:
        raise ConfigError(_source_prefix(source) + "training.early_stopping.stopping_rounds must be a positive integer")
    if es["metric"] != "binary_logloss":
        raise ConfigError(_source_prefix(source) + "training.early_stopping.metric must be 'binary_logloss'")


def _finite_number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConfigError(f"{field} must be a finite number")
    converted = float(value)
    if not isfinite(converted):
        raise ConfigError(f"{field} must be a finite number")
    return converted


def _positive_number(value: Any, field: str) -> float:
    converted = _finite_number(value, field)
    if converted <= 0:
        raise ConfigError(f"{field} must be > 0")
    return converted


def _non_negative_number(value: Any, field: str) -> float:
    converted = _finite_number(value, field)
    if converted < 0:
        raise ConfigError(f"{field} must be >= 0")
    return converted


def _source_prefix(source: str | Path | None) -> str:
    return f"{source}: " if source is not None else ""


def _config_date(value: Any, field: str) -> date:
    """Resolve a YAML date/string without changing the public config shape."""

    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    if isinstance(value, str):
        try:
            return date.fromisoformat(value)
        except ValueError as exc:
            raise ConfigError(f"{field} must be an ISO date (YYYY-MM-DD)") from exc
    raise ConfigError(f"{field} must be an ISO date (YYYY-MM-DD)")


__all__ = [
    "ConfigError",
    "EventPayout",
    "calculate_event_payout",
    "default_config_path",
    "dump_config",
    "load_config",
    "resolve_config",
]
