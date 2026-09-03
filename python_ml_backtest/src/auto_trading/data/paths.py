"""Stable local paths for B0 and B1 data artifacts."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class B0DataPaths:
    """Local raw and processed paths used by the public commands.

    The original B0 names remain unchanged.  B1 artifacts are additive so a
    historical B0 run can always be rebuilt from the same canonical files.
    """

    raw_root: Path
    processed_root: Path
    canonical_parquet: Path
    data_report: Path
    samples_parquet: Path
    split_report: Path
    features_parquet: Path
    model_dataset_parquet: Path
    feature_report: Path
    fine_canonical_parquet: Path
    fine_data_report: Path
    fine_features_parquet: Path
    fused_features_parquet: Path
    multires_feature_report: Path
    coarse_model_dataset_parquet: Path
    fine_model_dataset_parquet: Path
    multires_model_dataset_parquet: Path


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
        features_parquet=processed / "btcusdt_index_30m_features.parquet",
        model_dataset_parquet=processed / "btcusdt_index_30m_model_dataset.parquet",
        feature_report=processed / "btcusdt_index_30m_feature_report.json",
        fine_canonical_parquet=processed / "btcusdt_index_5m.parquet",
        fine_data_report=processed / "btcusdt_index_5m_data_report.json",
        fine_features_parquet=processed / "btcusdt_index_5m_features.parquet",
        fused_features_parquet=processed / "btcusdt_index_multires_features.parquet",
        multires_feature_report=processed / "btcusdt_index_multires_feature_report.json",
        coarse_model_dataset_parquet=processed / "btcusdt_index_30m_b1_coarse_model_dataset.parquet",
        fine_model_dataset_parquet=processed / "btcusdt_index_5m_b1_fine_model_dataset.parquet",
        multires_model_dataset_parquet=processed / "btcusdt_index_multires_model_dataset.parquet",
    )


DataPaths = B0DataPaths


__all__ = ["B0DataPaths", "DataPaths", "default_b0_data_paths"]
