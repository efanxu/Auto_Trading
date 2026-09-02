# Auto_Trading 当前状态

## 项目当前结构

```text
Auto_Trading/
├─ tradingview_pine/
└─ python_ml_backtest/
```

`tradingview_pine/` 保存现有 MR-T / MR-T Event Contract Pine 路线，保持独立维护。

`python_ml_backtest/` 是新的正式 Python ML/DL Event Contract 研究路线，当前已建立公共配置、package 骨架、模型接口、统一 CLI 和最小测试基础。

## 当前正式研究目标

```text
BTC 1m
→ 30min direction probability prediction
→ probability calibration
→ Signal State Machine
→ fixed-expiry Event Contract
→ walk-forward evaluation
```

最终模型尚未选择。第一批计划模型为 Logistic Regression、LightGBM、XGBoost 和 TCN；Logistic 是最低复杂度基线，LightGBM 是第一主力模型。

## 当前稳定协议

- 数据内部统一使用 UTC，基线 interval 为 `1m`。
- 目标为 `P(price_(t+30min) > price_t)`，相等按 down 处理。
- 当前实验协议使用 walk-forward，purge 为 30 分钟，prediction frequency 为 1 分钟。
- 校准方法的公共枚举为 `none`、`platt`、`isotonic`；当前为 `none`。
- Event Contract stake 为 5 USDT，winning total return 为 9.25 USDT，win net 为 4.25 USDT，loss net 为 -5 USDT。
- Event payout 的 break-even win rate 为 `5 / 9.25 = 54.054054...%`。
- Signal threshold、cooldown 和 re-arm 参数当前保持 unresolved (`null`)，不把未经验证的数值写成正式策略参数。
- 所有模型必须通过公共概率接口和公共数据、标签、split、calibration、signal、backtest、evaluation 与结果路径接入。

## 当前已完成内容

- 根目录项目规则、当前状态文档和 Python 模型接入规范。
- `configs/experiment.yaml` 公共实验协议及解析、字段校验和 payout 派生值。
- `src/auto_trading/` 的稳定 package 目录边界。
- `ProbabilityModel` / `DataInfo` 公共接口和空模型 registry loader。
- `scripts/run.py` 的 `--help`、`show-config` 和 `check` 命令。
- 安装配置、最小配置/接口/CLI/governance 测试。

## 当前限制

- 尚未下载或接入 BTC 数据。
- 尚未实现正式特征工程、Label Builder、时间 split/walk-forward、概率校准、Signal State Machine、Event Backtester 或结果汇总。
- 尚未选择或实现 Logistic Regression、LightGBM、XGBoost、TCN 等具体模型。
- 当前 `check` 中无数据是正常状态，会报告 `DATA = NOT_CONFIGURED`，不视为失败。
- TradingView/Pine 路线与 Python 路线执行系统相互独立。

## 下一步

先补充不泄漏的 Data/Label/Feature/Split 公共路径和最小时间因果测试，再实现 Logistic 最低复杂度基线，随后接入 LightGBM。每一步都沿固定验收顺序推进。

## 重要陷阱

- Test set 不能参与模型、特征、阈值、校准或策略选择。
- Label Builder 之外的路径不能读取未来价格；特征时间必须满足 `timestamp <= t`。
- purge 至少覆盖最大预测 horizon；不能用随机 split 替代正式时间 split。
- scaler、calibration 和 threshold 都必须在各自允许的训练/验证数据上拟合或选择。
- Prediction frequency 不等于 Entry frequency；重复 Event、expiry 和 payout 必须由公共路径管理。
- 未经验证的 signal threshold 继续保持 `null`。

Git history 是历史来源；本文件后续只在原章节内更新当前真实状态，不追加逐日维护日志。
