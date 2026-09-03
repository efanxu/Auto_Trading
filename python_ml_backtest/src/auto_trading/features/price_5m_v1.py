"""Causal 5-minute price features for the B1 multi-resolution view.

The implementation computes a feature row for every completed 5-minute bar.
Callers may pass coarse prediction times to select the exact completed fine bar
that is visible at each 30-minute decision time.  No forward/backward filling
is performed; a missing exact alignment is explicitly marked invalid.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

import numpy as np
import pandas as pd


PRICE_5M_V1_FEATURE_NAMES: tuple[str, ...] = (
    # Log return (8)
    "f5_ret_1",
    "f5_ret_3",
    "f5_ret_6",
    "f5_ret_12",
    "f5_ret_24",
    "f5_ret_48",
    "f5_ret_144",
    "f5_ret_288",
    # Realized volatility (5)
    "f5_vol_6",
    "f5_vol_12",
    "f5_vol_24",
    "f5_vol_48",
    "f5_vol_288",
    # Finite-window SMA trend (3)
    "f5_sma_gap_6_24",
    "f5_sma_gap_12_48",
    "f5_sma_gap_48_288",
    # Close z-score (4)
    "f5_zscore_6",
    "f5_zscore_24",
    "f5_zscore_48",
    "f5_zscore_288",
    # Current candle structure (5)
    "f5_range_pct",
    "f5_body_pct",
    "f5_upper_wick_pct",
    "f5_lower_wick_pct",
    "f5_close_location",
    # Rolling range position (8)
    "f5_rolling_high_distance_6",
    "f5_rolling_high_distance_24",
    "f5_rolling_high_distance_48",
    "f5_rolling_high_distance_288",
    "f5_rolling_low_distance_6",
    "f5_rolling_low_distance_24",
    "f5_rolling_low_distance_48",
    "f5_rolling_low_distance_288",
    # ATR-like normalized range (4)
    "f5_atr_pct_6",
    "f5_atr_pct_24",
    "f5_atr_pct_48",
    "f5_atr_pct_288",
    # Recent 30-minute path (8)
    "f5_up_ratio_6",
    "f5_sign_change_rate_6",
    "f5_abs_return_sum_6",
    "f5_max_return_6",
    "f5_min_return_6",
    "f5_path_efficiency_6",
    "f5_high_recency_6",
    "f5_low_recency_6",
    # UTC calendar (4)
    "f5_time_of_day_sin",
    "f5_time_of_day_cos",
    "f5_day_of_week_sin",
    "f5_day_of_week_cos",
)

FINE_MAX_LAG_BARS: int = 288
FINE_PATH_WINDOW_BARS: int = 6
_REQUIRED_COLUMNS: tuple[str, ...] = (
    "open_time",
    "open",
    "high",
    "low",
    "close",
    "close_time",
)


def get_feature_names() -> tuple[str, ...]:
    """Return the official ordered 49-feature contract."""

    return PRICE_5M_V1_FEATURE_NAMES


get_fine_feature_names = get_feature_names


def build_price_5m_v1_features(
    fine_bars: pd.DataFrame,
    *,
    prediction_times: Sequence[Any] | pd.Series | None = None,
) -> pd.DataFrame:
    """Build causal 5m features and optionally align them to coarse decisions.

    When ``prediction_times`` is omitted, one row is returned for every fine
    bar and ``prediction_time`` is that bar's ``close_time``.  When supplied,
    one row is returned for every requested prediction time.  The exact fine
    bar with ``close_time == prediction_time`` must exist; otherwise the row is
    marked ``alignment_invalid`` and all feature values remain null.

    A maximum lag of 288 means the first 288 rows are warm-up rows.  After a
    real gap, another 288 consecutive five-minute steps are required before a
    row becomes valid.
    """

    missing = [column for column in _REQUIRED_COLUMNS if column not in fine_bars.columns]
    if missing:
        raise ValueError(f"fine_bars missing required columns: {missing}")

    if fine_bars.empty:
        empty_columns = ["prediction_time", *PRICE_5M_V1_FEATURE_NAMES, "feature_valid", "feature_invalid_reason"]
        return pd.DataFrame(columns=empty_columns)

    ordered = fine_bars.sort_values("open_time", kind="mergesort").reset_index(drop=True)
    open_p = ordered["open"].astype(float)
    high_p = ordered["high"].astype(float)
    low_p = ordered["low"].astype(float)
    close_p = ordered["close"].astype(float)
    open_t = pd.to_datetime(ordered["open_time"], utc=True)
    close_t = pd.to_datetime(ordered["close_time"], utc=True)

    log_c = np.log(close_p)
    one_step_return = log_c - log_c.shift(1)
    values: dict[str, Any] = {}

    # A. Log returns.
    for k in (1, 3, 6, 12, 24, 48, 144, 288):
        values[f"f5_ret_{k}"] = log_c - log_c.shift(k)

    # B. Realized volatility, ddof=0.
    for k in (6, 12, 24, 48, 288):
        values[f"f5_vol_{k}"] = one_step_return.rolling(k).std(ddof=0)

    # C. Finite-window SMA gaps.
    for short, long in ((6, 24), (12, 48), (48, 288)):
        values[f"f5_sma_gap_{short}_{long}"] = (
            close_p.rolling(short).mean() / close_p.rolling(long).mean() - 1.0
        )

    # D. Close z-scores, ddof=0 and zero when the rolling standard deviation is
    # zero.  Warm-up NaN values are retained until the final validity pass.
    for k in (6, 24, 48, 288):
        mean = close_p.rolling(k).mean()
        std = close_p.rolling(k).std(ddof=0)
        z_score = np.where(std > 1e-12, (close_p - mean) / std, 0.0)
        z_score = np.where(std.isna(), np.nan, z_score)
        values[f"f5_zscore_{k}"] = z_score

    # E. Current candle structure; formulas intentionally match price_ohlc_v1.
    range_value = high_p - low_p
    values["f5_range_pct"] = range_value / close_p
    values["f5_body_pct"] = (close_p - open_p) / open_p
    values["f5_upper_wick_pct"] = (high_p - np.maximum(open_p, close_p)) / close_p
    values["f5_lower_wick_pct"] = (np.minimum(open_p, close_p) - low_p) / close_p
    values["f5_close_location"] = np.where(
        range_value > 1e-12,
        (close_p - low_p) / range_value,
        0.5,
    )

    # F. Rolling high/low distances.
    for k in (6, 24, 48, 288):
        rolling_high = high_p.rolling(k).max()
        rolling_low = low_p.rolling(k).min()
        values[f"f5_rolling_high_distance_{k}"] = close_p / rolling_high - 1.0
        values[f"f5_rolling_low_distance_{k}"] = close_p / rolling_low - 1.0

    # G. ATR-like normalized true range.
    previous_close = close_p.shift(1)
    true_range = np.maximum(
        high_p - low_p,
        np.maximum((high_p - previous_close).abs(), (low_p - previous_close).abs()),
    )
    for k in (6, 24, 48, 288):
        values[f"f5_atr_pct_{k}"] = true_range.rolling(k).mean() / close_p

    # H. Six-bar internal 30-minute path.
    recent_returns = one_step_return.rolling(FINE_PATH_WINDOW_BARS)
    values["f5_up_ratio_6"] = one_step_return.gt(0).rolling(FINE_PATH_WINDOW_BARS).mean()
    signs = np.sign(one_step_return)
    sign_change = (
        signs.ne(signs.shift(1))
        & signs.ne(0)
        & signs.shift(1).ne(0)
    ).astype(float)
    # Six returns contain five adjacent transitions.
    values["f5_sign_change_rate_6"] = (
        sign_change.rolling(FINE_PATH_WINDOW_BARS - 1).sum()
        / float(FINE_PATH_WINDOW_BARS - 1)
    )
    abs_sum = one_step_return.abs().rolling(FINE_PATH_WINDOW_BARS).sum()
    signed_sum = recent_returns.sum()
    values["f5_abs_return_sum_6"] = abs_sum
    values["f5_max_return_6"] = recent_returns.max()
    values["f5_min_return_6"] = recent_returns.min()
    values["f5_path_efficiency_6"] = np.where(
        abs_sum > 1e-15,
        signed_sum.abs() / abs_sum,
        0.0,
    )
    values["f5_high_recency_6"] = high_p.rolling(FINE_PATH_WINDOW_BARS).apply(
        _first_extreme_recency,
        raw=True,
    )
    values["f5_low_recency_6"] = low_p.rolling(FINE_PATH_WINDOW_BARS).apply(
        _first_extreme_recency,
        raw=True,
        args=(True,),
    )

    # I. Calendar values are the completed-bar UTC prediction time for the
    # unaligned view, and become the requested coarse prediction time below.
    values.update(_calendar_features(close_t))

    feature_frame = pd.DataFrame(values, columns=list(PRICE_5M_V1_FEATURE_NAMES))

    # A row is valid only if its required 288 historical steps are contiguous.
    step_is_5m = open_t.diff() == pd.Timedelta(minutes=5)
    contiguous_288 = step_is_5m.rolling(FINE_MAX_LAG_BARS).sum() == FINE_MAX_LAG_BARS
    valid = np.zeros(len(ordered), dtype=bool)
    reasons = pd.Series([None] * len(ordered), dtype="object")
    for index in range(len(ordered)):
        if index < FINE_MAX_LAG_BARS:
            reasons.iloc[index] = "insufficient_history"
            continue
        if not bool(contiguous_288.iloc[index]):
            reasons.iloc[index] = "non_contiguous_history"
            continue
        row_values = feature_frame.iloc[index].to_numpy(dtype=float)
        if not np.all(np.isfinite(row_values)):
            reasons.iloc[index] = "non_finite_feature"
            continue
        valid[index] = True

    all_features = pd.DataFrame(
        {
            "prediction_time": close_t,
            **{name: feature_frame[name] for name in PRICE_5M_V1_FEATURE_NAMES},
            "feature_valid": valid,
            "feature_invalid_reason": reasons,
        }
    )

    if prediction_times is None:
        return all_features
    return _align_to_prediction_times(all_features, prediction_times)


def _align_to_prediction_times(
    all_features: pd.DataFrame,
    prediction_times: Sequence[Any] | pd.Series,
) -> pd.DataFrame:
    requested = pd.Series(prediction_times, copy=True).reset_index(drop=True)
    requested = pd.to_datetime(requested, utc=True)
    lookup = all_features.copy()
    lookup["prediction_time"] = pd.to_datetime(lookup["prediction_time"], utc=True)
    lookup = lookup.drop_duplicates("prediction_time", keep="first").set_index("prediction_time")

    result = lookup.reindex(requested).reset_index().rename(columns={"index": "prediction_time"})
    result["prediction_time"] = requested
    result["alignment_valid"] = result["feature_valid"].notna()
    result.loc[~result["alignment_valid"], "feature_valid"] = False
    result.loc[~result["alignment_valid"], "feature_invalid_reason"] = "alignment_invalid"
    result = result.loc[
        :,
        [
            "prediction_time",
            *PRICE_5M_V1_FEATURE_NAMES,
            "feature_valid",
            "feature_invalid_reason",
            "alignment_valid",
        ],
    ]
    return result


def _calendar_features(close_times: pd.Series) -> dict[str, pd.Series]:
    minute_of_day = close_times.dt.hour * 60 + close_times.dt.minute
    theta_day = 2.0 * np.pi * minute_of_day / 1440.0
    theta_week = 2.0 * np.pi * close_times.dt.dayofweek / 7.0
    return {
        "f5_time_of_day_sin": np.sin(theta_day),
        "f5_time_of_day_cos": np.cos(theta_day),
        "f5_day_of_week_sin": np.sin(theta_week),
        "f5_day_of_week_cos": np.cos(theta_week),
    }


def _first_extreme_recency(values: np.ndarray, low: bool = False) -> float:
    if len(values) <= 1 or not np.all(np.isfinite(values)):
        return np.nan
    extreme = np.min(values) if low else np.max(values)
    positions = np.flatnonzero(values == extreme)
    if len(positions) == 0:
        return np.nan
    return float(positions[0]) / float(len(values) - 1)


__all__ = [
    "FINE_MAX_LAG_BARS",
    "FINE_PATH_WINDOW_BARS",
    "PRICE_5M_V1_FEATURE_NAMES",
    "build_price_5m_v1_features",
    "get_fine_feature_names",
    "get_feature_names",
]
