from __future__ import annotations

import pandas as pd

from auto_trading.labels import (
    build_event_candidates,
    build_event_dataset,
    run_label_causality_check,
)


def make_bars() -> pd.DataFrame:
    opens = pd.date_range("2024-01-01 10:00", periods=4, freq="30min", tz="UTC")
    return pd.DataFrame(
        {
            "open_time": opens,
            "open": [100.0, 101.0, 102.0, 103.0],
            "high": [102.0, 103.0, 103.0, 104.0],
            "low": [99.0, 100.0, 101.0, 102.0],
            "close": [100.5, 102.0, 101.0, 103.5],
            "close_time": opens + pd.Timedelta(minutes=30) - pd.Timedelta(milliseconds=1),
        }
    )


def test_next_bar_event_mapping_has_no_off_by_one() -> None:
    candidates = build_event_candidates(make_bars())

    first = candidates.iloc[0]
    second = candidates.iloc[1]
    assert first["prediction_time"] == pd.Timestamp("2024-01-01 10:29:59.999", tz="UTC")
    assert first["event_entry_time"] == pd.Timestamp("2024-01-01 10:30", tz="UTC")
    assert first["event_entry_price"] == 101.0
    assert first["event_expiry_time"] == pd.Timestamp("2024-01-01 10:59:59.999", tz="UTC")
    assert first["event_expiry_price"] == 102.0
    assert first["target_direction"] == 1
    assert first["target_up"] == 1
    assert bool(first["label_valid"])

    assert second["prediction_time"] == pd.Timestamp("2024-01-01 10:59:59.999", tz="UTC")
    assert second["event_entry_time"] == pd.Timestamp("2024-01-01 11:00", tz="UTC")
    assert second["event_entry_price"] == 102.0
    assert second["event_expiry_time"] == pd.Timestamp("2024-01-01 11:29:59.999", tz="UTC")
    assert second["event_expiry_price"] == 101.0
    assert second["target_direction"] == -1
    assert second["target_up"] == 0
    assert bool(second["label_valid"])

    last = candidates.iloc[-1]
    assert pd.isna(last["event_entry_time"])
    assert last["invalid_reason"] == "missing_next_bar"


def test_flat_event_is_retained_but_not_binary_training_label() -> None:
    bars = make_bars()
    bars.loc[1, "close"] = bars.loc[1, "open"]

    result = build_event_dataset(bars)
    flat = result.candidates.iloc[0]

    assert flat["target_direction"] == 0
    assert pd.isna(flat["target_up"])
    assert not bool(flat["label_valid"])
    assert result.report["flat_events"] == 1


def test_gap_does_not_connect_non_adjacent_bars() -> None:
    bars = make_bars().drop(index=1).reset_index(drop=True)
    candidates = build_event_candidates(bars)

    assert candidates.iloc[0]["invalid_reason"] == "missing_next_bar"
    assert pd.isna(candidates.iloc[0]["event_entry_time"])
    assert candidates.iloc[1]["event_entry_time"] == pd.Timestamp("2024-01-01 11:30", tz="UTC")


def test_label_causality_check_accepts_formal_valid_subset() -> None:
    result = build_event_dataset(make_bars())
    samples = result.samples.iloc[:2].copy()

    report = run_label_causality_check(make_bars(), samples)

    assert report["passed"] is True
    assert report["checked_rows"] == 2


def test_label_causality_check_rejects_wrong_entry_price() -> None:
    result = build_event_dataset(make_bars())
    samples = result.samples.iloc[:2].copy()
    samples.loc[samples.index[0], "event_entry_price"] = 999.0

    report = run_label_causality_check(make_bars(), samples)

    assert report["passed"] is False
    assert any("event_entry_price" in error for error in report["errors"])
