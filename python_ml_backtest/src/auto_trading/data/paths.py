"""Stable local paths for B0 data artifacts."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class B0DataPaths:
    """Local raw and processed paths used by the public commands."""

    raw_root: Path
    processed_root: Path
    canonical_parquet: Path
    data_report: Path
    samples_parquet: Path
    split_report: Path


def default_b0_data_paths(workspace_root: str | Path) -> B0DataPaths:
    """Resolve B0 paths relative to the Python workspace root."""

    root = Path(workspace_root)
    processed = root / "data" / "processed"
    return B0DataPaths(
        raw_root=root / "data" / "raw" / "binance",
        processed_root=processed,
        canonical_parquet=processed / "btcusdt_index_30m.parquet",
        data_report=processed / "btcusdt_index_30m_data_report.json",
        samples_parquet=processed / "btcusdt_index_30m_samples.parquet",
        split_report=processed / "btcusdt_index_30m_split_report.json",
    )


__all__ = ["B0DataPaths", "default_b0_data_paths"]
