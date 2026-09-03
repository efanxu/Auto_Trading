"""B1 multi-resolution feature construction and common-sample projections."""

from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd

from auto_trading.data.storage import atomic_write_json, atomic_write_parquet

from .price_5m_v1 import PRICE_5M_V1_FEATURE_NAMES, build_price_5m_v1_features
from .price_ohlc_v1 import PRICE_OHLC_V1_FEATURE_NAMES, build_price_ohlc_v1_features
from .views import COARSE_30M_FEATURE_NAMES, MULTIRES_FEATURE_NAMES, FeatureView, resolve_feature_view


SAMPLE_COLUMNS: tuple[str, ...] = (
    "sample_id",
    "prediction_time",
    "split",
    "target_up",
    "label_valid",
)
VALIDITY_COLUMNS: tuple[str, ...] = (
    "coarse_feature_valid",
    "fine_feature_valid",
    "alignment_valid",
    "multires_feature_valid",
    "feature_valid",
    "common_eligible",
)


def build_price_multires_features(
    coarse_bars: pd.DataFrame,
    fine_bars: pd.DataFrame,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """Build coarse, aligned fine, and fused features for every 30m bar."""

    coarse = build_price_ohlc_v1_features(coarse_bars)
    fine = build_price_5m_v1_features(
        fine_bars,
        prediction_times=coarse["prediction_time"],
    )
    fused = _fuse_feature_frames(coarse, fine)
    return coarse, fine, fused


def _fuse_feature_frames(
    coarse: pd.DataFrame,
    fine: pd.DataFrame,
) -> pd.DataFrame:
    if len(coarse) != len(fine):
        raise ValueError(f"coarse/fine row count mismatch: coarse={len(coarse)}, fine={len(fine)}")

    coarse_times = pd.to_datetime(coarse["prediction_time"], utc=True).reset_index(drop=True)
    fine_times = pd.to_datetime(fine["prediction_time"], utc=True).reset_index(drop=True)
    if not coarse_times.equals(fine_times):
        raise ValueError("coarse/fine prediction_time alignment mismatch")

    coarse_renamed = coarse.rename(
        columns={
            **{name: f"c30_{name}" for name in PRICE_OHLC_V1_FEATURE_NAMES},
            "feature_valid": "coarse_feature_valid",
            "feature_invalid_reason": "coarse_feature_invalid_reason",
        }
    )
    fine_renamed = fine.rename(
        columns={
            "feature_valid": "fine_feature_valid",
            "feature_invalid_reason": "fine_feature_invalid_reason",
        }
    )

    fused = pd.DataFrame({"prediction_time": coarse_times})
    fused["coarse_feature_valid"] = coarse_renamed["coarse_feature_valid"].astype(bool).to_numpy()
    fused["fine_feature_valid"] = fine_renamed["fine_feature_valid"].astype(bool).to_numpy()
    fused["alignment_valid"] = fine_renamed.get(
        "alignment_valid",
        pd.Series(True, index=fine_renamed.index),
    ).astype(bool).to_numpy()
    for name in COARSE_30M_FEATURE_NAMES:
        fused[name] = coarse_renamed[name].to_numpy()
    for name in PRICE_5M_V1_FEATURE_NAMES:
        fused[name] = fine_renamed[name].to_numpy()

    multires_valid = (
        fused["coarse_feature_valid"]
        & fused["fine_feature_valid"]
        & fused["alignment_valid"]
    )
    feature_matrix = fused.loc[:, list(MULTIRES_FEATURE_NAMES)].to_numpy(dtype=float)
    finite = np.all(np.isfinite(feature_matrix), axis=1)
    multires_valid &= finite

    reasons: list[str | None] = []
    for index in range(len(fused)):
        if not bool(fused.iloc[index]["alignment_valid"]):
            reason = "alignment_invalid"
        elif not bool(fused.iloc[index]["coarse_feature_valid"]):
            source_reason = coarse_renamed.iloc[index]["coarse_feature_invalid_reason"]
            reason = "non_finite_feature" if source_reason == "non_finite_feature" else "coarse_history_invalid"
        elif not bool(fused.iloc[index]["fine_feature_valid"]):
            source_reason = fine_renamed.iloc[index]["fine_feature_invalid_reason"]
            reason = "non_finite_feature" if source_reason == "non_finite_feature" else "fine_history_invalid"
        elif not bool(finite[index]):
            reason = "non_finite_feature"
        else:
            reason = None
        reasons.append(reason)

    fused["multires_feature_valid"] = multires_valid.astype(bool)
    fused["feature_valid"] = fused["multires_feature_valid"]
    fused["feature_invalid_reason"] = pd.Series(reasons, dtype="object")
    return fused.loc[
        :,
        [
            "prediction_time",
            *COARSE_30M_FEATURE_NAMES,
            *PRICE_5M_V1_FEATURE_NAMES,
            "coarse_feature_valid",
            "fine_feature_valid",
            "alignment_valid",
            "multires_feature_valid",
            "feature_valid",
            "feature_invalid_reason",
        ],
    ]


def build_multires_model_dataset(
    samples: pd.DataFrame,
    fused_features: pd.DataFrame,
) -> pd.DataFrame:
    """Join labels/split metadata to fused features and mark common eligibility."""

    missing_samples = [column for column in SAMPLE_COLUMNS if column not in samples.columns]
    if missing_samples:
        raise ValueError(f"samples missing required columns: {missing_samples}")
    required_features = [
        "prediction_time",
        *MULTIRES_FEATURE_NAMES,
        *VALIDITY_COLUMNS[:-1],
        "feature_invalid_reason",
    ]
    missing_features = [column for column in required_features if column not in fused_features.columns]
    if missing_features:
        raise ValueError(f"fused_features missing required columns: {missing_features}")

    sample_frame = samples.loc[:, list(SAMPLE_COLUMNS)].copy()
    feature_frame = fused_features.loc[:, required_features].copy()
    sample_frame["prediction_time"] = pd.to_datetime(sample_frame["prediction_time"], utc=True)
    feature_frame["prediction_time"] = pd.to_datetime(feature_frame["prediction_time"], utc=True)
    merged = sample_frame.merge(
        feature_frame,
        on="prediction_time",
        how="left",
        sort=False,
        validate="one_to_one",
    )
    if len(merged) != len(sample_frame) or not merged["prediction_time"].equals(sample_frame["prediction_time"]):
        raise ValueError(
            f"alignment mismatch: samples={len(sample_frame)}, merged={len(merged)}"
        )

    bool_columns = [
        "coarse_feature_valid",
        "fine_feature_valid",
        "alignment_valid",
        "multires_feature_valid",
        "feature_valid",
    ]
    for column in bool_columns:
        merged[column] = merged[column].fillna(False).astype(bool)
    merged["common_eligible"] = (
        merged["label_valid"].fillna(False).astype(bool)
        & merged["coarse_feature_valid"]
        & merged["fine_feature_valid"]
        & merged["alignment_valid"]
        & merged["multires_feature_valid"]
    )
    return merged.loc[
        :,
        [
            *SAMPLE_COLUMNS,
            *VALIDITY_COLUMNS,
            "feature_invalid_reason",
            *MULTIRES_FEATURE_NAMES,
        ],
    ]


def project_feature_view_dataset(
    multires_dataset: pd.DataFrame,
    view: str | FeatureView,
) -> pd.DataFrame:
    """Project one common-sample dataset into a B1-C/F/MR input view."""

    resolved = resolve_feature_view(view)
    required = [*SAMPLE_COLUMNS, *VALIDITY_COLUMNS, "feature_invalid_reason", *MULTIRES_FEATURE_NAMES]
    missing = [column for column in required if column not in multires_dataset.columns]
    if missing:
        raise ValueError(f"multires_dataset missing required columns: {missing}")

    result = multires_dataset.loc[
        :,
        [*SAMPLE_COLUMNS, *VALIDITY_COLUMNS, "feature_invalid_reason", *resolved.feature_names],
    ].copy()
    if resolved.name == "B1-C":
        result["feature_valid"] = result["coarse_feature_valid"]
    elif resolved.name == "B1-F":
        result["feature_valid"] = result["fine_feature_valid"] & result["alignment_valid"]
    else:
        result["feature_valid"] = result["multires_feature_valid"]
    return result.loc[
        :,
        [
            *SAMPLE_COLUMNS,
            *VALIDITY_COLUMNS,
            "feature_invalid_reason",
            *resolved.feature_names,
        ],
    ]


def build_b1_feature_report(
    coarse: pd.DataFrame,
    fine: pd.DataFrame,
    fused: pd.DataFrame,
    multires_dataset: pd.DataFrame,
) -> dict[str, Any]:
    """Return counts and fixed schemas for the B1 feature build."""

    def count(frame: pd.DataFrame, column: str) -> int:
        return int(frame[column].fillna(False).astype(bool).sum())

    common = multires_dataset["common_eligible"].astype(bool)
    return {
        "feature_set": "price_multires_v1",
        "coarse_feature_set": "price_ohlc_v1",
        "fine_feature_set": "price_5m_v1",
        "coarse_feature_count": len(COARSE_30M_FEATURE_NAMES),
        "fine_feature_count": len(PRICE_5M_V1_FEATURE_NAMES),
        "multires_feature_count": len(MULTIRES_FEATURE_NAMES),
        "coarse_feature_names": list(COARSE_30M_FEATURE_NAMES),
        "fine_feature_names": list(PRICE_5M_V1_FEATURE_NAMES),
        "multires_feature_names": list(MULTIRES_FEATURE_NAMES),
        "total_prediction_rows": len(fused),
        "coarse_feature_valid_rows": count(coarse, "feature_valid"),
        "fine_feature_valid_rows": count(fine, "feature_valid"),
        "fine_alignment_valid_rows": count(fine, "alignment_valid"),
        "multires_feature_valid_rows": count(fused, "multires_feature_valid"),
        "common_eligible_rows": int(common.sum()),
        "common_eligible_train_rows": int((common & (multires_dataset["split"] == "train")).sum()),
        "common_eligible_validation_rows": int((common & (multires_dataset["split"] == "validation")).sum()),
        "common_eligible_test_rows": int((common & (multires_dataset["split"] == "test")).sum()),
        "invalid_reason_counts": {
            str(key): int(value)
            for key, value in fused["feature_invalid_reason"].value_counts(dropna=True).to_dict().items()
        },
    }


def build_and_persist_multires_features(
    *,
    coarse_path: str | Path,
    fine_path: str | Path,
    samples_path: str | Path,
    coarse_features_path: str | Path,
    fine_features_path: str | Path,
    fused_features_path: str | Path,
    coarse_model_dataset_path: str | Path,
    fine_model_dataset_path: str | Path,
    multires_model_dataset_path: str | Path,
    report_path: str | Path,
) -> dict[str, Any]:
    """Build and persist all B1 views from the shared 30m samples."""

    coarse_bars = pd.read_parquet(coarse_path)
    fine_bars = pd.read_parquet(fine_path)
    samples = pd.read_parquet(samples_path)
    coarse, fine, fused = build_price_multires_features(coarse_bars, fine_bars)
    multires_dataset = build_multires_model_dataset(samples, fused)
    b1_datasets = {
        "coarse": project_feature_view_dataset(multires_dataset, "coarse"),
        "fine": project_feature_view_dataset(multires_dataset, "fine"),
        "multires": project_feature_view_dataset(multires_dataset, "multires"),
    }
    report = build_b1_feature_report(coarse, fine, fused, multires_dataset)

    atomic_write_parquet(coarse, coarse_features_path)
    atomic_write_parquet(fine, fine_features_path)
    atomic_write_parquet(fused, fused_features_path)
    atomic_write_parquet(b1_datasets["coarse"], coarse_model_dataset_path)
    atomic_write_parquet(b1_datasets["fine"], fine_model_dataset_path)
    atomic_write_parquet(b1_datasets["multires"], multires_model_dataset_path)
    atomic_write_json(report, report_path)
    return {
        "coarse_features": coarse,
        "fine_features": fine,
        "fused_features": fused,
        "multires_dataset": multires_dataset,
        "datasets": b1_datasets,
        "report": report,
    }


__all__ = [
    "SAMPLE_COLUMNS",
    "VALIDITY_COLUMNS",
    "build_and_persist_multires_features",
    "build_b1_feature_report",
    "build_multires_model_dataset",
    "build_price_multires_features",
    "project_feature_view_dataset",
]
