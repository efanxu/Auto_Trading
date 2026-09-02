"""Canonical market-data schema used by the B0 data contract."""

from __future__ import annotations

from collections.abc import Iterable

import pandas as pd


CANONICAL_COLUMNS: tuple[str, ...] = (
    "open_time",
    "open",
    "high",
    "low",
    "close",
    "close_time",
)
PRICE_COLUMNS: tuple[str, ...] = ("open", "high", "low", "close")


class SchemaError(ValueError):
    """Raised when a frame cannot satisfy the canonical OHLC schema."""


def missing_canonical_columns(columns: Iterable[str]) -> list[str]:
    """Return canonical columns that are absent, preserving contract order."""

    available = set(columns)
    return [column for column in CANONICAL_COLUMNS if column not in available]


def validate_canonical_schema(frame: pd.DataFrame) -> None:
    """Validate column names and timestamp representation without sorting data."""

    if not isinstance(frame, pd.DataFrame):
        raise SchemaError("canonical data must be a pandas DataFrame")

    missing = missing_canonical_columns(frame.columns)
    if missing:
        raise SchemaError("missing canonical columns: " + ", ".join(missing))

    open_time = frame["open_time"]
    close_time = frame["close_time"]
    for name, values in (("open_time", open_time), ("close_time", close_time)):
        if not isinstance(values.dtype, pd.DatetimeTZDtype):
            raise SchemaError(f"{name} must be a timezone-aware UTC datetime column")
        if str(values.dt.tz) != "UTC":
            raise SchemaError(f"{name} must use UTC timezone")


def empty_canonical_frame() -> pd.DataFrame:
    """Return an empty frame with the canonical dtypes."""

    return pd.DataFrame(
        {
            "open_time": pd.Series([], dtype="datetime64[ns, UTC]"),
            "open": pd.Series([], dtype="float64"),
            "high": pd.Series([], dtype="float64"),
            "low": pd.Series([], dtype="float64"),
            "close": pd.Series([], dtype="float64"),
            "close_time": pd.Series([], dtype="datetime64[ns, UTC]"),
        },
        columns=list(CANONICAL_COLUMNS),
    )


__all__ = [
    "CANONICAL_COLUMNS",
    "PRICE_COLUMNS",
    "SchemaError",
    "empty_canonical_frame",
    "missing_canonical_columns",
    "validate_canonical_schema",
]
