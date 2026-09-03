"""Shared training and Validation evaluation path for B0 and B1 views."""

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
    compute_monthly_validation_diagnostics,
    compute_probability_metrics,
    compute_reliability_table,
)
from auto_trading.features.price_ohlc_v1 import PRICE_OHLC_V1_FEATURE_NAMES
from auto_trading.features.views import FeatureView, resolve_feature_view
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
    """Split external Train chronologically into Train-fit and Train-ES."""

    if train_df.empty:
        raise ValueError("cannot split empty train dataframe")

    ordered = train_df.sort_values("prediction_time", kind="mergesort").reset_index(drop=True)
    n = len(ordered)
    es_start_idx = int(n * (1.0 - internal_fraction))
    if es_start_idx <= 0 or es_start_idx >= n:
        raise ValueError(f"invalid internal split index {es_start_idx} for {n} rows")

    es_start_time = pd.Timestamp(ordered.iloc[es_start_idx]["prediction_time"])
    purge_delta = pd.Timedelta(minutes=float(purge_minutes))
    candidates = ordered.iloc[:es_start_idx]
    train_es = ordered.iloc[es_start_idx:].copy().reset_index(drop=True)
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
    feature_view: str | FeatureView | None = None,
    eligible_column: str | None = None,
) -> dict[str, Any]:
    """Train one view through the shared two-stage, Test-sealed protocol.

    The only view-specific input is ``FeatureView.feature_names`` (and its
    validity/eligibility metadata).  All split, early-stopping, formal refit,
    Validation diagnostics, and artifact persistence remain in this module.
    """

    model_cfg = load_model_config(model_config_path)
    ds_path = Path(model_dataset_path)
    if not ds_path.is_file():
        raise FileNotFoundError(f"model dataset not found: {ds_path}")
    dataset = pd.read_parquet(ds_path)
    view = _resolve_training_view(feature_view, dataset)
    _validate_dataset_for_view(dataset, view)

    out_dir = Path(results_root) / model_name / run_id
    _reject_nonempty_run_directory(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    seed = int(config.get("project", {}).get("seed", 2026))
    run_info: dict[str, Any] = {
        "status": "RUNNING",
        "model": model_name,
        "run_id": run_id,
        "seed": seed,
        "feature_view": view.name,
        "feature_set": view.feature_set,
        "feature_count": view.feature_count,
        "feature_names": list(view.feature_names),
        "test_status": "SEALED",
    }
    _write_json(run_info, out_dir / "run_info.json")

    try:
        validity_column = view.validity_column
        eligibility = eligible_column or view.eligibility_column
        valid = dataset[validity_column].fillna(False).astype(bool)
        if eligibility is not None:
            if eligibility not in dataset.columns:
                raise ValueError(f"dataset missing eligibility column: {eligibility}")
            valid &= dataset[eligibility].fillna(False).astype(bool)

        # Select Train and Validation before touching target_up.  No Test row,
        # target, event outcome, or Test metric is read by the training path.
        train_full = dataset.loc[(dataset["split"] == "train") & valid].copy()
        val_df = dataset.loc[(dataset["split"] == "validation") & valid].copy()
        _validate_binary_targets(train_full, "train")
        _validate_binary_targets(val_df, "validation")
        train_rows = len(train_full)
        val_rows = len(val_df)
        if train_rows == 0 or val_rows == 0:
            raise ValueError(f"insufficient samples: train={train_rows}, val={val_rows}")

        tr_cfg = config.get("training", {})
        es_cfg = tr_cfg.get("early_stopping", {})
        es_enabled = bool(es_cfg.get("enabled", True))
        internal_frac = float(es_cfg.get("internal_fraction", 0.10))
        purge_min = float(es_cfg.get("purge_minutes", 30.0))
        stopping_rounds = int(es_cfg.get("stopping_rounds", 100))

        train_fit, train_es = split_train_internal_es(
            train_full,
            internal_fraction=internal_frac,
            purge_minutes=purge_min,
        )
        data_info = DataInfo(
            n_features=view.feature_count,
            feature_names=view.feature_names,
            target_name="target_up",
            horizon_minutes=30,
        )
        feature_cols = list(view.feature_names)
        X_fit = train_fit[feature_cols].to_numpy(dtype=float)
        y_fit = train_fit["target_up"].to_numpy(dtype=int)
        X_es = train_es[feature_cols].to_numpy(dtype=float)
        y_es = train_es["target_up"].to_numpy(dtype=int)
        X_train_full = train_full[feature_cols].to_numpy(dtype=float)
        y_train_full = train_full["target_up"].to_numpy(dtype=int)
        X_val = val_df[feature_cols].to_numpy(dtype=float)
        y_val = val_df["target_up"].to_numpy(dtype=int)

        # Step 1: determine this view's best iteration using only external
        # Train's chronological Train-fit and Train-ES partitions.
        es_model = build_model(model_name, model_cfg, data_info)
        if es_enabled:
            es_model.fit(
                X_fit,
                y_fit,
                validation=ValidationData(x=X_es, y=y_es),
                stopping_rounds=stopping_rounds,
            )
            best_iteration = int(
                getattr(es_model, "best_iteration", None) or _configured_estimators(model_cfg)
            )
            best_es_loss = float(getattr(es_model, "best_score", None) or 0.0)
        else:
            best_iteration = _configured_estimators(model_cfg)
            best_es_loss = None

        # Step 2: formal refit on all eligible external Train rows.
        formal_cfg = deepcopy(model_cfg)
        formal_inner = formal_cfg["model"] if "model" in formal_cfg else formal_cfg
        formal_inner["n_estimators"] = int(best_iteration)
        formal_inner.setdefault("random_state", seed)
        formal_inner.setdefault("n_jobs", 1)
        formal_model = build_model(model_name, formal_cfg, data_info)
        formal_model.fit(X_train_full, y_train_full, validation=None)

        probs_val = np.asarray(formal_model.predict_proba(X_val), dtype=float)
        val_metrics = compute_probability_metrics(y_val, probs_val)
        rel_table = compute_reliability_table(y_val, probs_val)
        conf_report = compute_confidence_report(y_val, probs_val)
        monthly = compute_monthly_validation_diagnostics(
            val_df["prediction_time"],
            y_val,
            probs_val,
            confidence_threshold=0.55,
        )
        if hasattr(formal_model, "get_feature_importance"):
            feat_imp = formal_model.get_feature_importance()
        else:
            feat_imp = pd.DataFrame(columns=["feature", "importance_gain", "importance_split"])

        if hasattr(formal_model, "save_model"):
            formal_model.save_model(out_dir / "model.txt")
        _write_yaml(dict(config), out_dir / "resolved_config.yaml")
        _write_yaml(dict(model_cfg), out_dir / "model_config.yaml")

        resolved_model_config = deepcopy(formal_cfg)
        resolved_inner = (
            resolved_model_config["model"]
            if "model" in resolved_model_config
            else resolved_model_config
        )
        resolved_inner["n_estimators"] = int(best_iteration)
        resolved_model_config["best_iteration"] = int(best_iteration)
        resolved_model_config["actual_n_estimators"] = int(best_iteration)
        resolved_model_config["seed"] = seed
        resolved_model_config["n_jobs"] = int(resolved_inner.get("n_jobs", 1))
        _write_yaml(resolved_model_config, out_dir / "resolved_model_config.yaml")

        _write_json(val_metrics, out_dir / "metrics_validation.json")
        pd.DataFrame(
            {
                "sample_id": val_df["sample_id"].values,
                "prediction_time": val_df["prediction_time"].values,
                "target_up": y_val,
                "predicted_probability_up": probs_val,
            }
        ).to_parquet(out_dir / "predictions_validation.parquet", index=False)
        rel_table.to_csv(out_dir / "reliability_validation.csv", index=False)
        conf_report.to_csv(out_dir / "confidence_validation.csv", index=False)
        monthly.to_csv(out_dir / "metrics_validation_monthly.csv", index=False)
        feat_imp.to_csv(out_dir / "feature_importance.csv", index=False)
        group_importance = build_feature_group_importance(feat_imp, view)
        _write_json(group_importance, out_dir / "feature_group_importance.json")

        run_info.update(
            {
                "status": "COMPLETE",
                "train_rows": train_rows,
                "train_fit_rows": len(train_fit),
                "train_es_rows": len(train_es),
                "validation_rows": val_rows,
                "best_iteration": int(best_iteration),
                "best_internal_es_logloss": best_es_loss,
                "validation_metrics": val_metrics,
                "eligible_column": eligibility,
            }
        )
        _write_json(run_info, out_dir / "run_info.json")
        return {
            "run_dir": str(out_dir),
            "run_info": run_info,
            "metrics": val_metrics,
            "best_iteration": best_iteration,
            "best_es_logloss": best_es_loss,
            "feature_importance": feat_imp,
            "feature_group_importance": group_importance,
            "confidence_report": conf_report,
            "reliability_table": rel_table,
            "monthly_metrics": monthly,
            "feature_view": view,
        }
    except Exception as exc:
        run_info.update({"status": "FAILED", "error": str(exc)})
        _write_json(run_info, out_dir / "run_info.json")
        raise


def build_feature_group_importance(
    feature_importance: pd.DataFrame,
    view: FeatureView,
) -> dict[str, Any]:
    """Aggregate LightGBM gain by the groups declared by a FeatureView."""

    gains = {
        str(row["feature"]): float(row["importance_gain"])
        for _, row in feature_importance.iterrows()
    }
    group_gain = {
        group: float(sum(gains.get(feature, 0.0) for feature in features))
        for group, features in view.groups.items()
    }
    total_gain = float(sum(group_gain.values()))
    shares = {
        group: (value / total_gain if total_gain else 0.0)
        for group, value in group_gain.items()
    }
    result: dict[str, Any] = {
        "feature_view": view.name,
        "feature_set": view.feature_set,
        "total_gain": total_gain,
        "group_gain": group_gain,
        "group_gain_share": shares,
    }
    if "coarse" in group_gain:
        result["coarse_total_gain"] = group_gain["coarse"]
        result["coarse_gain_share"] = shares["coarse"]
    if "fine" in group_gain:
        result["fine_total_gain"] = group_gain["fine"]
        result["fine_gain_share"] = shares["fine"]
    return result


def _resolve_training_view(
    feature_view: str | FeatureView | None,
    dataset: pd.DataFrame,
) -> FeatureView:
    # The default remains the historical B0-C schema.  This is what keeps the
    # frozen B0 artifact and its exact 34-column contract reproducible.
    if feature_view is None:
        return _legacy_b0_view()
    if isinstance(feature_view, str) and feature_view.strip().lower() == "price_ohlc_v1":
        if set(PRICE_OHLC_V1_FEATURE_NAMES).issubset(dataset.columns):
            return _legacy_b0_view()
    return resolve_feature_view(feature_view)


def _legacy_b0_view() -> FeatureView:
    return FeatureView(
        name="B0-C",
        feature_set="price_ohlc_v1",
        feature_names=PRICE_OHLC_V1_FEATURE_NAMES,
        groups={"coarse": PRICE_OHLC_V1_FEATURE_NAMES},
        validity_column="feature_valid",
        eligibility_column=None,
    )


def _validate_dataset_for_view(dataset: pd.DataFrame, view: FeatureView) -> None:
    required = {"sample_id", "prediction_time", "split", "target_up", view.validity_column, *view.feature_names}
    missing = sorted(required.difference(dataset.columns))
    if missing:
        raise ValueError(f"model dataset missing columns for {view.name}: {missing}")


def _validate_binary_targets(frame: pd.DataFrame, split: str) -> None:
    if frame["target_up"].isna().any():
        raise ValueError(f"{split} contains null target_up rows")
    values = set(frame["target_up"].astype(int).unique())
    if not values.issubset({0, 1}):
        raise ValueError(f"{split} target_up must contain only 0/1")


def _configured_estimators(model_cfg: Mapping[str, Any]) -> int:
    inner = model_cfg.get("model", model_cfg)
    return int(inner.get("n_estimators", 2000))


def _reject_nonempty_run_directory(path: Path) -> None:
    if path.exists() and not path.is_dir():
        raise FileExistsError(f"run output path is not a directory: {path}")
    if path.is_dir() and any(path.iterdir()):
        raise FileExistsError(f"refusing to overwrite non-empty run directory: {path}")


def _write_json(payload: Mapping[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(dict(payload), handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write("\n")


def _write_yaml(payload: Mapping[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        yaml.safe_dump(dict(payload), handle, sort_keys=False)


__all__ = [
    "build_feature_group_importance",
    "load_model_config",
    "run_training_pipeline",
    "split_train_internal_es",
]
