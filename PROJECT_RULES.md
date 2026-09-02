# Auto_Trading 项目准则

## 六条核心规则

1. 时间因果优先于模型精度。
2. Test set 不参与任何模型、特征、阈值、校准或策略选择。
3. 模型只输出预测概率，不拥有交易规则。
4. Prediction frequency 与 Entry frequency 分离。
5. 所有模型共享同一数据、标签、split、calibration、Signal State Machine、Event Backtester 和结果协议。
6. 新功能复用公共路径，训练、回测、配置和结果系统均保持单一实现。

## 稳定职责边界

### Data Layer

负责原始数据读取、timestamp、OHLC/V、数据完整性、时区和缺口识别。项目内部统一使用 UTC。

### Feature Layer

在时刻 `t` 生成的所有特征只能使用 `timestamp <= t` 的信息。特征工程不得读取未来数据。

### Label Layer

Label Builder 是唯一允许读取未来 `t+h` 数据的模块。当前正式 30min 标签为：

```text
y_t = 1 if P_(t+30min) > P_t
y_t = 0 otherwise
```

相等按下跌/失败处理。

### Split Layer

正式实验只允许 time-ordered split 或 walk-forward。训练、验证、测试边界必须根据最大预测 horizon 设置 purge，避免窗口重叠造成泄漏。

### Model Layer

统一目标为：

```text
X_t -> P(price_(t+30min) > price_t)
```

模型只实现拟合和概率预测，返回概率，不直接产生 Long、Short 或 NoTrade。

### Calibration Layer

统一管理 `none`、`platt` 和 `isotonic`。校准器只允许使用 validation 数据拟合；Test set 只能用于最终报告。

### Signal Layer

统一负责 probability threshold、threshold crossing、cooldown、re-arm、duplicate suppression，以及 Long / Short / NoTrade 决策。模型代码不拥有这些规则。

### Backtest Layer

统一拥有 Event Contract 收益模型和事件生命周期。当前基线为：

```text
Stake = 5 USDT
Winning total return = 9.25 USDT
Win net = +4.25 USDT
Loss net = -5.00 USDT
Break-even Win Rate = 5 / 9.25 = 54.054054...%
```

### Evaluation Layer

结果至少分为 Model Metrics、Probability / Calibration Metrics、Signal Metrics 和 Event Contract Metrics。正式策略结论不能只依赖 Accuracy。

## 最小必要验证

新增验证前必须能回答：

1. 它防止什么具体错误？
2. 现有测试为何无法覆盖？
3. 验证结果由哪个代码路径消费？

验证重点包括未来数据泄漏、timestamp 非单调、重复 timestamp、数据 gap、train/val/test 重叠、scaler 泄漏、calibration 泄漏、threshold 泄漏、label horizon 错误、重复 Event、Event expiry 错误和 payout 数学错误。

## 固定验收顺序

正式研究按以下顺序推进，不跳过前置阶段：

```text
DATA_PREFLIGHT
→ LABEL_CAUSALITY
→ FEATURE_CAUSALITY
→ SPLIT_CHECK
→ INTERFACE_SMALL
→ SMOKE
→ CALIBRATION_CHECK
→ SIGNAL_STATE_CHECK
→ BACKTEST_SMALL
→ WALK_FORWARD
→ REPEATABILITY
→ FORMAL
```

当前阶段只完成 `CONFIG_CHECK`、`INTERFACE_SMALL` 和 `CLI_CHECK`；数据、特征、标签、校准、信号、回测和正式 walk-forward 尚未进入实现阶段。

## 文档与工作区规则

- `HANDOFF.md` 是仓库唯一的当前状态来源；Git history 负责历史记录。HANDOFF 在原章节内更新，不追加逐日维护日志。
- 普通新增模型主要修改 `src/auto_trading/models/<model>/`、`configs/models/<model>.yaml` 和必要测试。
- 公共模型接口改变时更新 `python_ml_backtest/MODEL_INTEGRATION_INDEX.md`。
- 用户入口变化时更新根 `README.md` 或 Python 工作区 README。
- 项目当前状态变化时更新 `HANDOFF.md`。
- 只有稳定项目原则改变时才更新 `PROJECT_RULES.md`。
- Python ML 工作区只有一个公共入口：`python_ml_backtest/scripts/run.py`。未来的 train、evaluate、backtest、summarize 和 repeatability 都扩展到这个入口。
- `tradingview_pine/` 是已有独立工作区。本阶段不修改 `MRT.pine`、`MRT_V4.pine` 或 `MRT_EVENT.pine` 的策略逻辑；Python 框架不依赖 Pine 内部实现。
