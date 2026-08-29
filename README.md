# Mean Reversion T (MR-T)

[简体中文](README.zh-CN.md) · English

A production-grade **Confirmed-close MR-T Strategy** for TradingView, written in Pine Script v6. MR-T v3.1 makes every lifecycle decision from a confirmed **15-minute close**, then lets Strategy Tester fill the real market order at the next available tick. It is designed for **15-minute charts** and **A-share T+0 style intraday trading** (做T). Bilingual runtime UI (中文 / English).

[![Pine Script](https://img.shields.io/badge/Pine%20Script-v6-yellow)](https://www.tradingview.com/pine-script-docs/)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL%202.0-brightgreen.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-3.1.0-informational)](CHANGELOG.md)

---

## Why MR-T

Most mean-reversion indicators fire a signal the moment price strays from the mean - and then get run over when the "oversold" move is actually the start of a trend. MR-T treats mean reversion as a **multi-condition, time-aware lifecycle**, not a single threshold:

- It only trades when the **environment** is actually range-like (a composite regime score on both the 1H and 15m timeframes).
- It refuses to enter when a **hard trend** is present (slope and efficiency-ratio vetoes).
- It distinguishes a **gentle drift** (Range engine) from a **violent shock that is exhausting itself** (Shock engine).
- It sizes every exit by an **Ornstein-Uhlenbeck half-life** estimate, so a trade that has gone nowhere long enough is killed on time, not left to bleed.
- It sends **real strategy orders** to the TradingView broker emulator: T-trim closes a configurable percentage, and T-close manages the remainder.

## Features

| Capability | Detail |
|---|---|
| Dual engine | Range reversion (mild Z deviation) + Shock reversal (abnormal impulse + deceleration/rejection) |
| Hard Trend Veto | 1H and 15m slope + efficiency-ratio guards against trend environments |
| Half-life time stop | OU-process half-life estimates how long a reversion should take; fallback when unmeasurable |
| Strategy Tester | Real `strategy.entry` and `strategy.close` market orders; formal P&L and positions come from Strategy Tester |
| Partial exits | Configurable `trimPct` (default 50%) for T-trim; T-close exits the remaining position |
| Cost-aware breakeven | Strategy Tester commission/slippage are the formal cost source; matching inputs size the post-trim breakeven estimate |
| Confirmed-close lifecycle | Entry, Stop/BE, Trend Fail, Timeout, Trim, and Final are decided only at confirmed 15m closes |
| Broker fill state | A dedicated `varip` fill state synchronizes real position transitions across `calc_on_order_fills` executions without making new decisions |
| Broker/fill-state consistency | Classifies flat, pending, stale, mismatched, orphan, and direct-reversal states; invalid contexts are cleared or safely closed |
| No intrabar brackets | Risk/Trim/Final levels are decision thresholds, not continuously resting stop/limit orders |
| Bilingual | Panel, chart labels and error messages switch 中文 / English via the *Language* input; input labels are compile-time static, while alerts use structured dynamic messages |
| Repaint-safe | Signals gated on confirmed bars; higher-timeframe data uses the last confirmed 1H bar; trade targets are frozen at entry |
| Versioned | Semantic versioning (see `CHANGELOG.md`), version shown in the panel |

---

## How it works

```mermaid
flowchart TD
    GATE["Environment Gate - Regime Score (25x4) + Hard Trend Veto"]
    GATE --> CHECK{"Environment OK?"}
    CHECK -- "No" --> NONE["No trade"]
    CHECK -- "Yes" --> RANGE{"Range engine: z <= -Z_entry"}
    CHECK -- "Yes" --> SHOCK{"Shock engine: z <= -Z_shock + decel + rejection"}
    RANGE -- "Yes" --> RSETUP["Range setup observed"]
    SHOCK -- "Yes" --> SSETUP["Shock setup observed"]
    RSETUP --> CONFIRM["Confirm on Z re-entry / candle / band"]
    SSETUP --> CONFIRM
    CONFIRM --> ENTRY["T-entry"]
    ENTRY --> TRIM["T-trim - partial, stop moves to breakeven"]
    TRIM --> CLOSE{"Full reversion?"}
    CLOSE -- "Yes" --> CLOSED["T-close"]
    CLOSE -- "No" --> EXITS["Exits: T-stop / Trend-fail / T-timeout / T-BE"]
```

### Lifecycle (per trade)

`Observe` -> `T-buy / T-short` -> `T-trim` (real partial exit, moves the remaining stop to breakeven) -> `T-close` (remaining position, full reversion).
Abnormal exits: `T-stop` (statistical or ATR risk line), `Trend-fail` (market turned trending), `T-timeout` (half-life exceeded), `T-BE` (breakeven after the first target).

There is no session-end liquidation. Positions and pending mean-reversion setups may naturally remain active across trading dates.

---

## Requirements

- **Pine Script v6** editor
- **15-minute chart** (enforced - the script errors on any other timeframe; this is a deliberate contract, see *Limitations*)
- A higher timeframe for market state (default **1H**)
- Data with enough history for warm-up (`meanLen` + `zLen` ~ 64 bars, half-life ~ 80 bars)

## Installation

1. Open the Pine Editor on TradingView, paste the contents of [`MRT.pine`](MRT.pine), then *Add to chart*.
2. Or clone this repo and open `MRT.pine` in your editor.

> MR-T v3 is a **strategy**, not an indicator. It creates one-direction-at-a-time orders and can be evaluated in Strategy Tester.

---

## Usage

- **Market**: primarily A-share T+0 intraday (做T) on 15m. Re-validate **all** parameters before applying to another market or timeframe.
- **Language**: set the *Language & Version -> Language* input to `zh` or `en`. This switches the panel, chart labels, and error messages. Input *labels* are bilingual-static — Pine pins their text to compile-time `const string`; alert messages use structured dynamic fields (see *Limitations*).
- **Costs**: set `commissionBps` and `slippageTicks` to match the Strategy Tester **Properties** tab. The code defaults to `3.0 bp/side` commission and `0` ticks, which are also the defaults declared in `strategy()`; the inputs are used for the post-trim breakeven estimate.
- **Alerts**: use `Any alert() function call` for setup/fill lifecycle messages, or `Order fills only` with `{{strategy.order.alert_message}}` for executable order events. The built-in strategy alert template also appends `{{strategy.order.price}}` as the actual fill price. Messages include `MR-T`, direction, event, mode, and price.

### Backtest workflow

1. Add `MRT.pine` to a **15m** chart. The script intentionally errors on other chart timeframes.
2. Open **Strategy Tester -> Properties** and confirm commission is `0.03%` per order (3 bp) and slippage is `0` ticks, or change both the Properties values and the matching script inputs.
3. Confirm `Pyramiding` is `0` and choose the desired default order size in Properties. The script defaults to 100% of equity for a single position.
4. Verify the tester trade markers: entry fills on the next available tick after a confirmed signal; T-trim reduces the position by `trimPct`; T-close exits the remainder.
5. Use the chart’s Risk/Trim/Final lines and the panel’s Tester rows for inspection. Net profit, win rate, drawdown, profit factor, and trade count in Strategy Tester are the formal results.

---

## Parameter reference

Input labels are Chinese (Pine requires compile-time `const string` for input titles, so they cannot be localized by a runtime toggle). English reference below.

### 1. Trade Direction
| Input | Type | Default | Meaning |
|---|---|---|---|
| `allowLong` | bool | true | Allow long (T-buy) setups |
| `allowShort` | bool | true | Allow short (T-short) setups |

### 2. Mean & Z-score
| Input | Type | Default | Meaning |
|---|---|---|---|
| `meanLen` | int | 32 | Local mean EMA length (15m) |
| `zLen` | int | 32 | Z-score window |
| `rangeEntryZ` | float | 1.65 | Range-mode observation Z threshold |
| `shockEntryZ` | float | 2.00 | Shock-mode observation Z threshold |
| `rangePartialZ` | float | 0.80 | Range-mode trim target (in Z) |
| `rangeExitZ` | float | 0.25 | Range-mode close target (in Z) |
| `shockPartialZ` | float | 1.00 | Shock-mode trim target (in Z) |
| `shockExitZ` | float | 0.50 | Shock-mode close target (in Z) |
| `stopZ` | float | 3.25 | Extreme statistical failure (stop) Z |

### 3. 1H Market State
| Input | Type | Default | Meaning |
|---|---|---|---|
| `htfTf` | timeframe | 60 | Higher timeframe for market state |
| `htfMeanLen` | int | 20 | 1H mean EMA length |
| `htfSlopeLookback` | int | 4 | 1H slope lookback |
| `idealHtfSlope` | float | 0.10 | Max "ideal" 1H slope (ATR/bar) for scoring |
| `htfERLen` | int | 10 | 1H efficiency-ratio length |
| `idealHtfER` | float | 0.50 | Max "ideal" 1H ER for scoring |

### 4. 15m Market State
| Input | Type | Default | Meaning |
|---|---|---|---|
| `localSlopeLookback` | int | 8 | 15m slope lookback |
| `idealLocalSlope` | float | 0.12 | Max "ideal" 15m slope (ATR/bar) |
| `localERLen` | int | 16 | 15m efficiency-ratio length |
| `idealLocalER` | float | 0.60 | Max "ideal" 15m ER |

### 5. Regime Score
| Input | Type | Default | Meaning |
|---|---|---|---|
| `rangeMinScore` | float | 50 | Minimum environment score for Range mode |
| `shockMinScore` | float | 45 | Minimum environment score for Shock mode |
| `regimeSmoothLen` | int | 3 | Score smoothing window |

### 6. Hard Trend Veto
| Input | Type | Default | Meaning |
|---|---|---|---|
| `vetoHtfSlope` | float | 0.18 | 1H slope veto threshold |
| `vetoLocalSlope` | float | 0.23 | 15m slope veto threshold |
| `vetoHtfER` | float | 0.75 | 1H ER veto threshold |
| `vetoLocalER` | float | 0.80 | 15m ER veto threshold |

### 7. Shock Engine
| Input | Type | Default | Meaning |
|---|---|---|---|
| `shockLookback` | int | 2 | Bars over which shock is measured |
| `minShockATR` | float | 0.80 | Minimum shock strength (in ATR) |
| `requireShockDeceleration` | bool | true | Require the impulse to be decelerating |
| `decelerationRatio` | float | 0.85 | Deceleration ratio (current vs. previous move) |
| `requireRejection` | bool | true | Require a rejection / reverse candle |
| `minWickRatio` | float | 0.30 | Minimum wick ratio for rejection |

### 8. Half-Life / Time Stop
| Input | Type | Default | Meaning |
|---|---|---|---|
| `halfLifeLookback` | int | 80 | Half-life sample length |
| `timeStopMultiplier` | float | 3.0 | Time stop = half-life x N |
| `minTimeStopBars` | int | 8 | Minimum time stop (bars) |
| `maxTimeStopBars` | int | 40 | Maximum time stop (bars) |
| `fallbackTimeStopBars` | int | 24 | Time stop when half-life is unmeasurable |

### 9. Setup / Confirmation
| Input | Type | Default | Meaning |
|---|---|---|---|
| `rangeSetupBars` | int | 16 | Range setup validity window (bars) |
| `shockSetupBars` | int | 8 | Shock setup validity window (bars) |
| `requireCandleConfirm` | bool | true | Require candle direction confirmation |
| `requireBandReclaim` | bool | true | Require price to re-enter the active Entry-Z band in addition to Z reclaim |
| `cooldownBars` | int | 3 | Cooldown after exit |
| `trimPct` | float | 50 | Percentage of the initial position closed at T-trim |

### 10. Risk Control
| Input | Type | Default | Meaning |
|---|---|---|---|
| `atrLen` | int | 14 | ATR period |
| `hardStopATR` | float | 2.50 | ATR emergency stop |
| `stopMode` | string | Balanced | `Tight` / `Balanced` / `Loose` stop selection |
| `balancedWeight` | float | 0.50 | Weight between statistical & ATR stops (0=loose, 1=tight) |
| `moveStopToBE` | bool | true | Move stop to breakeven after trim |
| `commissionBps` | float | 3.0 | Commission per side in basis points; match Strategy Tester Properties |
| `slippageTicks` | int | 0 | Slippage per side in ticks; match Strategy Tester Properties |

### 11. Display / 12. Language
| Input | Type | Default | Meaning |
|---|---|---|---|
| `showBands` | bool | true | Show reversion bands |
| `showBackground` | bool | true | Show trade environment background |
| `showSetup` | bool | true | Show observation signals |
| `showPanel` | bool | true | Show status panel |
| `showTradeLevels` | bool | true | Show live target/risk lines |
| `lang` | string | zh | `zh` / `en` runtime UI language |

---

## Cost model & Strategy Tester panel

Strategy Tester is the formal performance source. Commission is declared as `0.03%` per order (3 bp/side) and slippage as `0` ticks by default. Change the Strategy Tester **Properties** values for a different test, then set the matching `commissionBps` and `slippageTicks` inputs so the post-trim breakeven estimate uses the same assumptions.

After a real T-trim fill, the remaining stop is moved to `entry +/- transaction cost` when `moveStopToBE` is enabled. The panel labels net profit, drawdown, closed trades, and win rate as **Tester** values; it does not use the former virtual P&L counters. Range/Shock are lightweight auxiliary classifications shown as entries / closed positions / wins, and their win rates use `wins / closed` rather than `wins / entries`.

The broker emulator uses standard market-order handling. A confirmed-close Entry, Trim, Final, Stop/BE, Trend Fail, or Timeout decision creates an order that fills at the next available tick because `process_orders_on_close = false` and every `strategy.close` uses `immediately = false`. The chart levels are thresholds for the decision close; they are not guaranteed fill prices.

### v3.1.0 confirmed-close broker/fill-state consistency

`strategy.position_size` and `strategy.position_avg_price` are the broker emulator’s source of truth. `MRFillState` only stores the frozen signal context, lifecycle phase, exit reason, and auxiliary statistics. The script exposes a numeric consistency classifier in the Data Window:

| Code | State | Meaning |
|---:|---|---|
| 0 | `OK_FLAT` | Broker and lifecycle are flat |
| 1 / 2 | `OK_LONG` / `OK_SHORT` | Active lifecycle and broker position agree |
| 3 | `PENDING_ENTRY` | A confirmed entry is queued or in its fill transition |
| 4 | `STALE_ACTIVE_FLAT` | Lifecycle is active while the broker is flat without a current Full Exit transition |
| 5 | `DIRECTION_MISMATCH` | Broker direction conflicts with active/pending lifecycle direction |
| 6 | `ORPHAN_BROKER` | Broker has a position with neither an active nor pending lifecycle |
| 7 | `DIRECT_REVERSAL` | The execution crossed from Long to Short or Short to Long |
| 8 / 9 | `STALE_PENDING` / `INVALID_CONTEXT` | Pending or frozen context is no longer safe to manage |

Stale context is cleared without incrementing Range/Shock Closed or Wins. An orphan or direct-reversal broker position cancels unfilled orders and is closed with `strategy.close_all()`; it is never initialized as a new trade from current mean/std values. Normal lifecycle management does not use `strategy.order`, `strategy.exit`, stop/limit prices, or OCA groups. Trade lines are shown only while a real broker position and a direction-matched active lifecycle both exist.

The lifecycle phases are: signal state → pending Entry → active pre-Trim → pending Trim fill → active post-Trim → pending Full Exit → flat. `partialTaken` becomes true only after `strategy.position_size` really shrinks, and the lifecycle resets only after it really reaches zero. `Consistency Recovery Count` should remain `0` for normal historical operation.

Data Window also exposes the cumulative Shock funnel: `Shock Z Candidates`, `Shock Move Candidates`, `Shock Environment Pass`, `Shock Deceleration Pass`, `Shock Rejection Pass`, `Shock Setups`, and `Shock Confirmed Entries`. Each pass includes the preceding layers and is counted during confirmed-close Entry eligibility, so the largest drop identifies the main filter.

---

## Repaint safety

- Setup, Entry, Stop/BE, Trend Fail, Timeout, Trim, and Final decisions are gated on the normal confirmed-bar decision phase. One bar can create at most one lifecycle decision.
- `calc_on_order_fills` executions are reserved for synchronizing actual Entry/Trim/Exit state. Historical fill executions can still have `barstate.isconfirmed = true`, so a detected broker-position change suppresses decisions on that execution.
- Higher-timeframe values are the **last confirmed 1H bar** (`f_erPrev` / `f_slopeATRPrev` + `barmerge.lookahead_on`) - no future leak.
- The confirmed signal bar queues an order; after the fill, targets/stops are **frozen from the actual `strategy.position_avg_price`** and the signal-bar regime context.
- The half-life estimate uses only past data.

The Entry fill bar only initializes the real fill price, size, and frozen context. Management requires `bar_index > entryBar`. A Trim signal submits a real `qty_percent = trimPct` market reduction; after its fill, BE/Final management requires `bar_index > partialBar`. This prevents Entry → exit and Trim → BE/Final lifecycle jumps on the same 15m bar.

### v3.1.0 TradingView validation checklist

After compiling in TradingView on a 15-minute chart:

1. Pine v6 compiles successfully on a 15m chart.
2. `MR-L` / `MR-S` fills at the next available tick after the confirmed signal close.
3. The Entry fill bar has no Trim, Stop, or Final decision.
4. Trim triggers only when the confirmed close reaches the frozen Trim level.
5. The real broker position is reduced by `trimPct` (default 50%).
6. BE and Final become eligible only on a bar after the real Trim fill bar.
7. Stop triggers only when the confirmed close crosses the displayed Risk level.
8. Trend Fail is evaluated only at a confirmed close.
9. Timeout is evaluated only at a confirmed close.
10. Long and Short behavior is mirrored, and positions can cross trading dates.
11. Broker Position and FillState direction remain consistent through every fill.
12. `Consistency Recovery Count` remains 0 on normal historical paths.
13. At a final flat state, Range + Shock Entries equals Range + Shock Closed (apart from a genuinely pending order).
14. No normal order list contains `MR-L/MR-S-STOP`, `-TRIM`, or `-FINAL` bracket IDs.
15. A normal Entry fill bar never shows Entry + Trim + Stop together. Bar Magnifier OFF/ON should not materially alter lifecycle decisions.

The source-level static review and `git diff --check` do not replace TradingView compilation or Strategy Tester runtime verification.

## Limitations & scope

- **Hard-coded 15m contract.** The script refuses to run on other timeframes. This is deliberate (window lengths are in bars and were tuned on 15m); rescaling to other timeframes requires re-tuning.
- **Input labels are bilingual-static.** Pine input titles are compile-time `const string`; a runtime language toggle cannot localize them. The panel, chart labels and error messages follow the `lang` input. Strategy order messages are dynamic and the default alert template includes the actual fill-price placeholder.
- **Costs have two settings surfaces.** Pine requires the Strategy Tester commission/slippage defaults in `strategy()` to be compile-time values. The `commissionBps` and `slippageTicks` inputs keep BE calculations aligned, but changing them does not rewrite the Properties tab automatically.
- **A-shares T+0 bias.** The engine assumes intraday reversion against a held position. Applying it to trending crypto/forex without re-tuning will disappoint.
- **Not financial advice.** No performance guarantees, express or implied.

---

## Contributing

Issues and PRs welcome. Keep changes backward-compatible, keep confirmed-bar state in `MRState` and fill lifecycle state in `MRFillState`, and bump `CHANGELOG.md` + `SCRIPT_VERSION` with each behavioral change.

## License

This Pine Script code is subject to the terms of the **Mozilla Public License 2.0** at <https://mozilla.org/MPL/2.0/>. See [LICENSE](LICENSE) for the full text.

## Author

**Jasxu** - [TradingView](https://www.tradingview.com/u/Jasxu/) · [GitHub](https://github.com/Ye-Yu-Mo)

## Disclaimer

This software is provided for **educational and informational purposes only**. It is not investment advice, and past or simulated performance does not guarantee future results. Trading involves risk; you are solely responsible for your own decisions.
