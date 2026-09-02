# MR-T Event Contract v0.2.0

`MRT_EVENT.pine` is an independent fixed-duration Event Contract experiment. The formal result is a Shadow Event result, not a Strategy Tester trade result.

The signal and entry baseline remains [`MRT_V4.pine` at commit `d30f506719666df1ac89f79ef322f15f81d901ec`](https://github.com/efanxu/Auto_Trading/commit/d30f506719666df1ac89f79ef322f15f81d901ec), MR-T v4.5.1 Real-Time Execution Correctness. The script retains:

- confirmed-close 15m Signal, Setup, Regime, Hard Trend Veto, Range/Shock funnel;
- previous-confirmed-bar PREPLAN scheduling;
- real Stop-Limit entry orders through the TradingView Broker Emulator;
- `process_orders_on_close = false`, `calc_on_order_fills = true`, `calc_on_every_tick = true`, and `use_bar_magnifier = true`.

`calc_on_every_tick` is used for realtime Event settlement only. Setup, PREPLAN, Regime, Range/Shock, and entry decisions remain behind the confirmed 15m execution gate. Historical-tick execution is not enabled.

## Event clock

An Event is created only after a PREPLAN Stop-Limit order produces a real Broker Fill. The actual entry price comes from `strategy.position_avg_price`; the entry timestamp preferentially comes from `strategy.opentrades.entry_time(...)`.

The only Event expiry clock is timestamp-based:

```text
Event Entry = actual Broker Fill timestamp
30m Target  = entryTimestamp + 30 * 60 * 1000
1h Target   = entryTimestamp + 60 * 60 * 1000
```

For example, an entry at minute 17 targets minute 47 for 30m and minute 77 for 1h. Event settlement never uses a chart-bar offset or a chart `close` as an expiry-price fallback.

## Historical 2m settlement

On the required 15m chart the script requests one lower-timeframe tuple:

```pine
[time, time_close, close] = request.security_lower_tf(syminfo.tickerid, "2", ...)
```

During a normal historical confirmed 15m execution, every active Event is checked independently for both horizons. The first available 2m intrabar with `time_close >= targetTime` is selected. Its lower-timeframe `close` is the observed expiry price.

The Event and Data Window expose:

- target time;
- observed time;
- timing error in seconds (`observedTime - targetTime`).

Average and maximum timing errors are tracked separately for 30m and 1h. With complete regular 2m coverage, the timing error should normally be between 0 and approximately 120 seconds. Larger values remain visible in the diagnostics.

TradingView limits the historical number of lower-timeframe intrabars. If the target has passed and no usable 2m observation is available, that horizon is marked `UNRESOLVED_NO_INTRABAR_DATA`. It is not converted to a 15m close, not counted as a Win or Loss, and contributes no Event P&L. The other horizon remains active and can settle independently.

## Realtime settlement

On a realtime bar, the script waits until `timenow >= expiryTime`. On the first realtime tick satisfying that condition, it records the current `close` and `timenow` as the expiry observation. A horizon is settled only once. Signal generation remains restricted to a genuinely confirmed 15m close, so realtime settlement ticks cannot create repeated Setup or PREPLAN decisions.

## Payout and statistics

The Event Contract has no commission or slippage:

```text
Stake              = 5.00 USDT
Winning total      = 9.25 USDT
Win net            = +4.25 USDT
Loss net           = -5.00 USDT
Break-even WinRate = 5 / 9.25 = 54.054...% ≈ 54.05%
```

Long is a strict `observedPrice > entryPrice` Win. Short is a strict `observedPrice < entryPrice` Win. Equality is a Loss.

30m and 1h maintain separate resolved/unresolved counts, Wins, Losses, Win Rate, break-even rate, Win Rate Edge, Net Event P&L, EV/Event, consecutive-win and consecutive-loss maxima, equity drawdown, timing diagnostics, and Long/Short, Range/Shock, Range Long, Range Short, Shock Long, and Shock Short breakdowns. All Win Rate denominators use resolved horizons only.

## Broker probe versus Event result

The Broker probe exists only to establish an executable PREPLAN fill fact:

```text
PREPLAN Stop-Limit
→ Broker Emulator fill
→ strategy.position_avg_price
→ strategy.opentrades.entry_time(...)
→ Shadow Event creation
```

The probe uses `default_qty_value = 0.1` percent of equity and is released immediately with `strategy.close(..., immediately = true)`. It does not carry the 5 USDT Event stake, does not settle an Event, and does not contribute to Event P&L. The formal Event stake and payout are an independent accounting ledger.

The panel explicitly labels:

```text
Event Contract Statistics
Strategy Tester trades = Broker probe only
```

Therefore Strategy Tester Net Profit, Win Rate, Average Trade, Profit Factor, commissions, and closed-trade profit are not Event Contract results. They describe only the small Broker probe lifecycle.

The Event version removes ordinary MR-T exit-only parameters and lifecycle state, including trim/final targets, initial stop construction, break-even protection, Trend Fail, Timeout, and other TP/SL/BE management artifacts. `MRT.pine` and `MRT_V4.pine` are not modified.

## Local harness

Run the Event Contract and regression harnesses from the repository root:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\MRT-event-contract-harness.ps1
```

The harness covers timestamp target math, first-observation selection, strict Long/Short comparisons, equality-as-Loss, independent horizons, overlapping Events, unavailable lower-TF coverage, exclusion of unresolved horizons from Win Rate and P&L, zero-cost declaration, probe sizing, ordinary-lifecycle removal, confirmed 15m signal gating, and unchanged formal MR-T scripts. Pine v6 compilation and TradingView runtime/visual checks remain release checks after loading the script on a 15m chart.
