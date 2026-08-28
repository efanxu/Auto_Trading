# Changelog

All notable changes to **Mean Reversion T (MR-T)** are documented here. Versioning follows [Semantic Versioning](https://semver.org/).

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
