"""Causal feature construction and verification."""

from .price_ohlc_v1 import (
    MAX_LAG_BARS,
    PRICE_OHLC_V1_FEATURE_NAMES,
    build_and_persist_features,
    build_feature_report,
    build_model_dataset,
    build_price_ohlc_v1_features,
    get_feature_names,
)
from .verification import (
    run_all_feature_checks,
    run_feature_alignment_check,
    run_feature_finite_check,
    run_feature_schema_check,
    run_future_mutation_check,
    run_gap_continuity_check,
)

__all__ = [
    "MAX_LAG_BARS",
    "PRICE_OHLC_V1_FEATURE_NAMES",
    "build_and_persist_features",
    "build_feature_report",
    "build_model_dataset",
    "build_price_ohlc_v1_features",
    "get_feature_names",
    "run_all_feature_checks",
    "run_feature_alignment_check",
    "run_feature_finite_check",
    "run_feature_schema_check",
    "run_future_mutation_check",
    "run_gap_continuity_check",
]
