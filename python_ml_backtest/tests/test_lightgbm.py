"""Tests for LightGBM model integration, early stopping, and test set sealing."""

from __future__ import annotations

from pathlib import Path
import numpy as np
import pandas as pd
import pytest

from auto_trading.models import DataInfo, ValidationData, build_model
from auto_trading.runtime.trainer import (
    load_model_config,
    run_training_pipeline,
    split_train_internal_es,
)


@pytest.fixture
def small_lgb_config() -> dict:
    return {
        "model": {
            "objective": "binary",
            "boosting_type": "gbdt",
            "learning_rate": 0.1,
            "num_leaves": 7,
            "max_depth": 3,
            "min_child_samples": 5,
            "subsample": 1.0,
            "colsample_bytree": 1.0,
            "n_estimators": 50,
            "deterministic": True,
            "force_col_wise": True,
            "random_state": 42,
            "verbosity": -1,
            "n_jobs": 1,
        }
    }


def test_lightgbm_build_and_predict(small_lgb_config: dict) -> None:
    n_features = 4
    feature_names = ("f1", "f2", "f3", "f4")
    data_info = DataInfo(n_features=n_features, feature_names=feature_names)

    model = build_model("lightgbm", small_lgb_config, data_info)

    np.random.seed(42)
    x = np.random.randn(50, n_features)
    y = (x[:, 0] + x[:, 1] > 0).astype(int)

    model.fit(x, y)
    probs = model.predict_proba(x)

    assert len(probs) == 50
    assert np.all(probs >= 0.0)
    assert np.all(probs <= 1.0)

    # Feature importance check
    imp = model.get_feature_importance()
    assert len(imp) == n_features
    assert list(imp.columns) == ["feature", "importance_gain", "importance_split"]


def test_lightgbm_early_stopping(small_lgb_config: dict) -> None:
    n_features = 4
    feature_names = ("f1", "f2", "f3", "f4")
    data_info = DataInfo(n_features=n_features, feature_names=feature_names)

    model = build_model("lightgbm", small_lgb_config, data_info)

    np.random.seed(42)
    x_train = np.random.randn(80, n_features)
    y_train = (x_train[:, 0] > 0).astype(int)
    x_val = np.random.randn(20, n_features)
    y_val = (x_val[:, 0] > 0).astype(int)

    val_data = ValidationData(x=x_val, y=y_val)
    model.fit(x_train, y_train, validation=val_data, stopping_rounds=10)

    assert model.best_iteration is not None
    assert 1 <= model.best_iteration <= 50
    assert model.best_score is not None
    assert model.best_score > 0.0


def test_split_train_internal_es_chronological_and_purged() -> None:
    n = 100
    start = pd.Timestamp("2024-01-01 00:00:00", tz="UTC")
    pred_times = [start + pd.Timedelta(minutes=30 * i) for i in range(n)]

    df = pd.DataFrame(
        {
            "prediction_time": pred_times,
            "target_up": [1] * 50 + [0] * 50,
            "label_valid": [True] * n,
            "feature_valid": [True] * n,
        }
    )

    train_fit, train_es = split_train_internal_es(
        df, internal_fraction=0.10, purge_minutes=30.0
    )

    # 10% of 100 = 10 rows for ES (indices 90..99)
    assert len(train_es) == 10
    # Boundary is at index 90. Row 89 has prediction_time + 30m == boundary -> purged!
    # Rows 0..88 = 89 rows for train_fit
    assert len(train_fit) == 89

    max_fit_pred = pd.Timestamp(train_fit["prediction_time"].max())
    min_es_pred = pd.Timestamp(train_es["prediction_time"].min())
    assert max_fit_pred + pd.Timedelta(minutes=30) <= min_es_pred


def test_test_set_sealed_in_pipeline(tmp_path: Path, small_lgb_config: dict) -> None:
    """Verify that training and evaluation never touch split == 'test'."""
    from auto_trading.features.price_ohlc_v1 import PRICE_OHLC_V1_FEATURE_NAMES
    import yaml

    model_cfg_file = tmp_path / "lightgbm.yaml"
    with model_cfg_file.open("w") as h:
        yaml.safe_dump(small_lgb_config, h)

    # Build dummy dataset
    n = 150
    start = pd.Timestamp("2024-01-01 00:00:00", tz="UTC")
    pred_times = [start + pd.Timedelta(minutes=30 * i) for i in range(n)]

    splits = ["train"] * 100 + ["validation"] * 30 + ["test"] * 20
    data = {
        "sample_id": [f"s-{i}" for i in range(n)],
        "prediction_time": pred_times,
        "split": splits,
        "target_up": [i % 2 for i in range(n)],
        "label_valid": [True] * n,
        "feature_valid": [True] * n,
    }
    for f in PRICE_OHLC_V1_FEATURE_NAMES:
        data[f] = np.random.randn(n)

    ds_file = tmp_path / "model_dataset.parquet"
    pd.DataFrame(data).to_parquet(ds_file, index=False)

    exp_config = {
        "project": {"seed": 42},
        "training": {
            "early_stopping": {
                "enabled": True,
                "internal_fraction": 0.10,
                "purge_minutes": 30,
                "stopping_rounds": 10,
                "metric": "binary_logloss",
            }
        },
    }

    result = run_training_pipeline(
        config=exp_config,
        model_config_path=model_cfg_file,
        model_dataset_path=ds_file,
        results_root=tmp_path / "results",
        model_name="lightgbm",
        run_id="test_run",
    )

    run_info = result["run_info"]
    assert run_info["status"] == "COMPLETE"
    assert run_info["test_status"] == "SEALED"
    assert run_info["train_rows"] == 100
    assert run_info["validation_rows"] == 30

    out_dir = Path(result["run_dir"])
    assert (out_dir / "metrics_validation.json").is_file()
    assert (out_dir / "predictions_validation.parquet").is_file()
    assert not (out_dir / "metrics_test.json").exists()
    assert not (out_dir / "predictions_test.parquet").exists()
