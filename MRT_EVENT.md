# MR-T Event Contract v0.1.0

`MRT_EVENT.pine` is an independent Event Contract Baseline Experiment. Its purpose is to measure whether the MR-T mean-reversion entry can predict the direction of the price after a fixed 30-minute or 1-hour holding period.

## Signal baseline

The signal and entry execution baseline is the `MRT_V4.pine` source at commit [`d30f506719666df1ac89f79ef322f15f81d901ec`](https://github.com/efanxu/Auto_Trading/commit/d30f506719666df1ac89f79ef322f15f81d901ec), MR-T v4.5.1 Real-Time Execution Correctness. The event script retains:

- confirmed 15m decision execution;
- last-confirmed 1H and 15m regime context;
- Hard Trend Veto;
- Range and Shock engines, including Shock priority, deceleration, and rejection checks;
- Setup state and previous-confirmed-bar PREPLAN;
- real Stop-Limit entry orders;
- Broker flat-to-position fill detection and actual fill price;
- source bar, valid bar, mode, direction, and fill diagnostics.

`MRT.pine` and `MRT_V4.pine` remain unchanged formal strategies.

## Event definition

An Event is created only after a PREPLAN Stop-Limit order has a real TradingView Broker Fill. The Event stores:

- direction: Long/T买 or Short/T空;
- mode: Range or Shock;
- `eventEntryPrice`: `strategy.position_avg_price` at the real Broker fill;
- entry fill bar and entry timestamp;
- PREPLAN `sourceBar` and `validBar`;
- independent 30m and 1h expiry/settlement state.

The script uses a short-lived Broker probe position because Pine exposes an actual entry fill through strategy Broker state. After the fill is recorded, it submits `strategy.close()` with the `EVENT_BROKER_RELEASE` comment to release that probe position. This release is not an Event settlement, does not affect Event P&L, and does not implement TP1, TP2, Initial Stop, Break Even, Trend Fail, or Timeout.

## Settlement rules

On a 15-minute chart the baseline horizon is two complete chart bars for 30min and four complete chart bars for 1h. For an entry fill on chart bar `B`:

```text
expiry30Bar = B + 2
expiry60Bar = B + 4
```

Settlement uses the `close` of the first confirmed chart bar at or after the stored expiry bar:

```text
Long 30m/1h: close > eventEntryPrice => Win
Short 30m/1h: close < eventEntryPrice => Win
otherwise                         => Loss
```

Equality is intentionally a Loss in v0.1.0. The 30m and 1h Shadow Events are independent: 30m can be Win while 1h is Loss, and settling 30m does not remove the 1h state.

TradingView can use Bar Magnifier to improve historical fill sequencing, but a Pine strategy with `calc_on_every_tick = false` cannot run a settlement callback at an arbitrary intrabar wall-clock instant. The implementation therefore records the Broker-provided fill timestamp for diagnostics and uses the fixed fill-bar-plus-horizon rule above for a strict, reproducible 15m-chart approximation. The actual settlement price is still the confirmed expiry-bar close, never the Setup close, source close, or PREPLAN creation close.

## P&L model

Inputs default to:

```text
stakeUSDT          = 5.00 USDT
winningReturnUSDT  = 9.25 USDT  # total return, including stake
winNetProfit       = +4.25 USDT
lossNetProfit      = -5.00 USDT
breakEvenWinRate   = 5 / 9.25 = 54.054...% ≈ 54.05%
```

30m and 1h maintain separate `eventEquity30` and `eventEquity60` curves, totals, wins/losses, win rates, edge over break-even, EV, streaks, drawdown, direction statistics, engine statistics, and Range/Long, Range/Short, Shock/Long, and Shock/Short breakdowns.

The expected value formula is:

```text
EV = WinRate × (+4.25) + (1 - WinRate) × (-5.00)
```

## Concurrent Events

Unsettled Events are stored in a bounded `array<MRShadowEvent>`. The queue is iterated backwards each confirmed bar, allowing 30m settlement while the same record remains active for 1h. A record is removed only after both horizons settle. `maxActiveEvents` is configurable; reaching its capacity raises a visible runtime error rather than silently dropping an Event.

The Broker probe is serialized because the v4.5.1 PREPLAN uses one real pending Stop-Limit order at a time. The Shadow Event queue is not serialized: after a probe fill is released, later PREPLAN fills can create new Events while earlier 30m/1h records remain active.

## Display and verification

The panel has independent `30min` and `1h` columns. The Data Window includes the last Event direction/mode/price, source/valid/fill facts, both settlement results/prices/P&L, both win rates and EVs, equity curves, active count, and Range/Shock counts. Entry labels are `EVENT LONG`/`EVENT SHORT`; settlement labels are `30W`, `30L`, `60W`, and `60L`, with a bounded label queue.

Run the deterministic checks with:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\MRT-event-contract-harness.ps1
```

The local harness covers Long/Short wins and losses, equality-as-Loss, independent horizons, overlap and cleanup, payout math, break-even rate, classification counters, and v4.5.1 causality guards. Pine v6 compilation and Strategy Tester runtime checks must still be performed on TradingView.
