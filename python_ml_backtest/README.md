# Python ML Event Contract Backtest

本工作区用于使用 BTC 分钟级数据研究固定期限 Event Contract。当前阶段建立长期稳定的公共研究基础，不实现最终模型或正式 Python 回测逻辑。

公共模型接入流程见 [MODEL_INTEGRATION_INDEX.md](MODEL_INTEGRATION_INDEX.md)。仓库级准则和当前状态分别见 [../PROJECT_RULES.md](../PROJECT_RULES.md) 与 [../HANDOFF.md](../HANDOFF.md)。

## Research pipeline

```text
BTC 1m Index Price
→ Feature Construction
→ ML / DL probability prediction
→ Signal State Machine
→ 30min Event Contract
→ Walk-forward Backtest
```

核心研究对象暂定为 **30min Event Contract**。

## Event payoff model

```text
Stake = 5 USDT
Winning total return = 9.25 USDT
Win  = +4.25 USDT
Loss = -5.00 USDT
Break-even Win Rate ≈ 54.05%
```

## Research principles

`Prediction frequency ≠ Entry frequency`

模型未来可以每分钟更新输入并每分钟推理，但交易必须经过独立的 Signal State Machine，避免连续分钟重复产生同一机会的入场。

第一版只记录研究方向，不制定最终模型。后续再加入特征工程、概率预测、信号状态机和 walk-forward 回测实现。

## Official entry point

```powershell
cd python_ml_backtest

python -m pip install -e .
python scripts\run.py check
python scripts\run.py show-config
```

`scripts/run.py` 是本工作区唯一正式公共入口；未来的 `train`、`evaluate`、`backtest`、`summarize` 和 `repeatability` 都在同一个入口上扩展。
