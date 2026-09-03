# Python 模型接入索引

这是 Python ML Event Contract 路线新增模型时的唯一入口。当前公共输入协议同时支持 5m fine、30m coarse 和 30m decision/event horizon；新增模型先读完本文件，再按共享路径检查公共协议和边界。

## 共享路径阅读顺序

```text
1. PROJECT_RULES.md
2. HANDOFF.md
3. python_ml_backtest/configs/experiment.yaml
4. python_ml_backtest/src/auto_trading/runtime/config.py
5. python_ml_backtest/src/auto_trading/data/
6. python_ml_backtest/src/auto_trading/features/（包括 `FeatureView`、`price_5m_v1` 和 `price_multires_v1`）
7. python_ml_backtest/src/auto_trading/labels/
8. python_ml_backtest/src/auto_trading/splits/
9. python_ml_backtest/src/auto_trading/models/base.py
10. python_ml_backtest/src/auto_trading/models/loader.py
11. python_ml_backtest/src/auto_trading/calibration/
12. python_ml_backtest/src/auto_trading/signals/
13. python_ml_backtest/src/auto_trading/backtest/
14. python_ml_backtest/src/auto_trading/evaluation/
15. python_ml_backtest/src/auto_trading/results/
16. python_ml_backtest/src/auto_trading/cli/
17. python_ml_backtest/scripts/run.py
```

目录名称和 package 名称是长期稳定的公共边界。模型不应绕过这些路径直接读取数据、选择策略或写结果。

## 普通模型只负责什么

一个普通模型原则上只增加：

```text
src/auto_trading/models/<model_name>/model.py
configs/models/<model_name>.yaml
```

模型构造器统一为：

```python
def build_model(model_config, data_info):
    ...
```

构造器通过 `models.loader.build_model(model_name, model_config, data_info)` 被公共运行时调用。模型实现公共 `ProbabilityModel` 接口的 `fit(x, y, *, validation: ValidationData | None = None)` 和 `predict_proba(x)`，只返回 `P(next_bar_close > next_bar_open)`。其中 `ValidationData(x, y)` 提供可选的验证数据容器用于 early stopping。

## 模型明确不拥有的职责

模型模块不得拥有：

```text
数据 split
标签构造
特征构造
概率校准
threshold selection
Signal State Machine
Event P&L
结果目录
CLI
summarization
```

scikit-learn、LightGBM、XGBoost 和 PyTorch 模型都必须适配相同的概率接口；公共 base 不假设模型是神经网络，也不绑定某一个训练框架。

## 接入步骤

1. 阅读上面的共享路径并确认输入、目标、split、purge 和时间因果协议。
2. 只在模型目录实现构造器和模型自身的 fit/predict_proba 行为。
3. 在 `configs/models/` 放置模型结构参数；公共实验参数仍留在 `configs/experiment.yaml`。
4. 通过空 registry 的公共 loader 注册模型，不创建第二套入口或训练流程。
5. 先确认 B0 的 data、label、split contract 已通过，再完成接口级 Dummy/小样本测试，随后按固定验收顺序推进 smoke、calibration、signal、backtest、walk-forward 和 repeatability。
6. 运行 `python scripts\run.py check`、`python scripts\run.py data-check` 及相关测试，确认模型没有拥有公共职责。

## 固定验收顺序

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

B0 已完成 `CONFIG_CHECK`、`DATA_PREFLIGHT`、`LABEL_CAUSALITY`、`SPLIT_CHECK`、`INTERFACE_SMALL` 和 `CLI_CHECK`。B1 增加了 5m preflight、5m/30m alignment、fine/multi-resolution causality、common-sample equality 和 monthly Validation diagnostics。B0-C 及未来模型不能跳过前置的数据因果和 split 检查。

## B1 FeatureView 接入协议

B1 的公共 View 由 `auto_trading.features.views.resolve_feature_view()` 解析，Trainer 不再固定依赖 `PRICE_OHLC_V1_FEATURE_NAMES`：

```text
B1-C   FeatureView(name=B1-C, feature_set=price_ohlc_v1)       34 × c30_*
B1-F   FeatureView(name=B1-F, feature_set=price_5m_v1)         49 × f5_*
B1-MR  FeatureView(name=B1-MR, feature_set=price_multires_v1)  83 × (c30_* + f5_*)
```

`FeatureView.feature_names` 是模型唯一需要学习的列 contract；`validity_column`/`eligibility_column` 描述可用性，`groups` 描述 feature importance 聚合。B1-C、B1-F、B1-MR 都使用相同的 `common_eligible` 样本（`label_valid AND coarse_feature_valid AND fine_feature_valid`），并通过 `runtime/trainer.py` 的同一套 chronological Train-fit/Train-ES、early stopping、formal refit、Validation metrics 和 Test sealing 路径运行。

历史 B0-C 仍通过 Trainer 的 legacy 34-column view 使用原始 `price_ohlc_v1` artifact，不能用 B1-C common-control 结果替换历史 B0-C。

## B1 artifact 与 Test sealing

`scripts/run.py compare-features --model lightgbm --run-id <id>` 只编排三个 View，不实现第二套 Trainer。每个 variant 的结果目录应包含 `resolved_model_config.yaml`（实际 `best_iteration`/`n_estimators`/`n_jobs`/seed）、`metrics_validation_monthly.csv` 和 `feature_group_importance.json`；正式路径不得生成 `metrics_test.json` 或 `predictions_test.parquet`。非空 run directory 默认拒绝覆盖，重复实验必须使用新 run-id。

## 文档影响

- 普通模型参数变化只改模型 YAML、模型代码和测试。
- 公共接口变化改本索引。
- 用户入口变化改 README。
- 当前状态变化改根 `HANDOFF.md`。
- 稳定项目准则变化才改 `PROJECT_RULES.md`。

历史由 Git commit 记录；本索引描述当前仍有效的接入协议，不承载逐日实验日志。
