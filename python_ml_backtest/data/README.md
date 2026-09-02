# Data

B0 使用 Binance 官方 USD-M Futures BTCUSDT Index Price 30m 数据。运行产物分别保存到：

```text
raw/binance/futures/um/indexPriceKlines/BTCUSDT/30m/
processed/
```

大型 raw archive、canonical parquet、sample parquet 和 JSON report 均被 `.gitignore` 忽略。小型 deterministic fixtures 应放在 `tests/fixtures/`，不让普通 pytest 依赖互联网。
