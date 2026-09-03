"""Tests for probability evaluation metrics, reliability calibration tables, and confidence diagnostics."""

from __future__ import annotations

import numpy as np
import pytest

from auto_trading.evaluation import (
    compute_confidence_report,
    compute_probability_metrics,
    compute_reliability_table,
)


def test_probability_metrics_values() -> None:
    y_true = [1, 0, 1, 0]
    y_prob = [0.9, 0.1, 0.8, 0.2]

    metrics = compute_probability_metrics(y_true, y_prob)

    assert metrics["n_samples"] == 4
    assert metrics["positive_rate"] == 0.5
    assert metrics["accuracy_at_0_5"] == 1.0
    assert metrics["roc_auc"] == 1.0
    # Expected brier: ((0.9-1)^2 + (0.1-0)^2 + (0.8-1)^2 + (0.2-0)^2) / 4 = (0.01 + 0.01 + 0.04 + 0.04) / 4 = 0.025
    assert metrics["brier_score"] == pytest.approx(0.025, rel=1e-5)
    assert metrics["probability_mean"] == pytest.approx(0.5, rel=1e-5)
    assert metrics["probability_min"] == 0.1
    assert metrics["probability_max"] == 0.9


def test_reliability_table_10_bins() -> None:
    # 10 samples spread across bins
    y_true = [0, 0, 1, 0, 1, 1, 0, 1, 1, 1]
    y_prob = [0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95]

    df = compute_reliability_table(y_true, y_prob, n_bins=10)

    assert len(df) == 10
    assert list(df.columns) == [
        "bin_range",
        "bin_lower",
        "bin_upper",
        "count",
        "mean_predicted_probability",
        "actual_up_rate",
    ]
    # Each bin should have exactly 1 count
    assert (df["count"] == 1).all()
    assert df.loc[0, "bin_range"] == "[0.0, 0.1)"
    assert df.loc[9, "bin_range"] == "[0.9, 1.0]"


def test_confidence_report_structure_and_logic() -> None:
    y_true = [1, 1, 0, 0, 1, 0]
    y_prob = [0.75, 0.65, 0.25, 0.35, 0.52, 0.48]

    report = compute_confidence_report(y_true, y_prob, thresholds=(0.60, 0.70))

    assert len(report) == 2
    assert list(report.columns) == [
        "threshold_q",
        "long_count",
        "long_actual_up_rate",
        "short_count",
        "short_actual_down_rate",
        "combined_count",
        "combined_hit_rate",
    ]

    # For q=0.70:
    # Long: p >= 0.70 -> [0.75] (y=1) -> count 1, rate 1.0
    # Short: p <= 0.30 -> [0.25] (y=0) -> count 1, down_rate 1.0
    # Combined: count 2, hit rate 1.0
    row_70 = report[report["threshold_q"] == 0.70].iloc[0]
    assert row_70["long_count"] == 1
    assert row_70["long_actual_up_rate"] == 1.0
    assert row_70["short_count"] == 1
    assert row_70["short_actual_down_rate"] == 1.0
    assert row_70["combined_count"] == 2
    assert row_70["combined_hit_rate"] == 1.0
