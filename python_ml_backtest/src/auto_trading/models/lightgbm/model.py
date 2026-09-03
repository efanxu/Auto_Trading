"""LightGBM probability baseline model implementation."""

from __future__ import annotations

from collections.abc import Mapping
from copy import deepcopy
from pathlib import Path
from typing import Any

import warnings

import lightgbm as lgb
import numpy as np
import pandas as pd

from auto_trading.models.base import DataInfo, ProbabilityModel, ValidationData


class LightGBMProbabilityModel(ProbabilityModel):
    """LightGBM model predicting positive direction probability P(next_bar_close > next_bar_open)."""

    def __init__(
        self,
        model_config: Mapping[str, Any],
        data_info: DataInfo,
    ) -> None:
        self.model_config = deepcopy(dict(model_config))
        self.data_info = data_info
        self.feature_names = list(data_info.feature_names) if data_info.feature_names else None

        cfg = self.model_config.get("model", self.model_config)
        self.params: dict[str, Any] = {
            "objective": cfg.get("objective", "binary"),
            "boosting_type": cfg.get("boosting_type", "gbdt"),
            "learning_rate": float(cfg.get("learning_rate", 0.03)),
            "num_leaves": int(cfg.get("num_leaves", 31)),
            "max_depth": int(cfg.get("max_depth", -1)),
            "min_child_samples": int(cfg.get("min_child_samples", 100)),
            "subsample": float(cfg.get("subsample", 0.8)),
            "subsample_freq": int(cfg.get("subsample_freq", 1)),
            "colsample_bytree": float(cfg.get("colsample_bytree", 0.8)),
            "reg_alpha": float(cfg.get("reg_alpha", 0.0)),
            "reg_lambda": float(cfg.get("reg_lambda", 1.0)),
            "n_estimators": int(cfg.get("n_estimators", 2000)),
            "deterministic": bool(cfg.get("deterministic", True)),
            "force_col_wise": bool(cfg.get("force_col_wise", True)),
            "random_state": int(cfg.get("random_state", 2026)),
            "verbosity": int(cfg.get("verbosity", -1)),
            "n_jobs": int(cfg.get("n_jobs", 1)),
        }

        self.classifier: lgb.LGBMClassifier | None = None
        self.best_iteration: int | None = None
        self.best_score: float | None = None

    def fit(
        self,
        x: Any,
        y: Any,
        *,
        validation: ValidationData | None = None,
        stopping_rounds: int = 100,
    ) -> "LightGBMProbabilityModel":
        """Fit the LightGBM classifier.

        If ``validation`` is provided, early stopping is applied.
        """
        if isinstance(x, pd.DataFrame):
            x_train = x
        elif self.feature_names is not None:
            x_train = pd.DataFrame(x, columns=self.feature_names)
        else:
            x_train = np.asarray(x, dtype=float)
        y_train = np.asarray(y, dtype=int)

        self.classifier = lgb.LGBMClassifier(**self.params)

        callbacks: list[Any] = []
        eval_set: list[tuple[Any, Any]] | None = None

        if validation is not None:
            if isinstance(validation.x, pd.DataFrame):
                x_val = validation.x
            elif self.feature_names is not None:
                x_val = pd.DataFrame(validation.x, columns=self.feature_names)
            else:
                x_val = np.asarray(validation.x, dtype=float)
            y_val = np.asarray(validation.y, dtype=int)
            eval_set = [(x_val, y_val)]
            callbacks.append(lgb.early_stopping(stopping_rounds=stopping_rounds, verbose=False))

        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            self.classifier.fit(
                x_train,
                y_train,
                eval_set=eval_set,
                eval_metric="binary_logloss",
                callbacks=callbacks if callbacks else None,
            )

        if validation is not None:
            self.best_iteration = int(self.classifier.best_iteration_)
            val_scores = self.classifier.best_score_.get("valid_0", {})
            self.best_score = float(val_scores.get("binary_logloss", 0.0))
        else:
            self.best_iteration = int(self.params["n_estimators"])
            self.best_score = None

        return self

    def predict_proba(self, x: Any) -> np.ndarray:
        """Return P(next_bar_close > next_bar_open) for each input row."""
        if self.classifier is None:
            raise RuntimeError("model is not fitted")

        if isinstance(x, pd.DataFrame):
            x_arr = x
        elif self.feature_names is not None:
            x_arr = pd.DataFrame(x, columns=self.feature_names)
        else:
            x_arr = np.asarray(x, dtype=float)
        probas = self.classifier.predict_proba(x_arr)
        return probas[:, 1]

    def get_feature_importance(self) -> pd.DataFrame:
        """Return feature importance sorted by gain descending."""
        if self.classifier is None:
            raise RuntimeError("model is not fitted")

        booster = self.classifier.booster_
        gain = booster.feature_importance(importance_type="gain")
        split = booster.feature_importance(importance_type="split")

        names = self.feature_names
        if names is None or len(names) != len(gain):
            names = booster.feature_name()

        df = pd.DataFrame(
            {
                "feature": names,
                "importance_gain": gain,
                "importance_split": split,
            }
        )
        return df.sort_values("importance_gain", ascending=False).reset_index(drop=True)

    def save_model(self, path: str | Path) -> None:
        """Persist model booster to text file."""
        if self.classifier is None:
            raise RuntimeError("model is not fitted")
        save_p = Path(path)
        save_p.parent.mkdir(parents=True, exist_ok=True)
        self.classifier.booster_.save_model(str(save_p))


def build_lightgbm_model(
    model_config: Mapping[str, Any],
    data_info: DataInfo,
) -> LightGBMProbabilityModel:
    """Public constructor for LightGBM model."""
    return LightGBMProbabilityModel(model_config=model_config, data_info=data_info)


__all__ = ["LightGBMProbabilityModel", "build_lightgbm_model"]
