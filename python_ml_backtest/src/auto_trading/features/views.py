"""Resolved feature-view contracts shared by feature building and Trainer."""

from __future__ import annotations

from dataclasses import dataclass
from types import MappingProxyType
from typing import Mapping

from .price_5m_v1 import PRICE_5M_V1_FEATURE_NAMES
from .price_ohlc_v1 import PRICE_OHLC_V1_FEATURE_NAMES


COARSE_30M_FEATURE_NAMES: tuple[str, ...] = tuple(
    f"c30_{name}" for name in PRICE_OHLC_V1_FEATURE_NAMES
)
B1_COARSE_FEATURE_NAMES = COARSE_30M_FEATURE_NAMES
B1_FINE_FEATURE_NAMES = PRICE_5M_V1_FEATURE_NAMES
MULTIRES_FEATURE_NAMES: tuple[str, ...] = (
    *COARSE_30M_FEATURE_NAMES,
    *PRICE_5M_V1_FEATURE_NAMES,
)
PRICE_MULTIRES_V1_FEATURE_NAMES = MULTIRES_FEATURE_NAMES


@dataclass(frozen=True)
class FeatureView:
    """Small public interface describing a model input view.

    ``feature_names`` is the only model-facing column contract.  Validity and
    group metadata stay here so the shared Trainer does not need to know how a
    particular feature family was built.
    """

    name: str
    feature_set: str
    feature_names: tuple[str, ...]
    groups: Mapping[str, tuple[str, ...]]
    validity_column: str = "feature_valid"
    eligibility_column: str | None = None

    def __post_init__(self) -> None:
        names = tuple(self.feature_names)
        if not names or len(names) != len(set(names)):
            raise ValueError("feature view must contain unique non-empty feature names")
        groups = {
            str(group): tuple(columns)
            for group, columns in self.groups.items()
        }
        grouped = tuple(column for columns in groups.values() for column in columns)
        if set(grouped) != set(names) or len(grouped) != len(names):
            raise ValueError("feature groups must partition feature_names exactly")
        object.__setattr__(self, "feature_names", names)
        object.__setattr__(self, "groups", MappingProxyType(groups))

    @property
    def feature_count(self) -> int:
        """Number of input features in this view."""

        return len(self.feature_names)


def _coarse_view() -> FeatureView:
    return FeatureView(
        name="B1-C",
        feature_set="price_ohlc_v1",
        feature_names=COARSE_30M_FEATURE_NAMES,
        groups=MappingProxyType({"coarse": COARSE_30M_FEATURE_NAMES}),
        eligibility_column="common_eligible",
    )


def _fine_view() -> FeatureView:
    return FeatureView(
        name="B1-F",
        feature_set="price_5m_v1",
        feature_names=PRICE_5M_V1_FEATURE_NAMES,
        groups=MappingProxyType({"fine": PRICE_5M_V1_FEATURE_NAMES}),
        eligibility_column="common_eligible",
    )


def _multires_view() -> FeatureView:
    return FeatureView(
        name="B1-MR",
        feature_set="price_multires_v1",
        feature_names=MULTIRES_FEATURE_NAMES,
        groups=MappingProxyType(
            {
                "coarse": COARSE_30M_FEATURE_NAMES,
                "fine": PRICE_5M_V1_FEATURE_NAMES,
            }
        ),
        eligibility_column="common_eligible",
    )


FEATURE_VIEWS: Mapping[str, FeatureView] = MappingProxyType(
    {
        "coarse": _coarse_view(),
        "fine": _fine_view(),
        "multires": _multires_view(),
    }
)

_ALIASES = {
    "coarse": "coarse",
    "b1-c": "coarse",
    "b1_c": "coarse",
    "price_ohlc_v1": "coarse",
    "price_coarse_30m_v1": "coarse",
    "fine": "fine",
    "b1-f": "fine",
    "b1_f": "fine",
    "price_5m_v1": "fine",
    "multires": "multires",
    "b1-mr": "multires",
    "b1_mr": "multires",
    "price_multires_v1": "multires",
}


def resolve_feature_view(view: str | FeatureView) -> FeatureView:
    """Resolve a stable alias to a shared ``FeatureView`` interface."""

    if isinstance(view, FeatureView):
        return view
    key = str(view).strip().lower()
    try:
        return FEATURE_VIEWS[_ALIASES[key]]
    except KeyError as exc:
        available = ", ".join(sorted(_ALIASES))
        raise ValueError(f"unknown feature view {view!r}; available aliases: {available}") from exc


def prefix_coarse_feature_names(frame):
    """Return a coarse feature frame with the B1 ``c30_`` column contract."""

    rename = {
        original: f"c30_{original}" for original in PRICE_OHLC_V1_FEATURE_NAMES
    }
    return frame.rename(columns=rename)


__all__ = [
    "COARSE_30M_FEATURE_NAMES",
    "B1_COARSE_FEATURE_NAMES",
    "B1_FINE_FEATURE_NAMES",
    "FEATURE_VIEWS",
    "FeatureView",
    "MULTIRES_FEATURE_NAMES",
    "PRICE_MULTIRES_V1_FEATURE_NAMES",
    "PRICE_5M_V1_FEATURE_NAMES",
    "resolve_feature_view",
    "prefix_coarse_feature_names",
]
