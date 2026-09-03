"""Deterministic contract checks for causal features."""

from __future__ import annotations

from os import PathLike
from pathlib import Path
from typing import Any, Mapping

import numpy as np
import pandas as pd

from .price_ohlc_v1 import (
    MAX_LAG_BARS,
    PRICE_OHLC_V1_FEATURE_NAMES,
    build_price_ohlc_v1_features,
)
from .multires import build_price_multires_features
from .price_5m_v1 import (
    FINE_MAX_LAG_BARS,
    PRICE_5M_V1_FEATURE_NAMES,
    build_price_5m_v1_features,
)
from .views import COARSE_30M_FEATURE_NAMES, MULTIRES_FEATURE_NAMES


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


def run_fine_future_mutation_check() -> dict[str, Any]:
    """Verify that future 5m bars cannot change a current fine feature row."""

    fine = _synthetic_bars(420, minutes=5, seed=7)
    target_index = 320
    prediction_time = fine.loc[target_index, "close_time"]
    before = build_price_5m_v1_features(fine, prediction_times=[prediction_time])
    mutated = fine.copy()
    mutated.loc[target_index + 1 :, "open"] *= 2.0
    mutated.loc[target_index + 1 :, "high"] *= 2.5
    mutated.loc[target_index + 1 :, "low"] *= 0.5
    mutated.loc[target_index + 1 :, "close"] *= 2.2
    after = build_price_5m_v1_features(mutated, prediction_times=[prediction_time])
    errors: list[str] = []
    if not bool(before.loc[0, "feature_valid"]):
        errors.append("synthetic current fine row was not valid")
    if not np.allclose(
        before.loc[0, list(PRICE_5M_V1_FEATURE_NAMES)].to_numpy(dtype=float),
        after.loc[0, list(PRICE_5M_V1_FEATURE_NAMES)].to_numpy(dtype=float),
        rtol=1e-10,
        atol=1e-10,
    ):
        errors.append("future 5m mutation changed current fine features")
    return {"passed": not errors, "errors": errors}


def run_fine_gap_continuity_check() -> dict[str, Any]:
    """Verify 5m gap invalidation and 288-step recovery."""

    fine = _synthetic_bars(650, minutes=5, seed=11)
    fine = fine.drop(index=300).reset_index(drop=True)
    features = build_price_5m_v1_features(fine)
    errors: list[str] = []
    for index in range(FINE_MAX_LAG_BARS):
        if bool(features.loc[index, "feature_valid"]):
            errors.append(f"fine row {index} should be invalid during warmup")
        if features.loc[index, "feature_invalid_reason"] != "insufficient_history":
            errors.append(f"fine row {index} has wrong warmup reason")
    gap_position = 300
    for index in range(gap_position, gap_position + FINE_MAX_LAG_BARS):
        if bool(features.loc[index, "feature_valid"]):
            errors.append(f"fine row {index} should be invalid after gap")
        if features.loc[index, "feature_invalid_reason"] != "non_contiguous_history":
            errors.append(f"fine row {index} has wrong gap reason")
    recovery = gap_position + FINE_MAX_LAG_BARS
    if not bool(features.loc[recovery, "feature_valid"]):
        errors.append("fine features did not recover after 288 contiguous steps")
    return {"passed": not errors, "errors": errors}


def run_fine_alignment_contract_check(
    coarse_bars: pd.DataFrame,
    fine_bars: pd.DataFrame,
    *,
    allow_real_gaps: bool = False,
) -> dict[str, Any]:
    """Check exact close-time alignment and six completed 5m bars per 30m bar.

    With ``allow_real_gaps=True``, rows whose missing fine bars are directly
    explained by a real fine-data gap are reported as invalid rows rather than
    treated as an alignment implementation failure.  This preserves the real
    time axis while allowing the data contract to pass on known gaps.
    """

    errors: list[str] = []
    coarse = coarse_bars.sort_values("open_time", kind="mergesort").reset_index(drop=True)
    fine = fine_bars.sort_values("open_time", kind="mergesort").reset_index(drop=True)
    coarse_prediction_times = pd.to_datetime(coarse["close_time"], utc=True)
    fine_open_times = pd.to_datetime(fine["open_time"], utc=True)
    fine_close_times = pd.to_datetime(fine["close_time"], utc=True)
    fine_open_set = set(fine_open_times)
    gap_explained_rows = 0
    for index, prediction_time in enumerate(coarse_prediction_times):
        position = int(fine_close_times.searchsorted(prediction_time, side="left"))
        if position >= len(fine) or fine_close_times.iloc[position] != prediction_time:
            expected_last_open = prediction_time - pd.Timedelta(minutes=5) + pd.Timedelta(milliseconds=1)
            if allow_real_gaps and expected_last_open not in fine_open_set:
                gap_explained_rows += 1
            else:
                errors.append(f"coarse row {index} has no exact completed 5m bar")
            continue
        if position < 5:
            errors.append(f"coarse row {index} has fewer than six completed 5m bars")
            continue
        recent_opens = fine_open_times.iloc[position - 5 : position + 1]
        if not bool((recent_opens.diff().iloc[1:] == pd.Timedelta(minutes=5)).all()):
            expected_opens = [
                prediction_time - pd.Timedelta(minutes=30) + pd.Timedelta(milliseconds=1)
                + pd.Timedelta(minutes=5 * offset)
                for offset in range(6)
            ]
            if allow_real_gaps and not set(expected_opens).issubset(fine_open_set):
                gap_explained_rows += 1
            else:
                errors.append(f"coarse row {index} does not have six contiguous completed 5m bars")
    return {
        "passed": not errors,
        "errors": list(dict.fromkeys(errors)),
        "checked_rows": len(coarse),
        "aligned_rows": int(
            coarse_prediction_times.isin(fine_close_times).sum()
        ),
        "gap_explained_rows": gap_explained_rows,
    }


def run_multires_future_mutation_check() -> dict[str, Any]:
    """Verify future 5m and future 30m mutations preserve the fused current row."""

    fine = _synthetic_bars(420, minutes=5, seed=17)
    coarse = fine.iloc[::6].copy().reset_index(drop=True)
    coarse["open_time"] = pd.date_range(
        fine.loc[0, "open_time"], periods=len(coarse), freq="30min"
    )
    coarse["close_time"] = coarse["open_time"] + pd.Timedelta(minutes=30) - pd.Timedelta(milliseconds=1)
    target_index = 50
    before = build_price_multires_features(coarse, fine)[2]

    fine_mutated = fine.copy()
    # The coarse prediction at index t aligns to the sixth fine bar in its
    # 30-minute block (row t*6 + 5); mutate strictly after that bar.
    fine_start = target_index * 6 + 6
    fine_mutated.loc[fine_start:, "close"] *= 2.0
    fine_mutated.loc[fine_start:, "high"] *= 2.0
    fine_mutated.loc[fine_start:, "low"] *= 0.5
    coarse_mutated = coarse.copy()
    coarse_mutated.loc[target_index + 1 :, "close"] *= 2.0
    coarse_mutated.loc[target_index + 1 :, "high"] *= 2.0
    coarse_mutated.loc[target_index + 1 :, "low"] *= 0.5
    after = build_price_multires_features(coarse_mutated, fine_mutated)[2]

    errors: list[str] = []
    if not bool(before.loc[target_index, "multires_feature_valid"]):
        errors.append("synthetic fused current row was not valid")
    before_values = before.loc[target_index, list(MULTIRES_FEATURE_NAMES)].to_numpy(dtype=float)
    after_values = after.loc[target_index, list(MULTIRES_FEATURE_NAMES)].to_numpy(dtype=float)
    if not np.allclose(before_values, after_values, rtol=1e-10, atol=1e-10):
        errors.append("future fine/coarse mutation changed fused current features")
    return {"passed": not errors, "errors": errors}


def run_multires_feature_schema_check(features: pd.DataFrame) -> dict[str, Any]:
    """Verify the exact 83-feature fused schema and validity metadata."""

    expected = [
        "prediction_time",
        *COARSE_30M_FEATURE_NAMES,
        *PRICE_5M_V1_FEATURE_NAMES,
        "coarse_feature_valid",
        "fine_feature_valid",
        "alignment_valid",
        "multires_feature_valid",
        "feature_valid",
        "feature_invalid_reason",
    ]
    errors: list[str] = []
    if list(features.columns) != expected:
        errors.append("fused feature columns or ordering does not match schema contract")
    forbidden = {"target_up", "target_direction", "event_entry_price", "event_expiry_price"}
    present = forbidden.intersection(features.columns)
    if present:
        errors.append(f"forbidden target/event columns present: {present}")
    return {
        "passed": not errors,
        "errors": errors,
        "coarse_feature_count": len(COARSE_30M_FEATURE_NAMES),
        "fine_feature_count": len(PRICE_5M_V1_FEATURE_NAMES),
        "feature_count": len(MULTIRES_FEATURE_NAMES),
    }


def run_multires_feature_finite_check(features: pd.DataFrame) -> dict[str, Any]:
    """Verify all valid fused rows contain finite 83-dimensional inputs."""

    valid_rows = features[features["multires_feature_valid"] == True]  # noqa: E712
    matrix = valid_rows[list(MULTIRES_FEATURE_NAMES)].to_numpy(dtype=float)
    finite = np.all(np.isfinite(matrix))
    return {
        "passed": bool(finite),
        "errors": [] if finite else ["found non-finite values in valid fused rows"],
        "checked_valid_rows": len(valid_rows),
    }


def run_common_sample_equality_check(
    datasets: Mapping[str, pd.DataFrame],
) -> dict[str, Any]:
    """Verify B1-C/F/MR have identical sample metadata in every split."""

    errors: list[str] = []
    required = ["sample_id", "prediction_time", "target_up", "split"]
    normalized: dict[str, pd.DataFrame] = {}
    for name, dataset in datasets.items():
        missing = [column for column in required if column not in dataset.columns]
        if missing:
            errors.append(f"{name} missing common sample columns: {missing}")
            continue
        current = dataset[required].copy().reset_index(drop=True)
        current["prediction_time"] = pd.to_datetime(current["prediction_time"], utc=True)
        normalized[name] = current
    if normalized:
        reference_name, reference = next(iter(normalized.items()))
        for name, current in normalized.items():
            if not reference.equals(current):
                errors.append(f"{name} sample_id/prediction_time/target_up differs from {reference_name}")
    return {
        "passed": not errors,
        "errors": errors,
        "checked_variants": sorted(datasets),
        "sample_count": len(next(iter(normalized.values()))) if normalized else 0,
    }


def run_test_sealing_check(result_directories: Mapping[str, str | PathLike[str]]) -> dict[str, Any]:
    """Check B1 result directories are sealed and have no Test artifacts."""

    errors: list[str] = []
    for variant, directory in result_directories.items():
        result_path = Path(directory)
        run_info_path = result_path / "run_info.json"
        if not run_info_path.is_file():
            errors.append(f"{variant} missing run_info.json")
            continue
        import json

        try:
            run_info = json.loads(run_info_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            errors.append(f"{variant} run_info unreadable: {exc}")
            continue
        if run_info.get("test_status") != "SEALED":
            errors.append(f"{variant} test_status is not SEALED")
        for filename in ("metrics_test.json", "predictions_test.parquet"):
            if (result_path / filename).exists():
                errors.append(f"{variant} contains forbidden Test artifact {filename}")
    return {"passed": not errors, "errors": errors}


def run_all_multires_checks(
    *,
    coarse_bars: pd.DataFrame,
    fine_bars: pd.DataFrame,
    fused_features: pd.DataFrame,
    datasets: Mapping[str, pd.DataFrame],
) -> dict[str, Any]:
    """Run B1 alignment, causality, schema, finite, and common-sample checks."""

    fine_mutation = run_fine_future_mutation_check()
    fine_gap = run_fine_gap_continuity_check()
    fused_mutation = run_multires_future_mutation_check()
    causality = {
        "passed": fine_mutation["passed"] and fine_gap["passed"] and fused_mutation["passed"],
        "errors": fine_mutation["errors"] + fine_gap["errors"] + fused_mutation["errors"],
    }
    alignment = run_fine_alignment_contract_check(
        coarse_bars,
        fine_bars,
        allow_real_gaps=True,
    )
    schema = run_multires_feature_schema_check(fused_features)
    finite = run_multires_feature_finite_check(fused_features)
    common = run_common_sample_equality_check(datasets)
    all_passed = all(
        result["passed"]
        for result in (causality, alignment, schema, finite, common)
    )
    return {
        "passed": all_passed,
        "causality": causality,
        "alignment": alignment,
        "schema": schema,
        "finite": finite,
        "common_samples": common,
    }


def _synthetic_bars(n: int, *, minutes: int, seed: int) -> pd.DataFrame:
    start = pd.Timestamp("2024-01-01 00:00:00", tz="UTC")
    opens = pd.date_range(start, periods=n, freq=f"{minutes}min")
    closes = opens + pd.Timedelta(minutes=minutes) - pd.Timedelta(milliseconds=1)
    rng = np.random.default_rng(seed)
    close_prices = 40000.0 * np.cumprod(1.0 + rng.normal(0.0, 0.002, n))
    open_prices = np.roll(close_prices, 1)
    open_prices[0] = 40000.0
    high_prices = np.maximum(open_prices, close_prices) * (1.0 + rng.uniform(0.0001, 0.002, n))
    low_prices = np.minimum(open_prices, close_prices) * (1.0 - rng.uniform(0.0001, 0.002, n))
    return pd.DataFrame(
        {
            "open_time": opens,
            "open": open_prices,
            "high": high_prices,
            "low": low_prices,
            "close": close_prices,
            "close_time": closes,
        }
    )


__all__ = [
    "run_all_feature_checks",
    "run_feature_alignment_check",
    "run_feature_finite_check",
    "run_feature_schema_check",
    "run_future_mutation_check",
    "run_gap_continuity_check",
    "run_all_multires_checks",
    "run_common_sample_equality_check",
    "run_fine_alignment_contract_check",
    "run_fine_future_mutation_check",
    "run_fine_gap_continuity_check",
    "run_multires_feature_finite_check",
    "run_multires_feature_schema_check",
    "run_multires_future_mutation_check",
    "run_test_sealing_check",
]
