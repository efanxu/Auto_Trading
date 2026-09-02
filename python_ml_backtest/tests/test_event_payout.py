from __future__ import annotations

import pytest

from auto_trading.backtest import calculate_event_payout


def test_baseline_event_payout() -> None:
    payout = calculate_event_payout(5, 9.25)

    assert payout.stake_usdt == pytest.approx(5.0)
    assert payout.winning_total_return_usdt == pytest.approx(9.25)
    assert payout.win_net_profit == pytest.approx(4.25)
    assert payout.loss_net_profit == pytest.approx(-5.0)
    assert payout.break_even_win_rate == pytest.approx(5 / 9.25)
    assert payout.break_even_win_rate * 100 == pytest.approx(54.05405405405405)
