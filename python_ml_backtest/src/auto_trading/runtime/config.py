"""Load, validate, and resolve the public experiment configuration.

This module deliberately owns only configuration concerns.  It does not load
market data, construct labels, select thresholds, or instantiate models.
"""

from __future__ import annotations

from copy import deepcopy
from math import isfinite
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
    ("data", "interval"),
    ("data", "timezone"),
    ("target", "type"),
    ("target", "horizon_minutes"),
    ("target", "equality"),
    ("split", "method"),
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

    if isinstance(project["seed"], bool) or not isinstance(project["seed"], int):
        raise ConfigError(_source_prefix(source) + "project.seed must be an integer")
    if data["interval"] != "1m":
        raise ConfigError(_source_prefix(source) + "data.interval must be '1m' for the current baseline")
    if data["timezone"] != "UTC":
        raise ConfigError(_source_prefix(source) + "data.timezone must be 'UTC'")
    if target["type"] != "binary_direction":
        raise ConfigError(_source_prefix(source) + "target.type must be 'binary_direction'")
    if target["equality"] != "down":
        raise ConfigError(_source_prefix(source) + "target.equality must be 'down'")

    target_horizon = _positive_number(target["horizon_minutes"], "target.horizon_minutes")
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

    if split["method"] not in {"time_ordered", "walk_forward"}:
        raise ConfigError(
            _source_prefix(source)
            + "split.method must be 'time_ordered' or 'walk_forward'"
        )
    _positive_number(prediction["frequency_minutes"], "prediction.frequency_minutes")
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


__all__ = [
    "ConfigError",
    "EventPayout",
    "calculate_event_payout",
    "default_config_path",
    "dump_config",
    "load_config",
    "resolve_config",
]
