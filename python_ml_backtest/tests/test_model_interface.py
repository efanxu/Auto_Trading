from __future__ import annotations

from collections.abc import Sequence
from typing import Any

import pytest

from auto_trading.models import DataInfo, ProbabilityModel, ValidationData


class DummyProbabilityModel(ProbabilityModel):
    """Small framework-neutral implementation used only by this test."""

    def __init__(self) -> None:
        self.fitted = False
        self.validation_seen = False

    def fit(
        self,
        x: Any,
        y: Any,
        *,
        validation: ValidationData | None = None,
    ) -> "DummyProbabilityModel":
        assert len(x) == len(y)
        self.fitted = True
        if validation is not None:
            assert len(validation.x) == len(validation.y)
            self.validation_seen = True
        return self

    def predict_proba(self, x: Sequence[Any]) -> list[float]:
        if not self.fitted:
            raise RuntimeError("dummy model is not fitted")
        return [0.6 for _ in x]


def test_probability_model_can_fit_and_predict_probability() -> None:
    model = DummyProbabilityModel()
    data_info = DataInfo(n_features=2, feature_names=("close", "volume"))

    assert data_info.n_features == 2
    assert model.fit([[1, 2], [3, 4]], [0, 1]) is model
    assert model.predict_proba([[5, 6], [7, 8]]) == pytest.approx([0.6, 0.6])

    val = ValidationData(x=[[9, 10]], y=[1])
    assert model.fit([[1, 2]], [0], validation=val) is model
    assert model.validation_seen is True
