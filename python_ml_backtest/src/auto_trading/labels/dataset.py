"""Persistence pipeline for the B0 Event sample dataset."""

from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path
from typing import Any

import pandas as pd

from auto_trading.data.storage import atomic_write_json, atomic_write_parquet
from auto_trading.splits.chronological import chronological_split

from .events import build_event_dataset


def build_persisted_event_dataset(
    *,
    config: Mapping[str, Any],
    canonical_path: str | Path,
    sample_path: str | Path,
    split_report_path: str | Path,
) -> tuple[pd.DataFrame, dict[str, Any]]:
    """Build causal labels, split them, and persist parquet plus split report."""

    bars = pd.read_parquet(canonical_path)
    label_result = build_event_dataset(
        bars,
        interval_minutes=int(config["prediction"]["frequency_minutes"]),
    )
    split_config = config["split"]
    split_result = chronological_split(
        label_result.samples,
        train_ratio=float(split_config["train_ratio"]),
        validation_ratio=float(split_config["validation_ratio"]),
        test_ratio=float(split_config["test_ratio"]),
        purge_minutes=float(split_config["purge_minutes"]),
    )

    samples = split_result.samples
    report = dict(label_result.report)
    report.update(split_result.report)
    report["total_candidate_events"] = label_result.report["total_candidate_events"]
    report["valid_events"] = label_result.report["valid_events"]
    report["invalid_events"] = label_result.report["invalid_events"]
    report["flat_events"] = label_result.report["flat_events"]
    report["invalid_reason_counts"] = label_result.report["invalid_reason_counts"]
    report["source"] = config["data"]["source"]
    report["symbol"] = config["data"]["symbol"]
    report["interval"] = config["data"]["interval"]
    report["start_date"] = str(config["data"]["start_date"])
    report["end_date"] = str(config["data"]["end_date"])
    atomic_write_parquet(samples, sample_path)
    atomic_write_json(report, split_report_path)
    return samples, report


__all__ = ["build_persisted_event_dataset"]
