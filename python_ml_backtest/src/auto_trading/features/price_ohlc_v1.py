"""Price-only causal OHLC feature engineering (price_ohlc_v1).

All features at bar t strictly use information available at close_time[t]
(i.e. timestamp <= t). Future information, target variables, and event prices
are never accessed.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd

PRICE_OHLC_V1_FEATURE_NAMES: tuple[str, ...] = (
    # Log return (6)
    "ret_1",
    "ret_2",
    "ret_4",
    "ret_8",
    "ret_16",
    "ret_48",
    # Realized volatility (4)
    "vol_4",
    "vol_8",
    "vol_16",
    "vol_48",
    # SMA trend (2)
    "sma_gap_4_16",
    "sma_gap_8_48",
    # Close Z-score (3)
    "zscore_8",
    "zscore_16",
    "zscore_48",
    # Candle structure (5)
    "range_pct",
    "body_pct",
    "upper_wick_pct",
    "lower_wick_pct",
    "close_location",
    # Rolling range position (6)
    "rolling_high_distance_8",
    "rolling_high_distance_16",
    "rolling_high_distance_48",
    "rolling_low_distance_8",
    "rolling_low_distance_16",
    "rolling_low_distance_48",
    # ATR-like normalized range (4)
    "atr_pct_4",
    "atr_pct_8",
    "atr_pct_16",
    "atr_pct_48",
    # Periodic calendar features (4)
    "time_of_day_sin",
    "time_of_day_cos",
    "day_of_week_sin",
    "day_of_week_cos",
)

MAX_LAG_BARS: int = 48


def get_feature_names() -> tuple[str, ...]:
    """Return the official stable list of 34 feature names."""
    return PRICE_OHLC_V1_FEATURE_NAMES


def build_price_ohlc_v1_features(bars: pd.DataFrame) -> pd.DataFrame:
    """Compute 34 causal features from canonical 30m OHLC bars.

    Args:
        bars: DataFrame containing ``open_time``, ``open``, ``high``, ``low``,
            ``close``, ``close_time``.

    Returns:
        DataFrame containing ``prediction_time``, the 34 feature columns,
        ``feature_valid``, and ``feature_invalid_reason``.
    """
    required_cols = ("open_time", "open", "high", "low", "close", "close_time")
    missing = [col for col in required_cols if col not in bars.columns]
    if missing:
        raise ValueError(f"bars missing required columns: {missing}")

    if bars.empty:
        return pd.DataFrame(
            columns=["prediction_time", *PRICE_OHLC_V1_FEATURE_NAMES, "feature_valid", "feature_invalid_reason"]
        )

    # Sort strictly by open_time
    df = bars.sort_values("open_time", kind="mergesort").reset_index(drop=True)
    open_p = df["open"].astype(float)
    high_p = df["high"].astype(float)
    low_p = df["low"].astype(float)
    close_p = df["close"].astype(float)
    open_t = pd.to_datetime(df["open_time"], utc=True)
    close_t = pd.to_datetime(df["close_time"], utc=True)

    features: dict[str, Any] = {}

    # A. Log return: ret_k = ln(C_t / C_{t-k})
    log_c = np.log(close_p)
    for k in (1, 2, 4, 8, 16, 48):
        features[f"ret_{k}"] = log_c - log_c.shift(k)

    # B. Realized volatility: vol_k = std(r_{t-k+1:t}, ddof=0) where r_i = ln(C_i / C_{i-1})
    r_1 = log_c - log_c.shift(1)
    for k in (4, 8, 16, 48):
        features[f"vol_{k}"] = r_1.rolling(k).std(ddof=0)

    # C. Finite-window trend: sma_gap_4_16, sma_gap_8_48
    sma_4 = close_p.rolling(4).mean()
    sma_8 = close_p.rolling(8).mean()
    sma_16 = close_p.rolling(16).mean()
    sma_48 = close_p.rolling(48).mean()
    features["sma_gap_4_16"] = sma_4 / sma_16 - 1.0
    features["sma_gap_8_48"] = sma_8 / sma_48 - 1.0

    # D. Close Z-score: z_k = (C_t - mu_k) / sigma_k (ddof=0, 0 if sigma==0)
    for k in (8, 16, 48):
        mu_k = close_p.rolling(k).mean()
        sigma_k = close_p.rolling(k).std(ddof=0)
        z = np.where(sigma_k > 1e-12, (close_p - mu_k) / sigma_k, 0.0)
        # If sigma_k is NaN (e.g. before k bars), preserve NaN
        z = np.where(sigma_k.isna(), np.nan, z)
        features[f"zscore_{k}"] = z

    # E. Candle structure
    range_val = high_p - low_p
    features["range_pct"] = range_val / close_p
    features["body_pct"] = (close_p - open_p) / open_p
    features["upper_wick_pct"] = (high_p - np.maximum(open_p, close_p)) / close_p
    features["lower_wick_pct"] = (np.minimum(open_p, close_p) - low_p) / close_p
    features["close_location"] = np.where(range_val > 1e-12, (close_p - low_p) / range_val, 0.5)

    # F. Rolling range position: rolling_high_distance_k, rolling_low_distance_k
    for k in (8, 16, 48):
        roll_max = high_p.rolling(k).max()
        roll_min = low_p.rolling(k).min()
        features[f"rolling_high_distance_{k}"] = close_p / roll_max - 1.0
        features[f"rolling_low_distance_{k}"] = close_p / roll_min - 1.0

    # G. ATR-like normalized range
    prev_close = close_p.shift(1)
    tr1 = high_p - low_p
    tr2 = (high_p - prev_close).abs()
    tr3 = (low_p - prev_close).abs()
    tr = np.maximum(tr1, np.maximum(tr2, tr3))
    for k in (4, 8, 16, 48):
        atr_k = tr.rolling(k).mean()
        features[f"atr_pct_{k}"] = atr_k / close_p

    # H. Periodic calendar features (UTC minute-of-day / 1440 and dayofweek / 7)
    minute_of_day = close_t.dt.hour * 60 + close_t.dt.minute
    theta_day = 2.0 * np.pi * minute_of_day / 1440.0
    features["time_of_day_sin"] = np.sin(theta_day)
    features["time_of_day_cos"] = np.cos(theta_day)

    theta_week = 2.0 * np.pi * close_t.dt.dayofweek / 7.0
    features["day_of_week_sin"] = np.sin(theta_week)
    features["day_of_week_cos"] = np.cos(theta_week)

    # Build intermediate feature frame
    feat_df = pd.DataFrame(features, columns=list(PRICE_OHLC_V1_FEATURE_NAMES))

    # Continuity & validity checks
    # Maximum lag is 48 bars, requiring 49 contiguous bars (48 steps)
    step_is_30m = open_t.diff() == pd.Timedelta(minutes=30)
    # rolling sum of 48 steps being exactly 30m
    contiguous_48 = step_is_30m.rolling(MAX_LAG_BARS).sum() == MAX_LAG_BARS

    n_rows = len(df)
    valid = np.ones(n_rows, dtype=bool)
    reason = pd.Series([None] * n_rows, dtype="object")

    for i in range(n_rows):
        if i < MAX_LAG_BARS:
            valid[i] = False
            reason.iloc[i] = "insufficient_history"
        elif not contiguous_48.iloc[i]:
            valid[i] = False
            reason.iloc[i] = "non_contiguous_history"
        else:
            row_vals = feat_df.iloc[i].to_numpy(dtype=float)
            if not np.all(np.isfinite(row_vals)):
                valid[i] = False
                reason.iloc[i] = "non_finite_feature"

    result = pd.DataFrame()
    result["prediction_time"] = close_t
    for name in PRICE_OHLC_V1_FEATURE_NAMES:
        result[name] = feat_df[name]
    result["feature_valid"] = valid
    result["feature_invalid_reason"] = reason

    return result


def build_model_dataset(
    samples: pd.DataFrame,
    features: pd.DataFrame,
) -> pd.DataFrame:
    """Merge Event samples with causal features on prediction_time.

    Args:
        samples: DataFrame containing ``sample_id``, ``prediction_time``,
            ``split``, ``target_up``, ``label_valid``.
        features: DataFrame returned by ``build_price_ohlc_v1_features``.

    Returns:
        DataFrame aligned 1-to-1 with samples.
    """
    required_sample_cols = ("sample_id", "prediction_time", "split", "target_up", "label_valid")
    for col in required_sample_cols:
        if col not in samples.columns:
            raise ValueError(f"samples missing required column: {col}")

    s = samples.copy()
    s["prediction_time"] = pd.to_datetime(s["prediction_time"], utc=True)
    f = features.copy()
    f["prediction_time"] = pd.to_datetime(f["prediction_time"], utc=True)

    feature_cols = list(PRICE_OHLC_V1_FEATURE_NAMES) + ["feature_valid"]
    merged = pd.merge(
        s[list(required_sample_cols)],
        f[["prediction_time", *feature_cols]],
        on="prediction_time",
        how="inner",
    )

    if len(merged) != len(samples):
        raise ValueError(
            f"alignment mismatch: samples={len(samples)}, merged={len(merged)}"
        )

    col_order = [
        "sample_id",
        "prediction_time",
        "split",
        "target_up",
        "label_valid",
        "feature_valid",
        *PRICE_OHLC_V1_FEATURE_NAMES,
    ]
    return merged[col_order]


def build_feature_report(
    features: pd.DataFrame,
    model_dataset: pd.DataFrame,
) -> dict[str, Any]:
    """Generate comprehensive summary statistics for the feature build."""
    total_rows = len(features)
    valid_feature_rows = int(features["feature_valid"].sum())
    invalid_feature_rows = total_rows - valid_feature_rows

    reasons = features["feature_invalid_reason"].value_counts().to_dict()
    insufficient = int(reasons.get("insufficient_history", 0))
    non_contiguous = int(reasons.get("non_contiguous_history", 0))
    non_finite = int(reasons.get("non_finite_feature", 0))

    # Model rows count
    train_model = int(
        (
            (model_dataset["split"] == "train")
            & (model_dataset["label_valid"] == True)  # noqa: E712
            & (model_dataset["feature_valid"] == True)  # noqa: E712
        ).sum()
    )
    val_model = int(
        (
            (model_dataset["split"] == "validation")
            & (model_dataset["label_valid"] == True)  # noqa: E712
            & (model_dataset["feature_valid"] == True)  # noqa: E712
        ).sum()
    )
    test_features = int(
        (
            (model_dataset["split"] == "test")
            & (model_dataset["feature_valid"] == True)  # noqa: E712
        ).sum()
    )

    return {
        "feature_set": "price_ohlc_v1",
        "feature_count": len(PRICE_OHLC_V1_FEATURE_NAMES),
        "feature_names": list(PRICE_OHLC_V1_FEATURE_NAMES),
        "total_rows": total_rows,
        "valid_feature_rows": valid_feature_rows,
        "invalid_feature_rows": invalid_feature_rows,
        "insufficient_history_rows": insufficient,
        "non_contiguous_history_rows": non_contiguous,
        "non_finite_rows": non_finite,
        "train_model_rows": train_model,
        "validation_model_rows": val_model,
        "test_feature_rows": test_features,
    }


def build_and_persist_features(
    *,
    canonical_path: str | Path,
    samples_path: str | Path,
    features_path: str | Path,
    model_dataset_path: str | Path,
    report_path: str | Path,
) -> tuple[pd.DataFrame, pd.DataFrame, dict[str, Any]]:
    """Load inputs, build features, create model dataset, and persist outputs."""
    bars = pd.read_parquet(canonical_path)
    samples = pd.read_parquet(samples_path)

    features = build_price_ohlc_v1_features(bars)
    model_dataset = build_model_dataset(samples, features)
    report = build_feature_report(features, model_dataset)

    features_p = Path(features_path)
    features_p.parent.mkdir(parents=True, exist_ok=True)
    features.to_parquet(features_p, index=False)

    model_p = Path(model_dataset_path)
    model_p.parent.mkdir(parents=True, exist_ok=True)
    model_dataset.to_parquet(model_p, index=False)

    report_p = Path(report_path)
    report_p.parent.mkdir(parents=True, exist_ok=True)
    with report_p.open("w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)

    return features, model_dataset, report


__all__ = [
    "MAX_LAG_BARS",
    "PRICE_OHLC_V1_FEATURE_NAMES",
    "build_and_persist_features",
    "build_feature_report",
    "build_model_dataset",
    "build_price_ohlc_v1_features",
    "get_feature_names",
]
