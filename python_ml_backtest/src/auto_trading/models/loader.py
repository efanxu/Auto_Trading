"""Model registry and construction seam.

The registry is intentionally empty until a concrete model is integrated.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from typing import Any

from .base import DataInfo, ProbabilityModel

ModelBuilder = Callable[[Mapping[str, Any], DataInfo], ProbabilityModel]

MODEL_REGISTRY: dict[str, ModelBuilder] = {}


def register_model(model_name: str, builder: ModelBuilder) -> None:
    """Register one model builder for future shared-runtime construction."""

    if not model_name or model_name.strip() != model_name:
        raise ValueError("model_name must be a non-empty name without surrounding whitespace")
    if model_name in MODEL_REGISTRY:
        raise ValueError(f"model already registered: {model_name}")
    MODEL_REGISTRY[model_name] = builder


def _ensure_builtin_models() -> None:
    """Ensure built-in models are registered."""
    if "lightgbm" not in MODEL_REGISTRY:
        from .lightgbm import build_lightgbm_model

        register_model("lightgbm", build_lightgbm_model)


def build_model(
    model_name: str,
    model_config: Mapping[str, Any],
    data_info: DataInfo,
) -> ProbabilityModel:
    """Build a registered model through the one public construction seam."""

    _ensure_builtin_models()
    try:
        builder = MODEL_REGISTRY[model_name]
    except KeyError as exc:
        available = ", ".join(sorted(MODEL_REGISTRY)) or "none"
        raise ValueError(
            f"unknown model '{model_name}'; registered models: {available}"
        ) from exc
    return builder(model_config, data_info)


__all__ = ["MODEL_REGISTRY", "ModelBuilder", "build_model", "register_model"]
