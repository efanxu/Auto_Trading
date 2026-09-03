"""Data preflight and OHLC integrity checks."""

from __future__ import annotations

from dataclasses import dataclass
from math import isfinite
from typing import Any

import pandas as pd

from .schema import PRICE_COLUMNS, SchemaError, validate_canonical_schema


class DataValidationError(ValueError):
    """Raised when canonical data violates a hard data contract."""


@dataclass(frozen=True)
class DataPreflightReport:
    """Serializable result of the canonical-data preflight."""

    expected_interval_minutes: int
    total_rows: int
    first_open_time: str | None
    last_close_time: str | None
    duplicate_count: int
    gap_count: int
    gap_ranges: tuple[dict[str, Any], ...]
    irregular_interval_count: int
    issues: tuple[str, ...]
    warnings: tuple[str, ...]

    @property
    def passed(self) -> bool:
        """Whether all hard checks passed; gaps are reported warnings."""

        return not self.issues

    def as_dict(self) -> dict[str, Any]:
        """Return a JSON-compatible report mapping."""

        return {
            "expected_interval_minutes": self.expected_interval_minutes,
            "rows": self.total_rows,
            "total_rows": self.total_rows,
            "first_open_time": self.first_open_time,
            "last_close_time": self.last_close_time,
            "duplicates": self.duplicate_count,
            "duplicate_count": self.duplicate_count,
            "gaps": self.gap_count,
            "gap_count": self.gap_count,
            "gap_ranges": [dict(item) for item in self.gap_ranges],
            "irregular_interval_count": self.irregular_interval_count,
            "issues": list(self.issues),
            "warnings": list(self.warnings),
            "passed": self.passed,
        }


def validate_ohlc(frame: pd.DataFrame) -> list[str]:
    """Return hard OHLC integrity errors for a canonical frame."""

    errors: list[str] = []
    for column in PRICE_COLUMNS:
        values = pd.to_numeric(frame[column], errors="coerce")
        invalid = values.isna() | ~values.map(lambda value: isfinite(float(value)))
        if bool(invalid.any()):
            errors.append(f"{column} contains null or non-finite values")
        non_positive = values.notna() & (values <= 0)
        if bool(non_positive.any()):
            errors.append(f"{column} contains non-positive prices")

    high = pd.to_numeric(frame["high"], errors="coerce")
    low = pd.to_numeric(frame["low"], errors="coerce")
    opening = pd.to_numeric(frame["open"], errors="coerce")
    closing = pd.to_numeric(frame["close"], errors="coerce")
    if bool((high < pd.concat([opening, closing], axis=1).max(axis=1)).fillna(False).any()):
        errors.append("high must be >= max(open, close)")
    if bool((low > pd.concat([opening, closing], axis=1).min(axis=1)).fillna(False).any()):
        errors.append("low must be <= min(open, close)")
    if bool((high < low).fillna(False).any()):
        errors.append("high must be >= low")
    return errors


def run_data_preflight(
    frame: pd.DataFrame,
    *,
    expected_interval_minutes: int = 30,
) -> dict[str, Any]:
    """Run timestamp, interval, duplicate, and OHLC checks.

    A missing interval is a reportable warning rather than a reason to invent
    bars.  The label builder consumes the same real time axis and skips events
    whose next bar is missing.
    """

    if expected_interval_minutes <= 0:
        raise ValueError("expected_interval_minutes must be > 0")

    issues: list[str] = []
    warnings: list[str] = []
    try:
        validate_canonical_schema(frame)
    except SchemaError as exc:
        report = DataPreflightReport(
            expected_interval_minutes=expected_interval_minutes,
            total_rows=len(frame) if isinstance(frame, pd.DataFrame) else 0,
            first_open_time=None,
            last_close_time=None,
            duplicate_count=0,
            gap_count=0,
            gap_ranges=(),
            irregular_interval_count=0,
            issues=(str(exc),),
            warnings=(),
        )
        return report.as_dict()

    total_rows = len(frame)
    if total_rows == 0:
        issues.append("canonical data is empty")

    open_time = frame["open_time"]
    close_time = frame["close_time"]
    duplicate_count = int(open_time.duplicated(keep="first").sum())
    if duplicate_count:
        issues.append(f"open_time contains {duplicate_count} duplicate rows")

    if open_time.isna().any():
        issues.append("open_time contains null timestamps")
    if close_time.isna().any():
        issues.append("close_time contains null timestamps")

    deltas = open_time.diff().dt.total_seconds().div(60)
    non_increasing = deltas.iloc[1:] <= 0
    if bool(non_increasing.fillna(False).any()):
        issues.append("open_time must be strictly increasing")

    expected = float(expected_interval_minutes)
    gap_ranges: list[dict[str, Any]] = []
    irregular_count = 0
    if total_rows > 1:
        for index in range(1, total_rows):
            delta = deltas.iloc[index]
            if pd.isna(delta) or delta == expected:
                continue
            irregular_count += 1
            previous = open_time.iloc[index - 1]
            current = open_time.iloc[index]
            if delta > expected:
                missing_bars = max(int(delta // expected) - 1, 0)
                gap_ranges.append(
                    {
                        "from_open_time": _timestamp_to_iso(previous),
                        "expected_next_open_time": _timestamp_to_iso(
                            previous + pd.Timedelta(minutes=expected_interval_minutes)
                        ),
                        "to_open_time": _timestamp_to_iso(current),
                        "duration_minutes": float(delta),
                        "missing_bars": missing_bars,
                    }
                )
            else:
                warnings.append(
                    "irregular open_time interval: "
                    f"{_timestamp_to_iso(previous)} -> {_timestamp_to_iso(current)}"
                )

    if gap_ranges:
        warnings.append(f"detected {len(gap_ranges)} gap range(s); no fill was applied")

    close_after_open = (close_time > open_time).fillna(False)
    if not bool(close_after_open.all()):
        issues.append("close_time must be greater than open_time")

    issues.extend(validate_ohlc(frame))

    report = DataPreflightReport(
        expected_interval_minutes=expected_interval_minutes,
        total_rows=total_rows,
        first_open_time=_timestamp_to_iso(open_time.iloc[0]) if total_rows else None,
        last_close_time=_timestamp_to_iso(close_time.iloc[-1]) if total_rows else None,
        duplicate_count=duplicate_count,
        gap_count=len(gap_ranges),
        gap_ranges=tuple(gap_ranges),
        irregular_interval_count=irregular_count,
        issues=tuple(dict.fromkeys(issues)),
        warnings=tuple(dict.fromkeys(warnings)),
    )
    return report.as_dict()


def assert_data_preflight(
    frame: pd.DataFrame,
    *,
    expected_interval_minutes: int = 30,
) -> dict[str, Any]:
    """Run preflight and raise a clear error for hard contract failures."""

    report = run_data_preflight(
        frame,
        expected_interval_minutes=expected_interval_minutes,
    )
    if not report["passed"]:
        details = "; ".join(report["issues"])
        raise DataValidationError(details)
    return report


def _timestamp_to_iso(value: Any) -> str | None:
    if value is None or pd.isna(value):
        return None
    timestamp = pd.Timestamp(value)
    if timestamp.tzinfo is None:
        return timestamp.isoformat()
    return timestamp.tz_convert("UTC").isoformat().replace("+00:00", "Z")


__all__ = [
    "DataPreflightReport",
    "DataValidationError",
    "assert_data_preflight",
    "run_data_preflight",
    "validate_ohlc",
]
