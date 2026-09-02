"""Framework-neutral probability model contract."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class DataInfo:
    """Minimal metadata a model builder may need to construct a model.

    The metadata intentionally contains no concrete array or framework type,
    so the same contract can be used by tabular and neural models.
    """

    n_features: int | None = None
    feature_names: tuple[str, ...] = field(default_factory=tuple)
    target_name: str = "direction"
    horizon_minutes: int | None = 30

    def __post_init__(self) -> None:
        names = tuple(self.feature_names)
        object.__setattr__(self, "feature_names", names)
        if self.n_features is not None and self.n_features <= 0:
            raise ValueError("n_features must be positive when provided")
        if self.n_features is not None and names and len(names) != self.n_features:
            raise ValueError("feature_names length must match n_features")
        if self.horizon_minutes is not None and self.horizon_minutes <= 0:
            raise ValueError("horizon_minutes must be positive when provided")


class ProbabilityModel(ABC):
    """Common model interface for predicting positive-direction probability."""

    @abstractmethod
    def fit(self, x: Any, y: Any) -> "ProbabilityModel":
        """Fit the model using the supplied training features and labels."""

    @abstractmethod
    def predict_proba(self, x: Any) -> Any:
        """Return ``P(price_(t+30min) > price_t)`` for each input row."""


__all__ = ["DataInfo", "ProbabilityModel"]
