# Changelog

All notable changes to **Mean Reversion T (MR-T)** are documented here. Versioning follows [Semantic Versioning](https://semver.org/).

## [0.1.0] — MR-T Event Contract Baseline Experiment

- Added standalone `MRT_EVENT.pine` for measuring MR-T direction accuracy after fixed 30-minute and 1-hour horizons.
- Kept the v4.5.1 confirmed-bar, previous-confirmed-bar PREPLAN, Stop-Limit, and real Broker fill baseline from `d30f506719666df1ac89f79ef322f15f81d901ec`.
- Added independent concurrent Shadow Event queue, Range/Shock and Long/Short statistics, fixed 5 USDT / 9.25 USDT payout accounting, event equity curves, and diagnostics.
- `MRT.pine` and `MRT_V4.pine` remain unchanged.

## [4.5.1] — Real-Time Execution Correctness

- Orders created from confirmed bars now become fillable only from the next available tick.
- Replaced split `strategy.exit` brackets with one Broker OCA-reduce price-order lifecycle.
- TP1/TP2 use Limit orders; Initial/BE protection use Stop orders.
- TP1 recalculation rebuilds remaining TP2/BE orders from actual `strategy.position_size`.
- Confirmed-close Trend Fail/Timeout decisions fill on the next available Broker tick.
- Added exact-flat and residual-position diagnostics.
- Strategy mathematics unchanged.

## [4.5.0] — Intrabar Broker Exit Lifecycle

- Entry fills now submit TP1/TP2/Stop Broker brackets immediately.
- Bar Magnifier may execute Entry→TP/Stop sequences inside the same 15m bar.
- Actual `MR-X1` TP1 fills immediately move the remaining `MR-X2` Stop to execution-cost-aware break-even through `calc_on_order_fills`.
- Trend Fail and Timeout remain later-bar, confirmed-close management and cancel the live brackets before `strategy.close()`.
- Strategy Tester remains the sole V4 performance source.
- Bar Magnifier improves intrabar sequencing using lower-timeframe historical bars. It is not tick-by-tick exchange replay; crossings inside one lowest available Magnifier bar still follow TradingView Broker Emulator rules.

## [4.4.0] — True Executable PREPLAN Entry

- PREPLAN now submits real next-bar Stop-Limit entries that expire at the valid bar's confirmed close; Stop activation, gap behavior, and Limit fills are decided only by TradingView's Broker Emulator.
- Broker fills initialize the formal V4 trade from `strategy.position_avg_price`, freeze the submitted source statistics, and re-anchor the initial Stop and break-even protection to the actual fill.
- Confirmed-close Stop/BE, Trend Fail, Timeout, Trim, and Final management starts only after the Entry bar, so the fill bar cannot also produce a formal exit.
- Strategy Tester is now the sole V4 performance source of truth; the independent V4 equity, Profit Factor, Win Rate, and trade-return ledger plus `V4_RESULT` output were removed.
- Enabled Bar Magnifier and removed V3 Entry/trade-count parity as a V4 acceptance target. Historical Broker Emulator output is higher-path-resolution simulation, not exchange tick-fill proof; live `ENTRY_FILLED` state must follow actual exchange fills.
- Reworked `tests/MRT-v4-execution-plan-harness.ps1` around executable-order, fill-transition, one-bar expiry, gap-unfilled, frozen-plan, actual-fill risk, and Entry-bar management guards.

## [4.3.0] — Standalone V4 Execution Accounting

- Reworked `MRT_V4.pine` around `MRV4ExecutionState`, the sole source of V4 entry price, trade return, compounded Net, Profit Factor, Win Rate, and PREPLAN usage.
- Kept the V3 confirmed-close Logic event clock, previous-bar PREPLAN assist, and Strategy Tester Broker order path unchanged.
- Removed the separate comparison ledger, comparison fields, and four one-bar Chart Data export series; result output now uses `V4_RESULT` alerts and the existing 21-row Panel.
- Extended `tests/MRT-v4-execution-plan-harness.ps1` for standalone V4 selection, accounting, presentation, alert, and regression checks.

## [4.2.1] — Shadow observability / export

- Surfaced Shadow trade/reference metrics in the existing panel.
- Added one-bar Shadow result export series.
- No Logic or Strategy Tester order changes.

## [4.2.0] — Shadow Execution Accounting

- Added an independent V4 Shadow Execution ledger that uses a touched, matching previous-bar PREPLAN limit as the historical entry fill approximation while keeping the official V3 confirmed-close Strategy Tester timeline unchanged.
- Added V3 Reference comparison, compounded normalized equity, trade returns, delta, Profit Factor, Win Rate, PREPLAN usage, entry improvement, Data Window fields, and `SHADOW_RESULT` alerts.
- Extended `tests/MRT-v4-execution-plan-harness.ps1` with Shadow state, pricing, lifecycle, accounting, and regression checks.

## [4.1.0] — V3-Aligned Execution Assist

- Execution Assist now uses a previous-confirmed-bar rolling one-bar PREPLAN.
- The official Logic timeline is restored to V3 confirmed-close parity.
- Provisional intrabar plans no longer drive the Strategy Tester lifecycle.

## [4.0.0] — Frozen execution plans and intrabar price orders

- Added `MRT_V4.pine`, preserving `MRT.pine` as the byte-for-byte v3.3.2 V2 Logic-State Parity reference. Confirmed 15m signals now create tick-rounded, frozen retracement plans with Range/Shock expiry, cancellation alerts, and non-marketable limit entries.
- Entry fills synchronize from Broker Emulator facts, then submit reserved TP1/TP2 `strategy.exit` brackets with frozen targets and Stop. Actual TP1 fills update the remaining bracket to an execution-cost-aware break-even Stop; Trend Fail and Timeout remain confirmed-close state exits.
- Enabled Bar Magnifier while keeping `calc_on_every_tick = false` and `calc_on_order_fills = true`. Fill recalculations are excluded from signal/cancel decisions, and the 21-row Panel no longer depends on `barstate.islast`.
- Added `tests/MRT-v4-execution-plan-harness.ps1` with 32 deterministic model/static checks. TradingView Pine compilation and Broker Emulator fill-order backtesting remain manual release checks.

## [Unreleased] — Restore strict V2 Logic execution timeline

### Fixed

- **MR-T v4 residual cleanup** — replaced exit brackets with explicit OCA-reduce orders, added strict-flat cleanup, restored filled-position Trade Level visibility, and fixed Plan expiry at `>=`.
- **Confirmed-bar Logic scheduling** — `positionChanged` is now Broker-only execution diagnostics. A Logic-only per-bar cursor guarantees that every confirmed 15m bar runs the V2 lifecycle once, while same-bar `calc_on_order_fills` recalculations cannot repeat it.
- **Lifecycle parity regression coverage** — the local harness now models normal confirmed executions, same-bar fill recalculations, next-bar management, chained cooldown lifecycles, Long/Short mirrors, and Stop/BE/Trend Fail/Timeout decision bars.

## [3.3.2] — Restore stable presentation footprint

This release keeps the v3.3.1 V2 Logic-State / Broker Execution architecture and restores the production display layer to the stable 07cbe31 presentation footprint.

### Changed

- **Three explicit layers** — `MRLogicState` remains the sole source for T-buy, T-short, T-trim, T-close, Stop/BE, Trend Fail, and Timeout decisions; `MRBrokerState` remains responsible for real Strategy Tester orders, fills, P&L, consistency, and recovery; Presentation only renders their facts.
- **Stable Presentation baseline** — Local Mean, Range/Shock/Extreme bands and fills, Range/Shock backgrounds, Logic-frozen T-trim/T-close/Risk levels, Setup labels, Logic Event T labels, and the compact Panel follow commit `07cbe31a1c9adbdf5d96a6c84558184adfb0cdfb`.
- **Compact production Data Window** — reduced from 44 to 27 plots. It retains market context, the minimum Logic parity fields, current Broker position/entry facts, recovery/consistency, and Range/Shock statistics; fill bars, intent flags, and Shock funnel counters remain development diagnostics.
- **Conservative plot budget** — 37 `plot()` calls, one `bgcolor()`, and two const-color Shock `fill()` calls produce an estimated static budget of 38/50. The Panel remains at 21 rows and includes Broker state, recovery count, and cost diagnostics.
- **Release harness** — renamed and extended `tests/MRT-v3.3.2-v2-logic-parity-harness.ps1` with direct v3.3.1 Logic/Broker regression checks and 07c Presentation regression checks.

### Preserved

- All 58 input declarations and defaults, `process_orders_on_close = true`, `calc_on_order_fills = true`, `calc_on_every_tick = false`, `pyramiding = 0`, zero margin requirements, real `strategy.entry` / `strategy.close`, default 50% Trim, Close-only V2 lifecycle, BE cost semantics, recovery isolation, and Range/Shock statistics.

### Verification

- Local harness passes V2 Logic parity, Broker architecture, Close-only lifecycle, BE cost, Trend/Timeout/Cooldown, Presentation regression, 27 Data Window plots, and the 38/50 static budget.
- `git diff --check` is required before release.
- TradingView Pine v6 compilation, absence of RE10140, visual comparison with 07c, Strategy Tester runtime parity, normal-path Recovery Count = 0, and Margin Call = 0 remain manual TradingView checks.

## [3.3.1] — Plot-budget and parity-harness correctness patch

This patch keeps the v3.3.0 MRLogicState / MRBrokerState architecture and transaction logic unchanged.

### Fixed

- **TradingView plot budget** — reduced permanent Data Window diagnostics from 55 to 44, retained the V2 Logic/Broker parity fields and Shock funnel, and moved the Broker cost estimate to the existing Panel. The 54 remaining `plot()` calls stay below the static budget of 57.
- **Const-color fills** — the two Shock-to-Extreme `fill()` calls now use const colors, so they do not add dynamic fill plot counts while preserving the existing visual bands.
- **Confirmed-close parity harness** — replaced the v3.3.0 harness with `tests/MRT-v3.3.1-v2-logic-parity-harness.ps1`. Dynamic Stop, Trim, and Final decisions now use `Close` only; Final requires `PartialTaken = true`; and BE uses the V2 round-trip commission cost.
- **Regression cases** — added Short `T空 → T减 → next-bar T平`, Long Stop precedence, and Long/Short BE-with-cost lifecycle assertions, plus static close-only and plot-budget checks.

### Preserved

- V2 setup conditions, priorities, expiry, entry confirmation, frozen context, targets, ATR/statistical stops, Tight/Balanced/Loose stop modes, Trend Fail, Timeout, cooldown, lifecycle priority, same-close broker settings, real 50% default trim, and Logic/Broker separation.

### Verification

- Local harness reports 54 `plot()` calls, 44 Data Window plots, two `fill()` calls, one `bgcolor()`, and an estimated static plot budget of 55/60.
- `git diff --check` is required before release.
- TradingView Pine v6 compilation, RE10140 absence, and Strategy Tester runtime parity remain pending manual TradingView verification.

## [3.3.0] — V2 Logic-State Parity

This release makes the V2.0.0 logic state the sole source of MR-T lifecycle decisions while retaining real Strategy Tester execution and Broker diagnostics.

### Changed

- **Logic/Broker split** — `MRLogicState` owns the V2 lifecycle fields and decides Entry, Trim, Final, Stop/BE, Trend Fail, and Timeout. `MRBrokerState` owns order intents, actual position/fill facts, P&L diagnostics, and recovery.
- **Immediate Logic mutation** — Entry sets `logic.entryPrice = close`, freezes the V2 context and cost, and sets `logic.pos` before `strategy.entry`. Trim sets `logic.partialTaken = true` before submitting `strategy.close(..., qty_percent = trimPct)`.
- **V2 management parity** — Active Stop/BE, Final, Trend Fail, Timeout, and cooldown read Logic State only. Logic exits set `logic.pos = 0` and `logic.lastExitBar` before Broker flattening.
- **Fill isolation** — `calc_on_order_fills` executions synchronize Broker facts only. Broker fills cannot create, reorder, or rewrite Logic Events; Broker recovery is execution-only and emits `BROKER RECOVERY` diagnostics.
- **Stable Logic Events** — `logicEventBar`, `logicEventKind`, `logicEventDir`, `logicEventReason`, `logicEventMode`, and `logicEventPrice` persist through same-bar fill recalculation and clear only on a new bar. T labels are derived from these fields.
- **Two-layer diagnostics** — Data Window adds Logic Position/Event/decision bars alongside Broker Position/fill/recovery/fill-bar fields. The existing 58 inputs, formulas, defaults, same-close settings, cross-date behavior, trim default of 50%, Shock funnel, and no-bracket order model are preserved.

### Verification

- The release-specific v3.3.0 static and dynamic parity harness was superseded by the v3.3.1 harness above, which is now the single current test source.
- `git diff --check` is required before release.
- TradingView Pine v6 compilation and Strategy Tester runtime parity remain pending manual TradingView verification.

## [3.2.0] — V2 Decision-Parity Strategy fills

This release aligns the Strategy Tester execution timeline with MR-T Production v2.0.0 while retaining real broker positions and a real partial exit.

### Changed

- **Same-close confirmed execution** — `process_orders_on_close = true`, `calc_on_order_fills = true`, `calc_on_every_tick = false`, and `pyramiding = 0`. Entry, Trim, Final, Stop/BE, Trend Fail, and Timeout remain confirmed-close decisions; their market orders fill on that same close.
- **V2 parity margin baseline** — `margin_long = 0` and `margin_short = 0` disable Broker Emulator margin liquidation for parity testing. This does not model a live account's margin configuration.
- **Frozen V2 reference price** — `referenceEntryPrice` is the Entry decision close used by ATR stop and BE thresholds; `brokerEntryPrice` records the actual `strategy.position_avg_price` separately.
- **Strict lifecycle phase boundary** — Entry and Trim fill recalculations only synchronize broker state. Entry management begins on the next bar, and post-Trim BE/Final management begins on the next bar after Trim.
- **Direct fill diagnostics** — Data Window exposes Entry/Trim/Exit decision bars, Entry/Trim/Full Exit fill bars, reference/broker entry prices, and the consistency recovery counter. Same-close parity requires each decision bar to equal its corresponding fill bar.

### Preserved

- V2 Range/ Shock setup logic, Shock priority and funnel, Regime Score, Hard Trend Veto, Z reclaim and band reclaim, frozen mean/std/ATR/Half-Life, Tight/Balanced/Loose stop construction, Trend Fail, Timeout, cooldown, lifecycle priority, cross-date holding, and consistency recovery protection.
- Real `trimPct` partial close (default 50%), Strategy Tester commission/slippage defaults, and the absence of intrabar `strategy.order`, `strategy.exit`, stop/limit brackets, and OCA groups.

### Verification

- The release-specific v3.2.0 static/lifecycle parity harness covered that release's decision-versus-fill contract.
- `git diff --check` is required before release.
- TradingView Pine v6 compilation and Strategy Tester runtime/parity verification remain pending manual TradingView verification.

## [3.1.1] — Compile fix and decision-bar timing alignment

This patch keeps the confirmed-close MR-T decision model and real Strategy Tester broker fills while separating strategy decision bars from actual fill bars.

### Fixed

- **Pine return type** — `f_manage()` now accumulates one `int` management code (`NONE`, `STOP/BE`, `TREND`, `TIMEOUT`, `TRIM`, or `FINAL`) and explicitly returns it, removing the mixed `series int` / `series bool` block result that caused the Pine 1090:9 compile error.
- **Decision-bar lifecycle timing** — `entryDecisionBar`, `trimDecisionBar`, and `exitDecisionBar` preserve the confirmed-close MR-T time axis; `entryFillBar` and `trimFillBar` record actual Broker Emulator executions.
- **Entry and Trim management** — fill recalculations remain synchronization-only, while the confirmed close of the Entry or Trim fill bar can perform the next lifecycle decision. Final/BE eligibility is based on `trimDecisionBar`.
- **TimeStop and cooldown** — TimeStop counts from `entryDecisionBar`; cooldown uses the full-exit `exitDecisionBar` when the broker later reaches flat.

### Preserved

- Range/Shock engines, Shock funnel, thresholds, defaults, confirmed-close risk decisions, real 50% default Trim, cross-date holding, consistency recovery, and Strategy Tester broker facts remain unchanged.

### Verification

- The release-specific v3.1.1 regression harness covered the decision-versus-fill timing and lifecycle checks introduced here.
- Static review and `git diff --check` are required before release.
- Pine v6 compilation and Strategy Tester runtime verification remain pending manual TradingView verification.

## [3.1.0] — Confirmed-close Strategy Tester execution

This release restores the original MR-T confirmed 15-minute close decision model while retaining real TradingView Strategy Tester fills and broker positions. It is an execution-semantics change only; all inputs and strategy thresholds keep their prior names, groups, defaults, meanings, and Long/Short symmetry.

### Changed

- **One confirmed-close decision source** — Entry, Stop/BE, Trend Fail, Timeout, Trim, and Final are evaluated only on the normal `barstate.isconfirmed` 15m execution. `calc_on_order_fills` recalculations synchronize broker transitions only.
- **Next-tick real execution** — `process_orders_on_close = false`, `calc_on_every_tick = false`, and `pyramiding = 0` remain fixed. Entry uses `MR-L` / `MR-S`; every reduction and full exit uses `strategy.close(..., immediately = false)` and therefore fills at the next available tick.
- **Close-confirmed risk and targets** — frozen Risk, Trim, and Final prices are decision thresholds. Normal lifecycle management no longer maintains intrabar stop/limit orders, `strategy.order`, `strategy.exit`, OCA reduce groups, or `MR-L/MR-S-STOP/TRIM/FINAL` order IDs.
- **Real partial fill synchronization** — Trim submits `qty_percent = trimPct` (default 50%). `partialTaken` changes only after `strategy.position_size` really shrinks; the lifecycle resets only after the broker position reaches zero.
- **Strict phase separation** — the Entry fill bar is synchronization-only (`bar_index > entryBar` for management). After a real Trim fill, BE/Final management waits until `bar_index > partialBar`, preventing Entry → exit and Trim → BE/Final same-bar jumps.
- **Restored Entry band reclaim** — `requireBandReclaim` now uses `close > mean15 - entryZ * safeStd` for Long and the mirrored upper boundary for Short. The Z crossover reclaim remains mandatory; residual momentum is not substituted.
- **Shock funnel diagnostics** — Data Window adds cumulative confirmed-close counts for Z candidates, move candidates, environment pass, deceleration pass, rejection pass, setups, and confirmed entries.

### Preserved

- Range/Shock Setup formulas and Shock priority, Regime Score, Hard Trend Veto, Half-Life, Trend Fail, Timeout, frozen mean/std/ATR/time stop, Tight/Balanced/Loose stop construction, BE cost estimate, cross-date positions, Range/Shock lifecycle statistics, recovery guards, and all existing input defaults remain unchanged.
- Strategy Tester remains the formal source for net profit, max drawdown, profit factor, win rate, fills, and positions.

### Verification

- `tests/MRT-v3.1.0-confirmed-close-harness.ps1` covers Long/Short Entry, Entry-bar exclusion, real Trim phase transitions, Final, Stop, BE, Trend Fail, Timeout, cross-date holding, broker/lifecycle consistency, zero recovery on normal paths, Shock diagnostics, parameter defaults, and absence of intrabar bracket orders.
- Static review and `git diff --check` are required before release.
- TradingView Pine v6 compilation, Strategy Tester runtime behavior, and Bar Magnifier OFF/ON comparison remain pending manual verification.

## [3.0.3] — Broker/fill-state consistency patch

This release keeps the v3.0.2 fill-recalculation model and `varip MRFillState`, then adds strong consistency checks against the Strategy Tester broker position and hardens protective exit quantities.

### Fixed

- **Broker/lifecycle invariant** — `strategy.position_size` and `strategy.position_avg_price` remain the final broker facts; active, pending, and frozen lifecycle state is classified against them on every execution.
- **Stale, orphan, and reversal recovery** — stale active-flat state is cleared without normal exit attribution; orphan broker positions and direct Long↔Short reversals cancel outstanding MR orders and close the unknown net position with `strategy.close_all()` instead of silently reinitializing it.
- **Direct reversal detection** — cross-zero transitions such as `-100 -> +20` and `+100 -> -20` are explicit `DIRECT_REVERSAL` errors, not unhandled `positionChanged` events.
- **Protective exit quantity correctness** — STOP, TRIM, and FINAL quantities are clamped to the current absolute broker position, so stale `entrySize` cannot independently over-exit or reverse the net position. The staged `strategy.order` + OCA reduce structure remains because the first stage needs a full STOP and partial TRIM concurrently; all order paths are gated by a valid frozen trade context.
- **Truthful display and diagnostics** — T-trim/T-close/Risk lines disappear when broker and lifecycle state disagree. Panel and Data Window now expose broker position/average, FillState direction, consistency state, reversal detection, recovery count, active protective quantities, and a numeric latest closed exit ID.

### Unchanged behavior

- `allowLong = true`, `allowShort = true`, cross-date positions, Range/Shock engines, Regime Score, Hard Trend Veto, Half-Life, Trend Fail, Timeout, 50% default Trim, Final, BE, all existing strategy parameters, and `calc_on_order_fills = true` remain unchanged.
- Range/Shock statistics count only normal lifecycle Entries, Full Exits, and Wins; state recovery does not add or duplicate Closed/Wins.

### Verification

- `tests/MRT-v3.0.3-consistency-harness.ps1` covers normal Long/Short, Stop, Trim→BE, stale, orphan, direct reversal, and protective-quantity scenarios.
- Static review and `git diff --check` are required before release.
- TradingView Pine v6 compilation, Strategy Tester runtime behavior, and Bar Magnifier OFF/ON comparison remain pending manual verification.

## [3.0.2] — Intrabar fill-state correctness patch

This release fixes rollback-sensitive Strategy Tester fill synchronization. Trading
signals, parameters, order IDs, and strategy behavior are unchanged.

### Fixed

- **Rollback-safe repeated fill executions** — a dedicated `MRFillState` uses
  field-level `varip` persistence for the real trade lifecycle, including frozen
  context, BE state, pending close reason, and Range/Shock auxiliary statistics.
- **Position-transition fill detection** — Entry, Trim, and Full Exit are derived
  from adjacent `strategy.position_size` executions. `pendingDir` remains signal
  context only and is no longer the final Entry-fill predicate.
- **Trim / BE / Full Exit continuity** — Entry -> Trim, Entry -> Stop, and
  Trim -> BE on the same bar preserve the original entry context, record one
  lifecycle event each, and reset the trade state only after the real position
  reaches zero.
- **Trim attribution guard** — `strategy.closedtrades.exit_id()` is used when a
  closed fragment is exposed; the fallback requires an active Trim order and the
  exact configured Trim quantity, so an arbitrary position reduction is not
  treated as T-trim.

### Unchanged behavior

- `calc_on_order_fills = true`, `process_orders_on_close = false`, `pyramiding = 0`,
  both Long and Short directions, cross-date positions, and all existing default
  parameters remain unchanged.
- Range/Shock engines, Regime Score, Hard Trend Veto, Half-Life, Trend Fail,
  Timeout, ATR/statistical stop, T-trim, T-close, BE, OCA reduce order groups,
  fixed order IDs, and the next-bar-before-Final rule remain unchanged.

### Verification

- Static review and `git diff --check` are required before release.
- TradingView Pine v6 compilation and Strategy Tester runtime verification remain
  pending manual verification, including Bar Magnifier OFF / ON comparison.

## [3.0.1] — Correctness patch

This release is a correctness patch for the Strategy Tester execution lifecycle. The trading strategy and its parameters are unchanged.

### Fixed

- **Isolated fill synchronization from bar-close decisions** — with `calc_on_order_fills = true`, executions caused by actual Entry, Trim, or final Exit fills now synchronize Strategy Tester state and maintain protective orders only. Setup, Entry Confirmation, Trend Fail, and Timeout decisions require the normal confirmed-bar decision phase; `barstate.isconfirmed` alone is not treated as sufficient on historical fill executions.
- **Range/Shock attribution denominators** — auxiliary statistics now track Entries, Closed positions, and Wins separately. Range/Shock win rates use `Wins / Closed`, while formal Net Profit, Max Drawdown, Profit Factor, Win Rate, and Closed Trades remain Strategy Tester values.

### Unchanged behavior

- Positions and pending mean-reversion setups may continue across trading dates; there is no session-end or new-day forced exit.
- Both Long (`MR-L`) and Short (`MR-S`) remain enabled by default.
- Range and Shock engines, real staged exits, OCA reduce orders, post-Trim breakeven protection, and the next-bar-before-Final rule remain in place.

## [3.0.0] — Strategy Tester release

MR-T is upgraded from a signal indicator with virtual position bookkeeping to a directly backtestable TradingView `strategy()`.

### Added

- **Real strategy orders** — confirmed-bar signals submit the fixed entry IDs `MR-L` and `MR-S`; `pyramiding = 0` and a pending-entry guard keep the model single-direction and single-position.
- **Standard execution model** — `process_orders_on_close = false` preserves the close-confirmed signal → next available tick fill flow. After the fill, `strategy.position_avg_price` becomes the entry-price source.
- **Real partial exits** — new `trimPct` input (default 50%) closes the first target with an OCA reduce order group; the final target is submitted only after the partial position reduction is observed.
- **Strategy risk orders** — ATR/statistical stops, post-trim breakeven, final targets, Trend Fail, and Timeout are connected to Strategy Tester orders. Trend Fail and Timeout use `strategy.close()` after cancelling pending price orders.
- **Tester-first performance** — the panel uses `strategy.netprofit`, `strategy.max_drawdown`, `strategy.closedtrades`, and `strategy.wintrades`; the v2 virtual P&L fields were removed from formal reporting.
- **Range/Shock attribution** — auxiliary counts and win counts track the two engine modes while leaving formal performance to Strategy Tester.
- **Cost inputs and alert routing** — `commissionBps` and `slippageTicks` keep breakeven estimates aligned with the Strategy Tester Properties tab. `alert()` covers lifecycle events and every strategy order includes a dynamic `alert_message`.

### Changed

- **Independent `requireBandReclaim`** — when enabled, the Z-score reclaim must also be accompanied by residual movement toward the mean; it no longer repeats the same current-bar Z-band inequality. `requireCandleConfirm` remains the separate raw-close direction check.
- **Frozen trade context** — mean, standard deviation, ATR, targets, and base stop are captured from the confirmed signal context and initialized against the actual strategy fill. Chart lines use the same frozen levels as the orders.
- **Sequential lifecycle** — T-close is not submitted until the actual T-trim has reduced the position, and it is delayed until the next bar so a single bar cannot jump directly from entry to final target.
- **Documentation** — both READMEs now describe Strategy Tester installation, execution timing, real partial exits, cost configuration, alerts, and validation steps.

### Notes

- Pine requires the `strategy()` commission/slippage defaults to be compile-time values. The script defaults to `0.03%` commission per order (3 bp/side) and `0` slippage ticks; if Properties are changed, update the matching inputs used by breakeven calculations.
- `calc_on_order_fills = true` is enabled so the actual fill average is available before the first protective price order is placed. Historical results should be checked with the selected broker-emulator and Bar Magnifier assumptions.

## [2.0.0] — Production rewrite

The "9 分版" (ninth tuning iteration, previously internal) is now released as a production-grade, open-source, bilingual indicator.

### Added
- **Direction-parameterized state machine** — all position/setup/trade state collapsed into a single `MRState` object (`type`), with `+1/-1` direction parameters driving one shared `f_enter` / `f_exit` / `f_manage`. Removes ~200 lines of mirror-image long/short duplication (was the top structural risk: any fix had to be applied twice).
- **Single setup slot** — long/short setup state merged (they were mutually exclusive by construction); same-direction replacement blocked, opposite-direction flip preserved.
- **Cost-aware virtual P&L** — new `costBps` input (round-trip cost per side). Panel now shows last-trade and cumulative net P&L (ATR & %). Breakeven after trim is offset by round-trip cost, so "T-BE" is genuinely flat after fees.
- **Bilingual runtime UI** — new `lang` input (`zh` / `en`) switches the panel, chart labels, and runtime error messages via `f_tr()`. Alert messages and input labels are **bilingual-static** — Pine pins their text to compile-time `const string`, so they cannot switch at runtime (see the CE10123 fix below).
- **Versioning** — `SCRIPT_VERSION = "2.0.0"` displayed in the panel; `CHANGELOG.md`; bilingual `README` (EN + 中文); Mozilla Public License 2.0.
- **TradingView publishing kit** — `docs/tradingview-publish.md` with an English title, a standalone originality/usage description, and a House-Rules compliance checklist.

### Fixed
- **Trim/close lifecycle jump** — previously a single bar reaching both the trim and the close target closed the trade without ever recording the trim (final was checked before partial). Close is now gated on `partialTaken`, so the lifecycle always runs `T-trim → T-close`.
- **Dead breakeven condition** — removed the always-true clause in the BE classification.
- **Duplicated higher-timeframe helpers** — `f_prevER` / `f_prevSlopeATR` replaced by thin `[1]` wrappers over the shared `f_er` / `f_slopeATR` (identical HTF repaint-safety semantics, one source of truth).
- **Identical long/short deceleration expressions** — merged into a single `shockDecelerating`.
- **CE10088 event routing** — one-bar display events are no longer written from inside functions (Pine forbids reassigning *any* global scalar in a function, `var` or not; only object fields are writable). `f_enter` / `f_exit` / `f_manage` now record events onto `MRState` capture fields (`eventKind` / `eventDir` / `eventReason`), which the global scope derives back into the event series.
- **CE10123 const-string bounds** — `plotshape` `text` and `alertcondition` `message` require compile-time `const string`, so dynamic language switching is impossible there. Chart labels now use `label.new` (its `text` is `series string`, so `f_tr()` works); alert messages are bilingual literals; `f_tr` parameters are `simple string` so it stays usable in `simple`/`series` contexts.
- **`max_labels_count` stays at the 500 ceiling** (Pine rejects higher values, CE10178).

### Changed
- Setup/entry/exit **events consolidated** from 20 booleans into typed one-bar events (`setupEvent*`, `entryEvent*`, `partialEvent*`, `exitEvent*` + `exitReason`), so every plot label and alert derives from one source.
- `activeStop` (incl. breakeven offset) computed once in `f_activeStop` and shared by management logic and the risk-line plot.
- Internal variable renames to match the object model (no behavioral intent change).

### Notes
- All 60 prior input parameters are **preserved** — the parameter surface is unchanged.
- Input *labels* remain Chinese (Pine input titles are compile-time `const string` and cannot be localized by a runtime toggle). Runtime UI is fully bilingual.

## [1.0.0] — "9 分版" (9th tuning iteration, pre-release)

Final pre-release tuning of the dual-engine design on 15m. This version is superseded by the 2.0.0 production rewrite; no changelog was kept for earlier tuning iterations.
