# Python ML Event Contract Backtest

这个工作区是 Python Event Contract 研究路线的公共数据、标签、split 和模型接口基础。当前正式批次为：

```text
B0-A  Binance BTCUSDT Index Price 30m
B0-B  next-bar Event label + chronological 8:1:1 split
下一步：B0-C LightGBM Probability Baseline
```

## B0 数据协议

数据来自 Binance 官方 `data.binance.vision` USD-M Futures `indexPriceKlines` archive：

```text
symbol       BTCUSDT
interval     30m
timezone     UTC
start_date   2020-01-01
end_date     2026-08-31（包含当天）
```

canonical parquet 只有以下字段，并按 `open_time ASC` 保存：

```text
open_time, open, high, low, close, close_time
```

gap 会被报告但不会 forward-fill/backward-fill。raw archive、canonical parquet、sample parquet 和 JSON report 都是本地运行产物，不提交 Git。

## Event label contract

对完成的 bar `t`，预测时间为 `close_time[t]`，Event 使用紧邻的下一根 bar：

```text
event_entry_time   = open_time[t+1]
event_entry_price  = open[t+1]
event_expiry_time  = close_time[t+1]
event_expiry_price = close[t+1]
```

只有 `open_time[t+1] == open_time[t] + 30min` 才形成正式样本。方向编码为 `UP=+1`、`DOWN=-1`、`FLAT=0`；`target_up` 对 UP/DOWN 分别为 `1/0`，FLAT 为 null，`label_valid` 对 FLAT 为 false。最后一根 bar 和 gap 前的 bar 记录为 `missing_next_bar`，但不进入正式 sample parquet。

有效 Event 按 `prediction_time` 严格排序后以 80%/10%/10% 切分，不 shuffle；Train→Validation 和 Validation→Test 边界 purge 30 分钟。

## Event payoff

```text
Stake = 10 USDT
Winning total return = 18.5 USDT
Win net = +8.5 USDT
Loss net = -10.0 USDT
Break-even Win Rate = 10 / 18.5 ≈ 54.054054%
```

派生 payout 值由公共实现计算，YAML 只保存 stake 和 winning total return。

## Official entry point

```powershell
cd D:\Codes\Auto_Trading\python_ml_backtest

python -m pip install -e .
python scripts\run.py show-config
python scripts\run.py check

python scripts\run.py data-download
python scripts\run.py data-prepare
python scripts\run.py dataset-build
python scripts\run.py data-check
```

产物位置：

```text
data/raw/binance/futures/um/indexPriceKlines/BTCUSDT/30m/
data/processed/btcusdt_index_30m.parquet
data/processed/btcusdt_index_30m_data_report.json
data/processed/btcusdt_index_30m_samples.parquet
data/processed/btcusdt_index_30m_split_report.json
```

模型训练尚未在 B0 实现。所有未来模型继续通过单一 `scripts/run.py`、`experiment.yaml` 和公共 Data / Label / Split / Model 路径接入。
