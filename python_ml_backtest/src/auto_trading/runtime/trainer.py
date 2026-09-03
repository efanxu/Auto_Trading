"""Training orchestrator for B0-C LightGBM probability baseline."""

from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
from typing import Any, Mapping

import numpy as np
import pandas as pd
import yaml

from auto_trading.evaluation.probability import (
    compute_confidence_report,
    compute_probability_metrics,
    compute_reliability_table,
)
from auto_trading.features.price_ohlc_v1 import PRICE_OHLC_V1_FEATURE_NAMES
from auto_trading.models.base import DataInfo, ValidationData
from auto_trading.models.loader import build_model


def load_model_config(path: str | Path) -> dict[str, Any]:
    """Load model YAML configuration."""
    model_path = Path(path)
    if not model_path.is_file():
        raise FileNotFoundError(f"model config not found: {model_path}")
    with model_path.open("r", encoding="utf-8") as handle:
        return yaml.safe_load(handle) or {}


def split_train_internal_es(
    train_df: pd.DataFrame,
    *,
    internal_fraction: float = 0.10,
    purge_minutes: float = 30.0,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Split external Train chronologically into Train-fit and Train-ES with boundary purge.

    Train-fit receives (1 - internal_fraction) and Train-ES receives internal_fraction.
    A purge of purge_minutes is applied before the Train-ES start boundary.
    """
    if train_df.empty:
        raise ValueError("cannot split empty train dataframe")

    ordered = train_df.sort_values("prediction_time", kind="mergesort").reset_index(drop=True)
    n = len(ordered)
    es_start_idx = int(n * (1.0 - internal_fraction))
    if es_start_idx <= 0 or es_start_idx >= n:
        raise ValueError(f"invalid internal split index {es_start_idx} for {n} rows")

    es_start_time = pd.Timestamp(ordered.iloc[es_start_idx]["prediction_time"])
    purge_delta = pd.Timedelta(minutes=float(purge_minutes))

    # Pre-ES candidates
    candidates = ordered.iloc[:es_start_idx]
    train_es = ordered.iloc[es_start_idx:].copy().reset_index(drop=True)

    # Purge any row whose prediction_time + purge_delta reaches or exceeds es_start_time
    pred_times = pd.to_datetime(candidates["prediction_time"], utc=True)
    train_fit = candidates[pred_times + purge_delta < es_start_time].copy().reset_index(drop=True)

    if train_fit.empty or train_es.empty:
        raise ValueError("internal early stopping split produced an empty split")

    return train_fit, train_es


def run_training_pipeline(
    *,
    config: Mapping[str, Any],
    model_config_path: str | Path,
    model_dataset_path: str | Path,
    results_root: str | Path,
    model_name: str = "lightgbm",
    run_id: str = "b0c_lightgbm_seed2026",
) -> dict[str, Any]:
    """Run formal B0-C LightGBM probability baseline training.

    1. Load model dataset.
    2. Filter valid train and validation rows (test is SEALED).
    3. Chronological internal ES split on external Train.
    4. Step 1: Fit with early stopping to find best_iteration.
    5. Step 2: Refit formal model on full external Train.
    6. Evaluate out-of-sample probability metrics on Validation.
    7. Persist result artifacts into results/lightgbm/<run_id>/.
    """
    out_dir = Path(results_root) / model_name / run_id
    out_dir.mkdir(parents=True, exist_ok=True)

    # Initial status
    run_info: dict[str, Any] = {
        "status": "RUNNING",
        "model": model_name,
        "run_id": run_id,
        "seed": int(config.get("project", {}).get("seed", 2026)),
        "feature_set": "price_ohlc_v1",
        "feature_count": len(PRICE_OHLC_V1_FEATURE_NAMES),
        "feature_names": list(PRICE_OHLC_V1_FEATURE_NAMES),
        "test_status": "SEALED",
    }
    with (out_dir / "run_info.json").open("w", encoding="utf-8") as handle:
        json.dump(run_info, handle, indent=2)

    try:
        model_cfg = load_model_config(model_config_path)
        ds_path = Path(model_dataset_path)
        if not ds_path.is_file():
            raise FileNotFoundError(f"model dataset not found: {ds_path}")

        dataset = pd.read_parquet(ds_path)
        # Ensure test labels/events are NOT touched for training or evaluation
        valid_mask = (dataset["label_valid"] == True) & (dataset["feature_valid"] == True)  # noqa: E712
        train_full = dataset[(dataset["split"] == "train") & valid_mask].copy()
        val_df = dataset[(dataset["split"] == "validation") & valid_mask].copy()

        train_rows = len(train_full)
        val_rows = len(val_df)
        if train_rows == 0 or val_rows == 0:
            raise ValueError(f"insufficient samples: train={train_rows}, val={val_rows}")

        # Training configuration
        tr_cfg = config.get("training", {})
        es_cfg = tr_cfg.get("early_stopping", {})
        internal_frac = float(es_cfg.get("internal_fraction", 0.10))
        purge_min = float(es_cfg.get("purge_minutes", 30.0))
        stopping_rounds = int(es_cfg.get("stopping_rounds", 100))

        # Internal chronological ES split on external Train
        train_fit, train_es = split_train_internal_es(
            train_full,
            internal_fraction=internal_frac,
            purge_minutes=purge_min,
        )

        data_info = DataInfo(
            n_features=len(PRICE_OHLC_V1_FEATURE_NAMES),
            feature_names=PRICE_OHLC_V1_FEATURE_NAMES,
            target_name="target_up",
            horizon_minutes=30,
        )

        feat_cols = list(PRICE_OHLC_V1_FEATURE_NAMES)
        X_fit = train_fit[feat_cols].to_numpy(dtype=float)
        y_fit = train_fit["target_up"].to_numpy(dtype=int)

        X_es = train_es[feat_cols].to_numpy(dtype=float)
        y_es = train_es["target_up"].to_numpy(dtype=int)

        X_train_full = train_full[feat_cols].to_numpy(dtype=float)
        y_train_full = train_full["target_up"].to_numpy(dtype=int)

        X_val = val_df[feat_cols].to_numpy(dtype=float)
        y_val = val_df["target_up"].to_numpy(dtype=int)

        # Step 1: Find best iteration using Train-fit and Train-ES
        es_model = build_model(model_name, model_cfg, data_info)
        val_container = ValidationData(x=X_es, y=y_es)
        es_model.fit(X_fit, y_fit, validation=val_container, stopping_rounds=stopping_rounds)

        best_iteration = getattr(es_model, "best_iteration", None) or 100
        best_es_loss = getattr(es_model, "best_score", None) or 0.0

        # Step 2: Refit formal model on entire external Train
        formal_cfg = deepcopy(model_cfg)
        inner_cfg = formal_cfg.get("model", formal_cfg)
        inner_cfg["n_estimators"] = int(best_iteration)

        formal_model = build_model(model_name, formal_cfg, data_info)
        formal_model.fit(X_train_full, y_train_full, validation=None)

        # Validation probability evaluation
        probs_val = formal_model.predict_proba(X_val)
        val_metrics = compute_probability_metrics(y_val, probs_val)
        rel_table = compute_reliability_table(y_val, probs_val)
        conf_report = compute_confidence_report(y_val, probs_val)

        # Feature importance
        if hasattr(formal_model, "get_feature_importance"):
            feat_imp = formal_model.get_feature_importance()
        else:
            feat_imp = pd.DataFrame(columns=["feature", "importance_gain", "importance_split"])

        # Persist artifacts
        # 1. model.txt
        if hasattr(formal_model, "save_model"):
            formal_model.save_model(out_dir / "model.txt")

        # 2. resolved_config.yaml & model_config.yaml
        with (out_dir / "resolved_config.yaml").open("w", encoding="utf-8") as handle:
            yaml.safe_dump(dict(config), handle, sort_keys=False)
        with (out_dir / "model_config.yaml").open("w", encoding="utf-8") as handle:
            yaml.safe_dump(dict(model_cfg), handle, sort_keys=False)

        # 3. metrics_validation.json
        with (out_dir / "metrics_validation.json").open("w", encoding="utf-8") as handle:
            json.dump(val_metrics, handle, indent=2)

        # 4. predictions_validation.parquet
        val_preds_df = pd.DataFrame(
            {
                "sample_id": val_df["sample_id"].values,
                "prediction_time": val_df["prediction_time"].values,
                "target_up": y_val,
                "predicted_probability_up": probs_val,
            }
        )
        val_preds_df.to_parquet(out_dir / "predictions_validation.parquet", index=False)

        # 5. reliability_validation.csv & confidence_validation.csv & feature_importance.csv
        rel_table.to_csv(out_dir / "reliability_validation.csv", index=False)
        conf_report.to_csv(out_dir / "confidence_validation.csv", index=False)
        feat_imp.to_csv(out_dir / "feature_importance.csv", index=False)

        # 6. Finalize run_info.json
        run_info.update(
            {
                "status": "COMPLETE",
                "train_rows": train_rows,
                "train_fit_rows": len(train_fit),
                "train_es_rows": len(train_es),
                "validation_rows": val_rows,
                "best_iteration": int(best_iteration),
                "best_internal_es_logloss": float(best_es_loss),
                "validation_metrics": val_metrics,
            }
        )
        with (out_dir / "run_info.json").open("w", encoding="utf-8") as handle:
            json.dump(run_info, handle, indent=2)

        return {
            "run_dir": str(out_dir),
            "run_info": run_info,
            "metrics": val_metrics,
            "best_iteration": best_iteration,
            "best_es_logloss": best_es_loss,
            "feature_importance": feat_imp,
            "confidence_report": conf_report,
            "reliability_table": rel_table,
        }

    except Exception as exc:
        run_info.update({"status": "FAILED", "error": str(exc)})
        with (out_dir / "run_info.json").open("w", encoding="utf-8") as handle:
            json.dump(run_info, handle, indent=2)
        raise


__all__ = [
    "load_model_config",
    "run_training_pipeline",
    "split_train_internal_es",
]
