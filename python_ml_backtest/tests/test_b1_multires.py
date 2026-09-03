"""Contract tests for the B1 multi-resolution price foundation."""

from __future__ import annotations

import numpy as np
import pandas as pd

from auto_trading.evaluation import compute_monthly_validation_diagnostics
from auto_trading.data import build_monthly_archive_url, run_data_preflight
from auto_trading.features import (
    COARSE_30M_FEATURE_NAMES,
    FINE_MAX_LAG_BARS,
    MULTIRES_FEATURE_NAMES,
    PRICE_5M_V1_FEATURE_NAMES,
    build_multires_model_dataset,
    build_price_5m_v1_features,
    build_price_multires_features,
    project_feature_view_dataset,
    run_common_sample_equality_check,
    run_fine_alignment_contract_check,
    run_fine_future_mutation_check,
    run_fine_gap_continuity_check,
    run_multires_feature_schema_check,
    run_multires_future_mutation_check,
)


def make_bars(n: int, minutes: int) -> pd.DataFrame:
    start = pd.Timestamp("2024-01-01 00:00:00", tz="UTC")
    opens = pd.date_range(start, periods=n, freq=f"{minutes}min")
    closes = opens + pd.Timedelta(minutes=minutes) - pd.Timedelta(milliseconds=1)
    close = 50000.0 * np.cumprod(1.0 + np.linspace(-0.001, 0.001, n))
    opening = np.roll(close, 1)
    opening[0] = 50000.0
    high = np.maximum(opening, close) * 1.001
    low = np.minimum(opening, close) * 0.999
    return pd.DataFrame(
        {
            "open_time": opens,
            "open": opening,
            "high": high,
            "low": low,
            "close": close,
            "close_time": closes,
        }
    )


def test_b1_feature_schema_counts_and_order() -> None:
    assert len(PRICE_5M_V1_FEATURE_NAMES) == 49
    assert PRICE_5M_V1_FEATURE_NAMES[:8] == (
        "f5_ret_1", "f5_ret_3", "f5_ret_6", "f5_ret_12",
        "f5_ret_24", "f5_ret_48", "f5_ret_144", "f5_ret_288",
    )
    assert PRICE_5M_V1_FEATURE_NAMES[-4:] == (
        "f5_time_of_day_sin", "f5_time_of_day_cos",
        "f5_day_of_week_sin", "f5_day_of_week_cos",
    )
    assert len(COARSE_30M_FEATURE_NAMES) == 34
    assert len(MULTIRES_FEATURE_NAMES) == 83
    assert all(name.startswith("f5_") for name in PRICE_5M_V1_FEATURE_NAMES)
    assert all(name.startswith("c30_") for name in COARSE_30M_FEATURE_NAMES)


def test_five_minute_archive_and_preflight_contract() -> None:
    url = build_monthly_archive_url("BTCUSDT", "5m", 2024, 1)
    assert url.endswith("/monthly/indexPriceKlines/BTCUSDT/5m/BTCUSDT-5m-2024-01.zip")
    bars = make_bars(3, 5)
    report = run_data_preflight(bars, expected_interval_minutes=5)
    assert report["passed"] is True
    assert report["rows"] == 3
    assert report["duplicates"] == 0
    assert report["gaps"] == 0


def test_fine_alignment_uses_last_completed_bar_and_six_bar_path() -> None:
    fine = make_bars(360, 5)
    coarse = fine.iloc[::6].copy().reset_index(drop=True)
    coarse["open_time"] = pd.date_range(
        fine.loc[0, "open_time"], periods=len(coarse), freq="30min"
    )
    coarse["close_time"] = coarse["open_time"] + pd.Timedelta(minutes=30) - pd.Timedelta(milliseconds=1)

    coarse_features, fine_features, fused = build_price_multires_features(coarse, fine)
    assert len(coarse_features) == len(fine_features) == len(fused)
    assert fine_features["alignment_valid"].all()
    assert fused["prediction_time"].equals(coarse_features["prediction_time"])
    assert run_fine_alignment_contract_check(coarse, fine)["passed"]
    assert list(fused.columns) == [
        "prediction_time",
        *COARSE_30M_FEATURE_NAMES,
        *PRICE_5M_V1_FEATURE_NAMES,
        "coarse_feature_valid", "fine_feature_valid", "alignment_valid",
        "multires_feature_valid", "feature_valid", "feature_invalid_reason",
    ]


def test_fine_warmup_and_gap_contract() -> None:
    fine = make_bars(FINE_MAX_LAG_BARS + 2, 5)
    features = build_price_5m_v1_features(fine)
    assert not features.loc[FINE_MAX_LAG_BARS - 1, "feature_valid"]
    assert features.loc[FINE_MAX_LAG_BARS, "feature_valid"]
    assert run_fine_gap_continuity_check()["passed"]


def test_causality_mutation_contracts_pass() -> None:
    assert run_fine_future_mutation_check()["passed"]
    assert run_multires_future_mutation_check()["passed"]


def test_common_sample_projections_are_identical() -> None:
    fine = make_bars(360, 5)
    coarse = fine.iloc[::6].copy().reset_index(drop=True)
    coarse["open_time"] = pd.date_range(
        fine.loc[0, "open_time"], periods=len(coarse), freq="30min"
    )
    coarse["close_time"] = coarse["open_time"] + pd.Timedelta(minutes=30) - pd.Timedelta(milliseconds=1)
    samples = pd.DataFrame(
        {
            "sample_id": [f"s-{i}" for i in range(len(coarse))],
            "prediction_time": coarse["close_time"],
            "split": ["train"] * 50 + ["validation"] * 10,
            "target_up": [i % 2 for i in range(len(coarse))],
            "label_valid": [True] * len(coarse),
        }
    )
    _, _, fused = build_price_multires_features(coarse, fine)
    full = build_multires_model_dataset(samples, fused)
    datasets = {
        name: project_feature_view_dataset(full, name)
        for name in ("coarse", "fine", "multires")
    }
    assert run_common_sample_equality_check(datasets)["passed"]
    assert all(len(dataset) == len(samples) for dataset in datasets.values())


def test_multires_schema_check_is_exact() -> None:
    fine = make_bars(360, 5)
    coarse = fine.iloc[::6].copy().reset_index(drop=True)
    coarse["open_time"] = pd.date_range(
        fine.loc[0, "open_time"], periods=len(coarse), freq="30min"
    )
    coarse["close_time"] = coarse["open_time"] + pd.Timedelta(minutes=30) - pd.Timedelta(milliseconds=1)
    _, _, fused = build_price_multires_features(coarse, fine)
    result = run_multires_feature_schema_check(fused)
    assert result["passed"], result["errors"]
    assert result["feature_count"] == 83


def test_monthly_validation_diagnostics_contract() -> None:
    times = pd.to_datetime(
        ["2025-01-01 00:00Z", "2025-01-15 00:00Z", "2025-02-01 00:00Z", "2025-02-15 00:00Z"]
    )
    result = compute_monthly_validation_diagnostics(times, [1, 0, 1, 0], [0.8, 0.2, 0.7, 0.3])
    assert list(result.columns) == [
        "month", "samples", "accuracy", "roc_auc", "binary_logloss",
        "confidence_event_count", "confidence_hit_rate",
    ]
    assert result["month"].tolist() == ["2025-01", "2025-02"]
    assert result["confidence_event_count"].tolist() == [2, 2]
