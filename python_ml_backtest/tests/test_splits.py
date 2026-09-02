from __future__ import annotations

import pandas as pd
import pytest

from auto_trading.splits import SplitContractError, chronological_split, run_split_check


def make_samples(count: int = 30) -> pd.DataFrame:
    prediction = pd.date_range("2024-01-01", periods=count, freq="30min", tz="UTC")
    return pd.DataFrame(
        {
            "sample_id": [f"sample-{index}" for index in range(count)],
            "prediction_time": prediction,
            "event_entry_time": prediction + pd.Timedelta(minutes=30),
            "event_entry_price": [100.0] * count,
            "event_expiry_time": prediction + pd.Timedelta(minutes=60) - pd.Timedelta(milliseconds=1),
            "event_expiry_price": [101.0] * count,
            "target_direction": [1] * count,
            "target_up": [1] * count,
            "label_valid": [True] * count,
            "invalid_reason": [None] * count,
        }
    )


def test_chronological_split_is_ordered_and_purges_borders() -> None:
    result = chronological_split(make_samples())
    samples = result.samples

    assert result.report["purged_rows"] == 2
    assert samples["prediction_time"].is_monotonic_increasing
    assert list(samples["split"].drop_duplicates()) == ["train", "validation", "test"]
    assert result.report["train_rows"] == 23
    assert result.report["validation_rows"] == 2
    assert result.report["test_rows"] == 3
    assert samples.loc[samples["split"] == "train", "event_expiry_time"].max() < samples.loc[
        samples["split"] == "validation", "event_entry_time"
    ].min()
    assert samples.loc[samples["split"] == "validation", "event_expiry_time"].max() < samples.loc[
        samples["split"] == "test", "event_entry_time"
    ].min()
    assert run_split_check(samples)["passed"] is True


def test_split_has_no_shuffle_and_rejects_bad_ratio() -> None:
    with pytest.raises(SplitContractError, match="sum to 1.0"):
        chronological_split(make_samples(), train_ratio=0.7, validation_ratio=0.2, test_ratio=0.2)

    shuffled = make_samples().sample(frac=1, random_state=3).reset_index(drop=True)
    result = chronological_split(shuffled)
    assert result.samples["prediction_time"].is_monotonic_increasing


def test_split_check_rejects_target_overlap() -> None:
    result = chronological_split(make_samples())
    samples = result.samples.copy()
    validation_index = samples.index[samples["split"] == "validation"][0]
    samples.loc[validation_index, "event_entry_time"] = samples.loc[
        samples["split"] == "train", "event_expiry_time"
    ].max()

    report = run_split_check(samples)

    assert report["passed"] is False
    assert any("overlap" in error for error in report["errors"])
