"""Probability evaluation metrics, reliability calibration tables, and confidence diagnostics."""

from __future__ import annotations

from typing import Any, Sequence

import numpy as np
import pandas as pd
from sklearn.metrics import accuracy_score, brier_score_loss, log_loss, roc_auc_score


def compute_probability_metrics(
    y_true: Sequence[int] | np.ndarray,
    y_prob: Sequence[float] | np.ndarray,
) -> dict[str, Any]:
    """Compute formal out-of-sample probability metrics.

    Args:
        y_true: Ground truth binary labels (0 or 1).
        y_prob: Predicted positive-class probabilities in [0, 1].

    Returns:
        Dictionary of probability metrics.
    """
    y_t = np.asarray(y_true, dtype=int)
    y_p = np.asarray(y_prob, dtype=float)

    if len(y_t) != len(y_p):
        raise ValueError(f"length mismatch: y_true={len(y_t)}, y_prob={len(y_p)}")
    if len(y_t) == 0:
        raise ValueError("cannot compute metrics on empty arrays")

    # Clip probabilities slightly to prevent log(0) in log_loss
    eps = 1e-15
    y_p_clipped = np.clip(y_p, eps, 1.0 - eps)

    # AUC requires both classes to be present
    unique_classes = np.unique(y_t)
    if len(unique_classes) > 1:
        auc = float(roc_auc_score(y_t, y_p))
    else:
        auc = 0.5

    binary_ll = float(log_loss(y_t, y_p_clipped, labels=[0, 1]))
    brier = float(brier_score_loss(y_t, y_p))
    acc_05 = float(accuracy_score(y_t, (y_p >= 0.5).astype(int)))
    pos_rate = float(np.mean(y_t))

    return {
        "n_samples": int(len(y_t)),
        "positive_rate": pos_rate,
        "binary_logloss": binary_ll,
        "brier_score": brier,
        "roc_auc": auc,
        "accuracy_at_0_5": acc_05,
        "probability_mean": float(np.mean(y_p)),
        "probability_std": float(np.std(y_p, ddof=0)),
        "probability_min": float(np.min(y_p)),
        "probability_max": float(np.max(y_p)),
    }


def compute_reliability_table(
    y_true: Sequence[int] | np.ndarray,
    y_prob: Sequence[float] | np.ndarray,
    *,
    n_bins: int = 10,
) -> pd.DataFrame:
    """Compute 10-bin reliability table for probability calibration analysis.

    Bins: [0.0, 0.1), [0.1, 0.2), ..., [0.9, 1.0] (last bin inclusive).
    """
    y_t = np.asarray(y_true, dtype=int)
    y_p = np.asarray(y_prob, dtype=float)

    bins = np.linspace(0.0, 1.0, n_bins + 1)
    records = []

    for i in range(n_bins):
        low = float(bins[i])
        high = float(bins[i + 1])
        if i == n_bins - 1:
            mask = (y_p >= low) & (y_p <= high)
            bin_range = f"[{low:.1f}, {high:.1f}]"
        else:
            mask = (y_p >= low) & (y_p < high)
            bin_range = f"[{low:.1f}, {high:.1f})"

        count = int(np.sum(mask))
        if count > 0:
            mean_prob = float(np.mean(y_p[mask]))
            actual_up = float(np.mean(y_t[mask]))
        else:
            mean_prob = None
            actual_up = None

        records.append(
            {
                "bin_range": bin_range,
                "bin_lower": low,
                "bin_upper": high,
                "count": count,
                "mean_predicted_probability": mean_prob,
                "actual_up_rate": actual_up,
            }
        )

    return pd.DataFrame(records)


def compute_confidence_report(
    y_true: Sequence[int] | np.ndarray,
    y_prob: Sequence[float] | np.ndarray,
    *,
    thresholds: Sequence[float] = (0.55, 0.575, 0.60, 0.625, 0.65, 0.675, 0.70),
) -> pd.DataFrame:
    """Compute confidence diagnostic across directional probability thresholds.

    For each threshold q:
    - Long-confidence: p_up >= q
    - Short-confidence: p_up <= 1 - q
    - Combined: p_up >= q or p_up <= 1 - q
    """
    y_t = np.asarray(y_true, dtype=int)
    y_p = np.asarray(y_prob, dtype=float)

    records = []
    for q in thresholds:
        q_val = float(q)
        long_mask = y_p >= q_val
        short_mask = y_p <= (1.0 - q_val)
        combined_mask = long_mask | short_mask

        long_count = int(np.sum(long_mask))
        long_rate = float(np.mean(y_t[long_mask])) if long_count > 0 else None

        short_count = int(np.sum(short_mask))
        # For short, actual down rate is fraction of y_t == 0
        short_rate = float(np.mean(y_t[short_mask] == 0)) if short_count > 0 else None

        combined_count = int(np.sum(combined_mask))
        if combined_count > 0:
            hits = np.sum((long_mask & (y_t == 1)) | (short_mask & (y_t == 0)))
            combined_hit_rate = float(hits / combined_count)
        else:
            combined_hit_rate = None

        records.append(
            {
                "threshold_q": q_val,
                "long_count": long_count,
                "long_actual_up_rate": long_rate,
                "short_count": short_count,
                "short_actual_down_rate": short_rate,
                "combined_count": combined_count,
                "combined_hit_rate": combined_hit_rate,
            }
        )

    return pd.DataFrame(records)


__all__ = [
    "compute_confidence_report",
    "compute_probability_metrics",
    "compute_reliability_table",
]
