# Python ML Event Contract Backtest

这个工作区维护 BTCUSDT Index Price 的因果概率预测基础。当前研究批次为：

```text
B0-A  Binance BTCUSDT Index Price 30m
B0-B  next-bar Event label + chronological 8:1:1 split
B0-C  LightGBM Probability Baseline（历史冻结基线，Test SEALED）
B1    Multi-Resolution Price Foundation（5m + 30m，Validation only）
```

## 公共实验协议

数据来自 Binance 官方 `data.binance.vision` USD-M Futures `indexPriceKlines`：

```text
symbol          BTCUSDT
fine interval   5m
coarse interval 30m
decision        30m
event horizon   30m
timezone        UTC
start_date      2020-01-01
end_date        2026-08-31（包含当天）
```

30m bar `t` 的预测时间为 `close_time[t]`，Event 使用紧邻的下一根 30m bar：

```text
event_entry_time   = open_time[t+1]
event_entry_price  = open[t+1]
event_expiry_time  = close_time[t+1]
event_expiry_price = close[t+1]
```

Label Builder 是未来信息的唯一 owner。正式 split 为 chronological 80%/10%/10%，无 shuffle，purge 30 分钟。Train 内部再按 90%/10% chronological 划分 Train-fit/Train-ES，并只使用 Train-ES 做 early stopping；Validation 只做一次 out-of-sample 评价，Test 始终 `SEALED`。

Event payout 保持：stake `10 USDT`、winning total return `18.5 USDT`、win net `+8.5 USDT`、loss net `-10 USDT`，break-even win rate 为 `10 / 18.5 ≈ 54.054054%`。

## Feature Views

历史 B0-C 的 `price_ohlc_v1` 34 列保持原名和原 artifact。B1 的 coarse view 在公共融合层映射为 `c30_<original_name>`，fine view 的 49 列全部使用 `f5_` 前缀：

```text
B1-C   34 × c30_*
B1-F   49 × f5_*
B1-MR  83 × (c30_* + f5_*)
```

每个 prediction time 的 fine view 只读取 `close_time_5m <= prediction_time` 的已完成 bar；精确对齐要求最后一根 fine bar 的 `close_time` 等于 30m prediction time。fine 最大历史为 288 个 5m step；真实 gap 不填充，gap 后重新积累连续历史才恢复有效。`multires_feature_valid = coarse_feature_valid AND fine_feature_valid`，并区分 `coarse_history_invalid`、`fine_history_invalid`、`non_finite_feature` 和 `alignment_invalid`。

## Official entry point

```powershell
cd D:\Codes\Auto_Trading\python_ml_backtest
D:\Apps\Miniconda3\envs\auto_trading\python.exe -m pip install -e .

D:\Apps\Miniconda3\envs\auto_trading\python.exe scripts\run.py show-config
D:\Apps\Miniconda3\envs\auto_trading\python.exe scripts\run.py check
D:\Apps\Miniconda3\envs\auto_trading\python.exe scripts\run.py data-download
D:\Apps\Miniconda3\envs\auto_trading\python.exe scripts\run.py data-prepare
D:\Apps\Miniconda3\envs\auto_trading\python.exe scripts\run.py dataset-build
D:\Apps\Miniconda3\envs\auto_trading\python.exe scripts\run.py data-check
D:\Apps\Miniconda3\envs\auto_trading\python.exe scripts\run.py feature-build
D:\Apps\Miniconda3\envs\auto_trading\python.exe scripts\run.py feature-check

D:\Apps\Miniconda3\envs\auto_trading\python.exe scripts\run.py compare-features `
  --model lightgbm `
  --run-id b1_multires_seed2026

D:\Apps\Miniconda3\envs\auto_trading\python.exe -m pytest -q
```

`compare-features` 只负责解析 B1-C/F/MR 并三次调用 `src/auto_trading/runtime/trainer.py`；训练、early stopping、formal refit、metrics 和 result artifact 没有第二套实现。已有非空正式 run directory 默认拒绝覆盖，请使用新的 run-id。

## Local artifacts

raw archive、canonical parquet、sample parquet、feature parquet、model 权重和结果均为本地运行产物，不进入 Git：

```text
data/raw/binance/futures/um/indexPriceKlines/BTCUSDT/{5m,30m}/
data/processed/btcusdt_index_5m.parquet
data/processed/btcusdt_index_5m_data_report.json
data/processed/btcusdt_index_5m_features.parquet
data/processed/btcusdt_index_multires_features.parquet
data/processed/btcusdt_index_multires_feature_report.json
data/processed/btcusdt_index_{30m,5m,multires}_*model_dataset.parquet

results/lightgbm/<run_id>_{coarse,fine,multires}/
  run_info.json
  resolved_config.yaml
  model_config.yaml
  resolved_model_config.yaml
  model.txt
  metrics_validation.json
  predictions_validation.parquet
  reliability_validation.csv
  confidence_validation.csv
  metrics_validation_monthly.csv
  feature_importance.csv
  feature_group_importance.json

results/_runs/<comparison_run_id>/
  feature_comparison.csv
  run_info.json
```

## B1 实际 Validation 结果（seed 2026）

三组使用相同 common samples：Train `92,414`、Validation `11,624`；Test 只保留结构性 common-sample 记录，不用于训练或评价。

```text
                 best_iteration   ROC-AUC    LogLoss     Brier       q=.55 count / hit rate
B1-C coarse              31       0.537058   0.691139   0.248996       2473 / 0.549535
B1-F fine                27       0.534416   0.691405   0.249129       1738 / 0.546605
B1-MR multires           19       0.534028   0.691404   0.249129        574 / 0.536585
```

B1-MR 没有在 AUC、LogLoss、Brier 或 q=.55 selective hit rate 上超过两个单粒度输入，因此本批次不报告明确的 multi-resolution incremental value。月度诊断已分别写入三个 result directory 的 `metrics_validation_monthly.csv`，只用于稳定性检查，不重新调参。
