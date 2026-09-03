"""Deterministic contract checks for causal features."""

from __future__ import annotations

from typing import Any

import numpy as np
import pandas as pd

from .price_ohlc_v1 import (
    MAX_LAG_BARS,
    PRICE_OHLC_V1_FEATURE_NAMES,
    build_price_ohlc_v1_features,
)


def run_future_mutation_check() -> dict[str, Any]:
    """Verify that modifying future bars does not alter features at bar t."""
    # Generate 70 synthetic 30m bars
    n = 70
    start = pd.Timestamp("2024-01-01 00:00:00", tz="UTC")
    opens = [start + pd.Timedelta(minutes=30 * i) for i in range(n)]
    closes = [opens[i] + pd.Timedelta(minutes=30) - pd.Timedelta(milliseconds=1) for i in range(n)]

    np.random.seed(42)
    base_price = 40000.0
    returns = np.random.normal(0, 0.005, n)
    close_prices = base_price * np.cumprod(1 + returns)
    open_prices = np.roll(close_prices, 1)
    open_prices[0] = base_price
    high_prices = np.maximum(open_prices, close_prices) * (1 + np.random.uniform(0, 0.002, n))
    low_prices = np.minimum(open_prices, close_prices) * (1 - np.random.uniform(0, 0.002, n))

    bars = pd.DataFrame(
        {
            "open_time": opens,
            "open": open_prices,
            "high": high_prices,
            "low": low_prices,
            "close": close_prices,
            "close_time": closes,
        }
    )

    feat_before = build_price_ohlc_v1_features(bars)

    # Mutate future bars from t=50 onwards
    t = 50
    bars_mutated = bars.copy()
    bars_mutated.loc[t + 1 :, "open"] = bars_mutated.loc[t + 1 :, "open"] * 2.0
    bars_mutated.loc[t + 1 :, "high"] = bars_mutated.loc[t + 1 :, "high"] * 2.5
    bars_mutated.loc[t + 1 :, "low"] = bars_mutated.loc[t + 1 :, "low"] * 0.5
    bars_mutated.loc[t + 1 :, "close"] = bars_mutated.loc[t + 1 :, "close"] * 2.2

    feat_after = build_price_ohlc_v1_features(bars_mutated)

    # Compare bar t and all bars <= t
    cols = list(PRICE_OHLC_V1_FEATURE_NAMES)
    errors: list[str] = []

    # Bar t is valid
    if not feat_before.loc[t, "feature_valid"]:
        errors.append(f"expected bar {t} to be feature_valid before mutation")

    vals_before = feat_before.loc[:t, cols].to_numpy(dtype=float)
    vals_after = feat_after.loc[:t, cols].to_numpy(dtype=float)

    # Ignore NaNs during warmup
    valid_mask = feat_before.loc[:t, "feature_valid"].to_numpy()
    if not np.allclose(vals_before[valid_mask], vals_after[valid_mask], rtol=1e-10, atol=1e-10):
        errors.append("feature values up to bar t changed after future mutation")

    # Future bars SHOULD differ
    future_before = feat_before.loc[t + 1 :, cols].to_numpy(dtype=float)
    future_after = feat_after.loc[t + 1 :, cols].to_numpy(dtype=float)
    if np.allclose(future_before, future_after, rtol=1e-5, atol=1e-5):
        errors.append("future bars unexpectedly remained identical")

    return {
        "passed": not errors,
        "errors": errors,
    }


def run_gap_continuity_check() -> dict[str, Any]:
    """Verify that gaps cause invalidation and recovery requires 48 contiguous bars."""
    n = 120
    start = pd.Timestamp("2024-01-01 00:00:00", tz="UTC")
    opens = [start + pd.Timedelta(minutes=30 * i) for i in range(n)]

    # Introduce gap: drop bar 60 (so bar 61 is 60 minutes after bar 59)
    opens.pop(60)
    n_bars = len(opens)
    closes = [opens[i] + pd.Timedelta(minutes=30) - pd.Timedelta(milliseconds=1) for i in range(n_bars)]

    price = 40000.0
    bars = pd.DataFrame(
        {
            "open_time": opens,
            "open": [price] * n_bars,
            "high": [price * 1.001] * n_bars,
            "low": [price * 0.999] * n_bars,
            "close": [price] * n_bars,
            "close_time": closes,
        }
    )

    feat = build_price_ohlc_v1_features(bars)
    errors: list[str] = []

    # Warmup checks (0..47)
    for i in range(MAX_LAG_BARS):
        if feat.loc[i, "feature_valid"]:
            errors.append(f"bar {i} should be invalid during warmup")
        if feat.loc[i, "feature_invalid_reason"] != "insufficient_history":
            errors.append(f"bar {i} invalid reason should be insufficient_history")

    # Bars 48..59 should be valid (contiguous)
    for i in range(MAX_LAG_BARS, 60):
        if not feat.loc[i, "feature_valid"]:
            errors.append(f"bar {i} before gap should be valid")

    # Bar 60 (which was originally bar 61, open_time 59 -> 61 has 1h gap):
    # In the new frame, bar 60 has open_time[60] - open_time[59] = 60min.
    # Therefore, from bar 60 to 60 + 47 = 107, the rolling window of 48 steps contains this gap!
    for i in range(60, 60 + MAX_LAG_BARS):
        if feat.loc[i, "feature_valid"]:
            errors.append(f"bar {i} within 48 bars after gap should be invalid")
        if feat.loc[i, "feature_invalid_reason"] != "non_contiguous_history":
            errors.append(f"bar {i} after gap invalid reason should be non_contiguous_history")

    # Bar 60 + 48 = 108 should recover to valid!
    if not feat.loc[60 + MAX_LAG_BARS, "feature_valid"]:
        errors.append(f"bar {60 + MAX_LAG_BARS} should have recovered to valid after 48 contiguous bars")

    return {
        "passed": not errors,
        "errors": errors,
    }


def run_feature_schema_check(features: pd.DataFrame) -> dict[str, Any]:
    """Verify feature column count, names, order, and absence of target columns."""
    errors: list[str] = []

    expected_cols = [
        "prediction_time",
        *PRICE_OHLC_V1_FEATURE_NAMES,
        "feature_valid",
        "feature_invalid_reason",
    ]
    actual_cols = list(features.columns)

    if actual_cols != expected_cols:
        errors.append("feature columns or ordering does not match schema contract")

    forbidden_cols = {
        "target_up",
        "target_direction",
        "event_entry_price",
        "event_expiry_price",
        "future_return",
        "next_bar_open",
        "next_bar_close",
    }
    present_forbidden = forbidden_cols.intersection(actual_cols)
    if present_forbidden:
        errors.append(f"forbidden future/target columns present: {present_forbidden}")

    return {
        "passed": not errors,
        "errors": errors,
        "feature_count": len(PRICE_OHLC_V1_FEATURE_NAMES),
    }


def run_feature_finite_check(features: pd.DataFrame) -> dict[str, Any]:
    """Verify all valid feature rows contain strictly finite numbers."""
    valid_rows = features[features["feature_valid"] == True]  # noqa: E712
    feature_matrix = valid_rows[list(PRICE_OHLC_V1_FEATURE_NAMES)].to_numpy(dtype=float)

    is_finite = np.all(np.isfinite(feature_matrix))
    errors: list[str] = []
    if not is_finite:
        errors.append("found non-finite values in valid feature rows")

    return {
        "passed": not errors,
        "errors": errors,
        "checked_valid_rows": len(valid_rows),
    }


def run_feature_alignment_check(
    samples: pd.DataFrame,
    features: pd.DataFrame,
    model_dataset: pd.DataFrame,
) -> dict[str, Any]:
    """Verify 1-to-1 alignment between samples and features on prediction_time."""
    errors: list[str] = []

    samples_pt = pd.to_datetime(samples["prediction_time"], utc=True)
    features_pt = pd.to_datetime(features["prediction_time"], utc=True)
    model_pt = pd.to_datetime(model_dataset["prediction_time"], utc=True)

    if len(model_dataset) != len(samples):
        errors.append(
            f"model_dataset row count ({len(model_dataset)}) != samples count ({len(samples)})"
        )

    if not model_pt.equals(samples_pt):
        errors.append("model_dataset prediction_time does not match samples prediction_time")

    if not samples_pt.isin(features_pt).all():
        errors.append("some sample prediction_times are missing from features")

    return {
        "passed": not errors,
        "errors": errors,
        "matched_rows": len(model_dataset),
    }


def run_all_feature_checks(
    *,
    features: pd.DataFrame,
    samples: pd.DataFrame,
    model_dataset: pd.DataFrame,
) -> dict[str, Any]:
    """Run all four formal feature contract checks."""
    mutation_res = run_future_mutation_check()
    gap_res = run_gap_continuity_check()
    causality_passed = mutation_res["passed"] and gap_res["passed"]
    causality_errors = mutation_res["errors"] + gap_res["errors"]

    schema_res = run_feature_schema_check(features)
    finite_res = run_feature_finite_check(features)
    align_res = run_feature_alignment_check(samples, features, model_dataset)

    all_passed = (
        causality_passed
        and schema_res["passed"]
        and finite_res["passed"]
        and align_res["passed"]
    )

    return {
        "passed": all_passed,
        "causality": {"passed": causality_passed, "errors": causality_errors},
        "schema": schema_res,
        "finite": finite_res,
        "alignment": align_res,
    }


__all__ = [
    "run_all_feature_checks",
    "run_feature_alignment_check",
    "run_feature_finite_check",
    "run_feature_schema_check",
    "run_future_mutation_check",
    "run_gap_continuity_check",
]
