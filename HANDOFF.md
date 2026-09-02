# Auto_Trading 当前状态

## 项目当前结构

```text
Auto_Trading/
├─ tradingview_pine/
└─ python_ml_backtest/
   ├─ configs/experiment.yaml
   ├─ data/raw/                 # 本地 Binance archive，不进 Git
   ├─ data/processed/           # 本地 parquet/report，不进 Git
   ├─ scripts/run.py            # 唯一公共入口
   └─ src/auto_trading/
      ├─ data/
      ├─ labels/
      └─ splits/
```

`tradingview_pine/` 保存现有 MR-T / MR-T Event Contract Pine 路线，保持独立维护。

`python_ml_backtest/` 是新的正式 Python ML/DL Event Contract 研究路线。

## 当前正式研究目标

```text
Binance BTCUSDT Index Price 30m
→ causal next-bar Event labels
→ chronological 8:1:1 split with purge
→ B0-C LightGBM probability baseline
→ calibration / Signal State Machine / Event Contract evaluation
```

## 当前稳定协议

- 数据源为 Binance 官方 `data.binance.vision` USD-M Futures `indexPriceKlines`，symbol 为 `BTCUSDT`，interval 为 `30m`，内部统一使用 UTC。
- 固定研究区间为 `2020-01-01` 至 `2026-08-31`（包含截止日），canonical 字段为 `open_time/open/high/low/close/close_time`。
- 对 bar `t`，prediction time 为 `close_time[t]`；entry 使用 `open[t+1]`，expiry 使用 `close[t+1]`。`next open` 必须是下一根 30m boundary。
- Event direction 为 `UP=+1`、`DOWN=-1`、`FLAT=0`。`target_up` 为 UP/DOWN 的 `1/0`，FLAT 为 null；`label_valid` 对 FLAT 为 false。
- 正式 split 为按 `prediction_time` 排序的 chronological 80%/10%/10%，无 shuffle；Train→Validation 和 Validation→Test 均 purge 30 分钟。
- Event payout 为 stake `10 USDT`、winning total return `18.5 USDT`、win net `+8.5 USDT`、loss net `-10 USDT`；break-even win rate 为 `10 / 18.5 = 54.054054...%`。
- Signal threshold、cooldown 和 re-arm 参数继续保持 unresolved (`null`)，不把未经验证的数值写成正式策略参数。
- 所有模型必须通过公共概率接口和公共 Data、Label、Split、calibration、signal、backtest、evaluation 与结果路径接入。

## B0 当前已完成内容

- B0-A 已接入官方 Binance archive URL、`.CHECKSUM` SHA-256 校验、重复运行复用、临时文件原子替换、ZIP/CSV 解析和 canonical parquet 生成。
- B0-A 实际下载了 `2020-01-01` 至 `2026-08-31` 的 80 个官方 monthly archives；canonical 数据为 `116256` 行，duplicates `0`，gap ranges `9`。
- canonical data report 已生成：首个 open time `2020-01-01T00:00:00Z`，最后 close time `2026-08-31T23:59:59.999000Z`。
- B0-B 已实现 next-bar Event labels、gap 前样本 `missing_next_bar` 审计、FLAT 保留、`target_up` nullable binary label，以及 chronological split/purge。
- 实际 Event report：candidate `116256`、valid `116246`、invalid `10`、FLAT `5`、purged `2`；Train `92995`、Validation `11624`、Test `11625`。
- purge 后正式样本共 `116244` 行，actual ratios 为 Train `0.7999982795`、Validation `0.0999965590`、Test `0.1000051616`。
- 实际 split prediction time 区间：Train `2020-01-01T00:29:59.999000Z`–`2025-05-03T13:29:59.999000Z`；Validation `2025-05-03T14:29:59.999000Z`–`2025-12-31T17:59:59.999000Z`；Test `2025-12-31T18:59:59.999000Z`–`2026-08-31T23:29:59.999000Z`。
- `data-check` 已通过 `DATA_PREFLIGHT`、`LABEL_CAUSALITY`、`SPLIT_CHECK` 和 `DATA_CHECK`。
- deterministic contract tests 覆盖 URL、checksum、CSV/UTC、duplicate/conflict、gap/OHLC、label off-by-one、FLAT、gap label、split purge、payout 和 CLI；当前 `pytest` 全部通过。

## 当前限制

- 尚未实现正式特征工程、概率校准、Signal State Machine、Event Backtester、结果汇总或 LightGBM 训练。
- Test set 不参与模型、特征、阈值、校准或策略选择。
- raw archive、processed parquet 和 JSON report 是本地运行产物；只提交代码、配置、测试和文档。
- TradingView/Pine 路线与 Python 路线执行系统相互独立。

## 下一步

实现 `B0-C LightGBM Probability Baseline`：price-only feature engine、LightGBM、validation early stopping、probability metrics、validation threshold selection，以及 Test Event Contract evaluation。

## 重要陷阱

- Label Builder 是唯一允许读取下一根 bar 的路径；feature 时间必须满足 `timestamp <= t`。
- gap 不得用 forward-fill/backward-fill 制造 Index Price；gap 前的 bar 不得错误连接到更晚的 bar。
- FLAT 必须保留为 `target_direction=0`，不能在 LightGBM binary training 中静默当作 DOWN；未来 Event Backtester 再按 Long/Short + FLAT = Loss 处理。
- purge 必须覆盖最大预测 horizon；训练、验证、测试事件窗口不得重叠。
- scaler、calibration 和 threshold 都必须在各自允许的训练/验证数据上拟合或选择。
- `prediction frequency` 不等于 `Entry frequency`；重复 Event、expiry 和 payout 必须由公共路径管理。

Git history 是历史来源；本文件只记录当前真实状态，不追加逐日维护日志。
