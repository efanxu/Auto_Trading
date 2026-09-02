"""Chronological 8:1:1 splitting with event-horizon purge."""

from __future__ import annotations

from dataclasses import dataclass
from math import isclose
from typing import Any

import pandas as pd


SPLIT_NAMES: tuple[str, ...] = ("train", "validation", "test")
SPLIT_COLUMNS: tuple[str, ...] = (
    "prediction_time",
    "event_entry_time",
    "event_expiry_time",
    "split",
)
REQUIRED_EVENT_COLUMNS: tuple[str, ...] = (
    "prediction_time",
    "event_entry_time",
    "event_expiry_time",
)


class SplitContractError(ValueError):
    """Raised when a chronological split cannot satisfy its contract."""


@dataclass(frozen=True)
class ChronologicalSplitResult:
    """Persistable samples and an audit report for one chronological split."""

    samples: pd.DataFrame
    report: dict[str, Any]


def chronological_split(
    samples: pd.DataFrame,
    *,
    train_ratio: float = 0.8,
    validation_ratio: float = 0.1,
    test_ratio: float = 0.1,
    purge_minutes: float = 30,
) -> ChronologicalSplitResult:
    """Assign sorted Event samples to train/validation/test and purge borders.

    Nominal boundaries are selected by row count.  For each boundary, rows in
    the preceding split whose prediction or expiry window reaches the boundary
    are removed.  Purged rows never receive a ``split`` value and are not
    included in the formal sample parquet.
    """

    _validate_ratios(train_ratio, validation_ratio, test_ratio)
    if purge_minutes < 0:
        raise SplitContractError("purge_minutes must be >= 0")
    _validate_sample_columns(samples, require_split=False)
    if samples.empty:
        raise SplitContractError("cannot split an empty sample frame")

    ordered = samples.copy()
    ordered["prediction_time"] = pd.to_datetime(ordered["prediction_time"], utc=True)
    ordered["event_entry_time"] = pd.to_datetime(ordered["event_entry_time"], utc=True)
    ordered["event_expiry_time"] = pd.to_datetime(ordered["event_expiry_time"], utc=True)
    if ordered[["prediction_time", "event_entry_time", "event_expiry_time"]].isna().any().any():
        raise SplitContractError("split input contains null event timestamps")
    if ordered["prediction_time"].duplicated().any():
        raise SplitContractError("prediction_time must be unique before splitting")
    ordered = ordered.sort_values("prediction_time", kind="mergesort").reset_index(drop=True)

    train_boundary_index, test_boundary_index = _boundary_indices(
        len(ordered),
        train_ratio,
        validation_ratio,
        minimum_pre_purge_rows=2 if purge_minutes > 0 else 1,
    )
    ordered["split"] = pd.Series(
        [
            "train" if index < train_boundary_index else
            "validation" if index < test_boundary_index else
            "test"
            for index in range(len(ordered))
        ],
        dtype="string",
    )

    validation_boundary = ordered.iloc[train_boundary_index]["prediction_time"]
    test_boundary = ordered.iloc[test_boundary_index]["prediction_time"]
    purge_delta = pd.Timedelta(minutes=float(purge_minutes))

    train_rows = ordered[ordered["split"] == "train"]
    validation_rows = ordered[ordered["split"] == "validation"]
    train_purge = train_rows[
        (train_rows["prediction_time"] + purge_delta >= validation_boundary)
        | (train_rows["event_expiry_time"] >= validation_boundary)
    ]
    validation_purge = validation_rows[
        (validation_rows["prediction_time"] + purge_delta >= test_boundary)
        | (validation_rows["event_expiry_time"] >= test_boundary)
    ]
    purged_ids = set(train_purge.index).union(validation_purge.index)
    assigned = ordered.drop(index=sorted(purged_ids)).reset_index(drop=True)

    result = ChronologicalSplitResult(
        samples=assigned,
        report=_build_split_report(
            ordered,
            assigned,
            len(purged_ids),
            train_boundary_index,
            test_boundary_index,
            train_ratio,
            validation_ratio,
            test_ratio,
            purge_minutes,
        ),
    )
    check = run_split_check(
        result.samples,
        train_ratio=train_ratio,
        validation_ratio=validation_ratio,
        test_ratio=test_ratio,
    )
    if not check["passed"]:
        raise SplitContractError("; ".join(check["errors"]))
    return result


def run_split_check(
    samples: pd.DataFrame,
    *,
    train_ratio: float = 0.8,
    validation_ratio: float = 0.1,
    test_ratio: float = 0.1,
) -> dict[str, Any]:
    """Validate ordering, continuity, uniqueness, and event target isolation."""

    errors: list[str] = []
    try:
        _validate_sample_columns(samples, require_split=True)
        _validate_ratios(train_ratio, validation_ratio, test_ratio)
    except (SplitContractError, ValueError) as exc:
        return {"passed": False, "errors": [str(exc)], "checked_rows": 0}

    if samples.empty:
        return {"passed": False, "errors": ["split sample frame is empty"], "checked_rows": 0}

    frame = samples.copy()
    for column in ("prediction_time", "event_entry_time", "event_expiry_time"):
        frame[column] = pd.to_datetime(frame[column], utc=True)
    if frame[["prediction_time", "event_entry_time", "event_expiry_time"]].isna().any().any():
        errors.append("split event timestamps must be non-null")
    if frame["split"].isna().any() or not frame["split"].isin(SPLIT_NAMES).all():
        errors.append("split must contain only train, validation, and test")
    if not frame["prediction_time"].is_monotonic_increasing:
        errors.append("split rows must remain chronological; shuffle is not allowed")
    if "sample_id" in frame and frame["sample_id"].duplicated().any():
        errors.append("sample_id must be unique across splits")
    if frame["prediction_time"].duplicated().any():
        errors.append("prediction_time must be unique across splits")

    split_frames = {name: frame[frame["split"] == name] for name in SPLIT_NAMES}
    if any(part.empty for part in split_frames.values()):
        errors.append("train, validation, and test must all be non-empty")
    else:
        train = split_frames["train"]
        validation = split_frames["validation"]
        test = split_frames["test"]
        if not (
            train["prediction_time"].max()
            < validation["prediction_time"].min()
            < test["prediction_time"].min()
        ):
            errors.append("split prediction times must be strictly chronological")
        if train["event_expiry_time"].max() >= validation["event_entry_time"].min():
            errors.append("train and validation event windows overlap")
        if validation["event_expiry_time"].max() >= test["event_entry_time"].min():
            errors.append("validation and test event windows overlap")

    return {
        "passed": not errors,
        "errors": list(dict.fromkeys(errors)),
        "checked_rows": int(len(frame)),
        "counts": {name: int(len(part)) for name, part in split_frames.items()},
    }


def _validate_sample_columns(samples: pd.DataFrame, *, require_split: bool) -> None:
    if not isinstance(samples, pd.DataFrame):
        raise SplitContractError("split input must be a pandas DataFrame")
    required = SPLIT_COLUMNS if require_split else REQUIRED_EVENT_COLUMNS
    missing = [column for column in required if column not in samples.columns]
    if missing:
        raise SplitContractError("split input missing columns: " + ", ".join(missing))


def _validate_ratios(train_ratio: float, validation_ratio: float, test_ratio: float) -> None:
    values = {
        "train_ratio": train_ratio,
        "validation_ratio": validation_ratio,
        "test_ratio": test_ratio,
    }
    for name, value in values.items():
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
            raise SplitContractError(f"{name} must be > 0")
    if not isclose(sum(float(value) for value in values.values()), 1.0, rel_tol=0, abs_tol=1e-12):
        raise SplitContractError("split ratios must sum to 1.0")


def _boundary_indices(
    row_count: int,
    train_ratio: float,
    validation_ratio: float,
    *,
    minimum_pre_purge_rows: int,
) -> tuple[int, int]:
    minimum_total = minimum_pre_purge_rows * 2 + 1
    if row_count < minimum_total:
        raise SplitContractError(
            "not enough samples for three non-empty splits after purge "
            f"(need at least {minimum_total})"
        )
    train_boundary = int(row_count * train_ratio)
    test_boundary = int(row_count * (train_ratio + validation_ratio))
    train_boundary = min(
        max(train_boundary, minimum_pre_purge_rows),
        row_count - minimum_pre_purge_rows - 1,
    )
    test_boundary = min(
        max(test_boundary, train_boundary + minimum_pre_purge_rows),
        row_count - 1,
    )
    return train_boundary, test_boundary


def _build_split_report(
    nominal: pd.DataFrame,
    assigned: pd.DataFrame,
    purged_rows: int,
    train_boundary_index: int,
    test_boundary_index: int,
    train_ratio: float,
    validation_ratio: float,
    test_ratio: float,
    purge_minutes: float,
) -> dict[str, Any]:
    counts = {
        name: int((assigned["split"] == name).sum()) for name in SPLIT_NAMES
    }
    assigned_rows = len(assigned)
    report: dict[str, Any] = {
        "total_candidate_events": int(len(nominal)),
        "valid_events": int(len(nominal)),
        "invalid_events": 0,
        "flat_events": int((nominal.get("target_direction", pd.Series(dtype="int8")) == 0).sum()),
        "train_rows": counts["train"],
        "validation_rows": counts["validation"],
        "test_rows": counts["test"],
        "train_start": _range_value(assigned, "train", "min"),
        "train_end": _range_value(assigned, "train", "max"),
        "validation_start": _range_value(assigned, "validation", "min"),
        "validation_end": _range_value(assigned, "validation", "max"),
        "test_start": _range_value(assigned, "test", "min"),
        "test_end": _range_value(assigned, "test", "max"),
        "actual_ratios": {
            name: counts[name] / assigned_rows if assigned_rows else 0.0
            for name in SPLIT_NAMES
        },
        "ratios_of_valid_events": {
            name: counts[name] / len(nominal) for name in SPLIT_NAMES
        },
        "nominal_ratios": {
            "train": float(train_ratio),
            "validation": float(validation_ratio),
            "test": float(test_ratio),
        },
        "purged_rows": int(purged_rows),
        "purge_minutes": float(purge_minutes),
        "nominal_train_boundary": _timestamp_to_iso(
            nominal.iloc[train_boundary_index]["prediction_time"]
        ),
        "nominal_test_boundary": _timestamp_to_iso(
            nominal.iloc[test_boundary_index]["prediction_time"]
        ),
    }
    return report


def _range_value(frame: pd.DataFrame, split: str, operation: str) -> str | None:
    values = frame.loc[frame["split"] == split, "prediction_time"]
    if values.empty:
        return None
    timestamp = values.min() if operation == "min" else values.max()
    return _timestamp_to_iso(timestamp)


def _timestamp_to_iso(value: Any) -> str | None:
    if value is None or pd.isna(value):
        return None
    timestamp = pd.Timestamp(value)
    if timestamp.tzinfo is None:
        return timestamp.isoformat()
    return timestamp.tz_convert("UTC").isoformat().replace("+00:00", "Z")


__all__ = [
    "ChronologicalSplitResult",
    "SPLIT_COLUMNS",
    "SPLIT_NAMES",
    "REQUIRED_EVENT_COLUMNS",
    "SplitContractError",
    "chronological_split",
    "run_split_check",
]
