# Python 模型接入索引

这是 Python ML Event Contract 路线新增模型时的唯一入口。新增模型先读完本文件，再按共享路径检查公共协议和边界。

## 共享路径阅读顺序

```text
1. PROJECT_RULES.md
2. HANDOFF.md
3. python_ml_backtest/configs/experiment.yaml
4. python_ml_backtest/src/auto_trading/runtime/config.py
5. python_ml_backtest/src/auto_trading/data/
6. python_ml_backtest/src/auto_trading/features/
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

构造器通过 `models.loader.build_model(model_name, model_config, data_info)` 被公共运行时调用。模型实现公共 `ProbabilityModel` 接口的 `fit(...)` 和 `predict_proba(...)`，只返回价格方向概率。

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
5. 先完成接口级 Dummy/小样本测试，再按固定验收顺序推进 smoke、calibration、signal、backtest、walk-forward 和 repeatability。
6. 运行 `python scripts\run.py check` 及相关测试，确认模型没有拥有公共职责。

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

本阶段仅完成 `CONFIG_CHECK`、`INTERFACE_SMALL` 和 `CLI_CHECK`。未来模型不能跳过前置的数据因果和 split 检查。

## 文档影响

- 普通模型参数变化只改模型 YAML、模型代码和测试。
- 公共接口变化改本索引。
- 用户入口变化改 README。
- 当前状态变化改根 `HANDOFF.md`。
- 稳定项目准则变化才改 `PROJECT_RULES.md`。

历史由 Git commit 记录；本索引描述当前仍有效的接入协议，不承载逐日实验日志。
