"""Causal next-bar Event label construction for the B0 protocol."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import pandas as pd

from auto_trading.data.schema import SchemaError, validate_canonical_schema


EVENT_COLUMNS: tuple[str, ...] = (
    "sample_id",
    "prediction_time",
    "event_entry_time",
    "event_entry_price",
    "event_expiry_time",
    "event_expiry_price",
    "target_direction",
    "target_up",
    "label_valid",
    "invalid_reason",
)


class LabelContractError(ValueError):
    """Raised when bars or Event labels violate the causal contract."""


@dataclass(frozen=True)
class EventLabelResult:
    """Candidates, valid samples, and counts produced by the label builder."""

    candidates: pd.DataFrame
    samples: pd.DataFrame
    report: dict[str, Any]


def build_event_candidates(
    bars: pd.DataFrame,
    *,
    interval_minutes: int = 30,
) -> pd.DataFrame:
    """Build one candidate per completed bar using only its immediate next bar.

    The final bar and a bar immediately before a real gap are retained as
    invalid candidates with ``invalid_reason=missing_next_bar``.  They are
    useful for audit counts but are excluded from the formal sample dataset.
    """

    _validate_bars_for_labels(bars, interval_minutes)
    rows: list[dict[str, Any]] = []
    expected_delta = pd.Timedelta(minutes=interval_minutes)

    for index in range(len(bars)):
        current = bars.iloc[index]
        prediction_time = current["close_time"]
        sample_id = _sample_id(prediction_time)
        row: dict[str, Any] = {
            "sample_id": sample_id,
            "prediction_time": prediction_time,
            "event_entry_time": pd.NaT,
            "event_entry_price": None,
            "event_expiry_time": pd.NaT,
            "event_expiry_price": None,
            "target_direction": pd.NA,
            "target_up": pd.NA,
            "label_valid": False,
            "invalid_reason": "missing_next_bar",
        }
        if index + 1 >= len(bars):
            rows.append(row)
            continue

        next_bar = bars.iloc[index + 1]
        expected_next_open = current["open_time"] + expected_delta
        if next_bar["open_time"] != expected_next_open:
            rows.append(row)
            continue

        entry_price = float(next_bar["open"])
        expiry_price = float(next_bar["close"])
        if expiry_price > entry_price:
            direction = 1
            target_up: int | None = 1
            label_valid = True
        elif expiry_price < entry_price:
            direction = -1
            target_up = 0
            label_valid = True
        else:
            direction = 0
            target_up = None
            label_valid = False

        row.update(
            {
                "event_entry_time": next_bar["open_time"],
                "event_entry_price": entry_price,
                "event_expiry_time": next_bar["close_time"],
                "event_expiry_price": expiry_price,
                "target_direction": direction,
                "target_up": target_up,
                "label_valid": label_valid,
                "invalid_reason": None,
            }
        )
        rows.append(row)

    candidates = pd.DataFrame(rows, columns=list(EVENT_COLUMNS))
    return _normalise_event_dtypes(candidates)


def build_event_labels(
    bars: pd.DataFrame,
    *,
    interval_minutes: int = 30,
) -> pd.DataFrame:
    """Return all Event candidates, including auditable invalid candidates."""

    return build_event_candidates(bars, interval_minutes=interval_minutes)


def build_valid_event_samples(
    bars: pd.DataFrame,
    *,
    interval_minutes: int = 30,
) -> pd.DataFrame:
    """Return only candidates with a valid immediate next-bar relationship."""

    candidates = build_event_candidates(bars, interval_minutes=interval_minutes)
    return candidates.loc[candidates["event_entry_time"].notna()].reset_index(drop=True)


def build_event_dataset(
    bars: pd.DataFrame,
    *,
    interval_minutes: int = 30,
) -> EventLabelResult:
    """Build candidates, filter formal samples, and return audit counts."""

    candidates = build_event_candidates(bars, interval_minutes=interval_minutes)
    samples = candidates.loc[candidates["event_entry_time"].notna()].reset_index(drop=True)
    valid_events = int(len(samples))
    invalid_events = int(len(candidates) - valid_events)
    flat_events = int((samples["target_direction"] == 0).sum())
    report = {
        "total_candidate_events": int(len(candidates)),
        "valid_events": valid_events,
        "invalid_events": invalid_events,
        "flat_events": flat_events,
        "invalid_reason_counts": {
            str(key): int(value)
            for key, value in candidates["invalid_reason"].dropna().value_counts().items()
        },
        "invalid_candidates": [
            {
                "sample_id": str(row["sample_id"]),
                "prediction_time": _timestamp_to_iso(row["prediction_time"]),
                "invalid_reason": str(row["invalid_reason"]),
            }
            for _, row in candidates.loc[candidates["invalid_reason"].notna()].iterrows()
        ],
    }
    return EventLabelResult(candidates=candidates, samples=samples, report=report)


def run_label_causality_check(
    bars: pd.DataFrame,
    samples: pd.DataFrame,
    *,
    interval_minutes: int = 30,
) -> dict[str, Any]:
    """Verify persisted samples against a fresh causal next-bar derivation."""

    errors: list[str] = []
    try:
        expected = build_valid_event_samples(bars, interval_minutes=interval_minutes)
    except (LabelContractError, SchemaError) as exc:
        return {"passed": False, "errors": [str(exc)], "checked_rows": 0}

    required_columns = [column for column in EVENT_COLUMNS if column != "invalid_reason"]
    missing = [column for column in required_columns if column not in samples.columns]
    if missing:
        return {
            "passed": False,
            "errors": ["sample data missing columns: " + ", ".join(missing)],
            "checked_rows": 0,
        }

    expected_ids = set(expected["sample_id"])
    actual_ids = set(samples["sample_id"])
    unexpected_ids = actual_ids - expected_ids
    if unexpected_ids:
        errors.append(
            f"sample_id set contains {len(unexpected_ids)} rows that are not "
            "valid next-bar candidates"
        )
    if samples["sample_id"].duplicated().any():
        errors.append("sample_id must be unique")

    expected_subset = expected[expected["sample_id"].isin(actual_ids)]
    joined = samples.merge(
        expected_subset,
        on="sample_id",
        how="left",
        suffixes=("_actual", "_expected"),
        validate="many_to_one",
    )
    comparable_columns = (
        "prediction_time",
        "event_entry_time",
        "event_expiry_time",
        "target_direction",
        "label_valid",
        "event_entry_price",
        "event_expiry_price",
    )
    for column in comparable_columns:
        actual_values = joined[f"{column}_actual"]
        expected_values = joined[f"{column}_expected"]
        mismatches = (actual_values != expected_values).fillna(True)
        if bool(mismatches.any()):
            for sample_id in joined.loc[mismatches, "sample_id"].head(10):
                errors.append(f"{sample_id}: {column} does not match causal next-bar value")

    actual_target_up = joined["target_up_actual"]
    expected_target_up = joined["target_up_expected"]
    target_up_matches = (
        (actual_target_up.isna() & expected_target_up.isna())
        | (actual_target_up == expected_target_up).fillna(False)
    )
    if not bool(target_up_matches.all()):
        for sample_id in joined.loc[~target_up_matches, "sample_id"].head(10):
            errors.append(f"{sample_id}: target_up does not match direction contract")

    if "invalid_reason" in samples.columns:
        invalid_reason = joined["invalid_reason_actual"]
        if bool(invalid_reason.notna().any()):
            errors.append("formal samples must not have invalid_reason")

    return {
        "passed": not errors,
        "errors": list(dict.fromkeys(errors)),
        "checked_rows": int(len(samples)),
        "valid_candidate_rows": int(len(expected)),
    }


def _validate_bars_for_labels(bars: pd.DataFrame, interval_minutes: int) -> None:
    if interval_minutes <= 0:
        raise ValueError("interval_minutes must be > 0")
    try:
        validate_canonical_schema(bars)
    except SchemaError as exc:
        raise LabelContractError(str(exc)) from exc
    if bars["open_time"].isna().any() or bars["close_time"].isna().any():
        raise LabelContractError("bars cannot contain null timestamps")
    if not bars["open_time"].is_monotonic_increasing or bars["open_time"].duplicated().any():
        raise LabelContractError("bars must be sorted by unique open_time")


def _normalise_event_dtypes(frame: pd.DataFrame) -> pd.DataFrame:
    result = frame.copy()
    result["prediction_time"] = pd.to_datetime(result["prediction_time"], utc=True)
    result["event_entry_time"] = pd.to_datetime(result["event_entry_time"], utc=True)
    result["event_expiry_time"] = pd.to_datetime(result["event_expiry_time"], utc=True)
    result["event_entry_price"] = pd.to_numeric(result["event_entry_price"], errors="coerce").astype(
        "float64"
    )
    result["event_expiry_price"] = pd.to_numeric(
        result["event_expiry_price"], errors="coerce"
    ).astype("float64")
    result["target_direction"] = pd.array(result["target_direction"], dtype="Int8")
    result["target_up"] = pd.array(result["target_up"], dtype="Int8")
    result["label_valid"] = result["label_valid"].astype("bool")
    result["sample_id"] = result["sample_id"].astype("string")
    result["invalid_reason"] = result["invalid_reason"].astype("string")
    return result.loc[:, list(EVENT_COLUMNS)]


def _sample_id(prediction_time: Any) -> str:
    timestamp = pd.Timestamp(prediction_time)
    if timestamp.tzinfo is not None:
        timestamp = timestamp.tz_convert("UTC")
    return "btc-usdt-index-30m-" + timestamp.strftime("%Y%m%dT%H%M%S%fZ")


def _timestamp_to_iso(value: Any) -> str | None:
    if value is None or pd.isna(value):
        return None
    timestamp = pd.Timestamp(value)
    if timestamp.tzinfo is None:
        return timestamp.isoformat()
    return timestamp.tz_convert("UTC").isoformat().replace("+00:00", "Z")


__all__ = [
    "EVENT_COLUMNS",
    "EventLabelResult",
    "LabelContractError",
    "build_event_candidates",
    "build_event_dataset",
    "build_event_labels",
    "build_valid_event_samples",
    "run_label_causality_check",
]
