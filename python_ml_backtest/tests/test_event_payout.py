from __future__ import annotations

import pytest

from auto_trading.backtest import calculate_event_payout


def test_b0_event_payout() -> None:
    payout = calculate_event_payout(10, 18.5)

    assert payout.stake_usdt == pytest.approx(10.0)
    assert payout.winning_total_return_usdt == pytest.approx(18.5)
    assert payout.win_net_profit == pytest.approx(8.5)
    assert payout.loss_net_profit == pytest.approx(-10.0)
    assert payout.break_even_win_rate == pytest.approx(10 / 18.5)
    assert payout.break_even_win_rate * 100 == pytest.approx(54.05405405405405)
