"""Fixed-stake Event Contract payout math."""

from __future__ import annotations

from dataclasses import dataclass
from math import isfinite
from typing import Any


@dataclass(frozen=True)
class EventPayout:
    """Resolved net payout values for one fixed-stake Event Contract."""

    stake_usdt: float
    winning_total_return_usdt: float

    @property
    def win_net_profit(self) -> float:
        """Net profit for a winning event."""

        return self.winning_total_return_usdt - self.stake_usdt

    @property
    def loss_net_profit(self) -> float:
        """Net profit for a losing event."""

        return -self.stake_usdt

    @property
    def break_even_win_rate(self) -> float:
        """Win rate at which expected net profit is zero."""

        return self.stake_usdt / self.winning_total_return_usdt

    def as_dict(self) -> dict[str, float]:
        """Return the payout values used by resolved configuration and reports."""

        return {
            "stake_usdt": self.stake_usdt,
            "winning_total_return_usdt": self.winning_total_return_usdt,
            "win_net_profit": self.win_net_profit,
            "loss_net_profit": self.loss_net_profit,
            "break_even_win_rate": self.break_even_win_rate,
        }


def calculate_event_payout(
    stake_usdt: Any,
    winning_total_return_usdt: Any,
) -> EventPayout:
    """Calculate the fixed-stake Event Contract payout."""

    stake = _finite_number(stake_usdt, "event.stake_usdt")
    winning_return = _finite_number(
        winning_total_return_usdt,
        "event.winning_total_return_usdt",
    )
    if stake <= 0:
        raise ValueError("event.stake_usdt must be > 0")
    if winning_return <= stake:
        raise ValueError("event.winning_total_return_usdt must be > event.stake_usdt")
    return EventPayout(stake, winning_return)


def _finite_number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{field} must be a finite number")
    converted = float(value)
    if not isfinite(converted):
        raise ValueError(f"{field} must be a finite number")
    return converted


__all__ = ["EventPayout", "calculate_event_payout"]
