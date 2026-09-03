"""Tests for price_ohlc_v1 feature engineering and causality contracts."""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from auto_trading.features import (
    MAX_LAG_BARS,
    PRICE_OHLC_V1_FEATURE_NAMES,
    build_feature_report,
    build_model_dataset,
    build_price_ohlc_v1_features,
    get_feature_names,
    run_all_feature_checks,
    run_future_mutation_check,
    run_gap_continuity_check,
)


def make_synthetic_bars(n: int = 60, seed: int = 42) -> pd.DataFrame:
    """Generate synthetic contiguous 30m bars."""
    start = pd.Timestamp("2024-01-01 00:00:00", tz="UTC")
    opens = [start + pd.Timedelta(minutes=30 * i) for i in range(n)]
    closes = [opens[i] + pd.Timedelta(minutes=30) - pd.Timedelta(milliseconds=1) for i in range(n)]

    rng = np.random.default_rng(seed)
    base = 50000.0
    returns = rng.normal(0, 0.005, n)
    close_p = base * np.cumprod(1 + returns)
    open_p = np.roll(close_p, 1)
    open_p[0] = base
    high_p = np.maximum(open_p, close_p) * (1 + rng.uniform(0.0001, 0.002, n))
    low_p = np.minimum(open_p, close_p) * (1 - rng.uniform(0.0001, 0.002, n))

    return pd.DataFrame(
        {
            "open_time": opens,
            "open": open_p,
            "high": high_p,
            "low": low_p,
            "close": close_p,
            "close_time": closes,
        }
    )


def test_feature_names_count_and_order() -> None:
    names = get_feature_names()
    assert len(names) == 34
    assert names == PRICE_OHLC_V1_FEATURE_NAMES
    # Verify exact grouping counts
    assert names[:6] == ("ret_1", "ret_2", "ret_4", "ret_8", "ret_16", "ret_48")
    assert names[6:10] == ("vol_4", "vol_8", "vol_16", "vol_48")
    assert names[10:12] == ("sma_gap_4_16", "sma_gap_8_48")
    assert names[12:15] == ("zscore_8", "zscore_16", "zscore_48")
    assert names[15:20] == ("range_pct", "body_pct", "upper_wick_pct", "lower_wick_pct", "close_location")
    assert names[20:26] == (
        "rolling_high_distance_8", "rolling_high_distance_16", "rolling_high_distance_48",
        "rolling_low_distance_8", "rolling_low_distance_16", "rolling_low_distance_48",
    )
    assert names[26:30] == ("atr_pct_4", "atr_pct_8", "atr_pct_16", "atr_pct_48")
    assert names[30:34] == ("time_of_day_sin", "time_of_day_cos", "day_of_week_sin", "day_of_week_cos")


def test_future_mutation_check_passes() -> None:
    res = run_future_mutation_check()
    assert res["passed"] is True, f"Mutation check failed: {res['errors']}"


def test_gap_continuity_check_passes() -> None:
    res = run_gap_continuity_check()
    assert res["passed"] is True, f"Gap check failed: {res['errors']}"


def test_warmup_invalidation() -> None:
    bars = make_synthetic_bars(n=50)
    feat = build_price_ohlc_v1_features(bars)

    # First 48 rows must be invalid with insufficient_history
    for i in range(MAX_LAG_BARS):
        assert not feat.loc[i, "feature_valid"]
        assert feat.loc[i, "feature_invalid_reason"] == "insufficient_history"

    # Row 48 and 49 must be valid
    assert feat.loc[48, "feature_valid"]
    assert feat.loc[48, "feature_invalid_reason"] is None
    assert feat.loc[49, "feature_valid"]


def test_no_target_or_future_columns_in_feature_set() -> None:
    bars = make_synthetic_bars(n=55)
    feat = build_price_ohlc_v1_features(bars)

    forbidden = {
        "target_up", "target_direction", "event_entry_price", "event_expiry_price",
        "future_return", "next_bar_open", "next_bar_close",
    }
    present = forbidden.intersection(feat.columns)
    assert not present, f"Forbidden columns present: {present}"


def test_valid_features_are_finite() -> None:
    bars = make_synthetic_bars(n=60)
    feat = build_price_ohlc_v1_features(bars)
    valid_rows = feat[feat["feature_valid"] == True]

    feature_matrix = valid_rows[list(PRICE_OHLC_V1_FEATURE_NAMES)].to_numpy(dtype=float)
    assert np.all(np.isfinite(feature_matrix))


def test_model_dataset_alignment() -> None:
    bars = make_synthetic_bars(n=60)
    feat = build_price_ohlc_v1_features(bars)

    # Fake samples aligned with bars
    samples = pd.DataFrame(
        {
            "sample_id": [f"sample-{i}" for i in range(len(bars))],
            "prediction_time": bars["close_time"],
            "split": ["train"] * 50 + ["validation"] * 5 + ["test"] * 5,
            "target_up": [1] * 30 + [0] * 30,
            "label_valid": [True] * 60,
        }
    )

    ds = build_model_dataset(samples, feat)
    assert len(ds) == len(samples)
    assert list(ds.columns[:6]) == [
        "sample_id", "prediction_time", "split", "target_up", "label_valid", "feature_valid"
    ]
    assert list(ds.columns[6:]) == list(PRICE_OHLC_V1_FEATURE_NAMES)
    assert ds["prediction_time"].equals(samples["prediction_time"])


def test_all_feature_checks_pass() -> None:
    bars = make_synthetic_bars(n=70)
    feat = build_price_ohlc_v1_features(bars)
    samples = pd.DataFrame(
        {
            "sample_id": [f"sample-{i}" for i in range(len(bars))],
            "prediction_time": bars["close_time"],
            "split": ["train"] * 55 + ["validation"] * 10 + ["test"] * 5,
            "target_up": [1] * 35 + [0] * 35,
            "label_valid": [True] * 70,
        }
    )
    model_ds = build_model_dataset(samples, feat)
    res = run_all_feature_checks(features=feat, samples=samples, model_dataset=model_ds)
    assert res["passed"] is True
