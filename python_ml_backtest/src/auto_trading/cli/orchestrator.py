"""Single public CLI for the Python ML Event Contract workspace."""

from __future__ import annotations

import argparse
from math import isclose
import json
from pathlib import Path
from typing import Any, Sequence

import pandas as pd

from auto_trading.data import (
    BinanceDataError,
    DataValidationError,
    default_b0_data_paths,
    download_archives,
    prepare_interval_data,
    run_data_preflight,
)
from auto_trading.data.storage import atomic_write_json
from auto_trading.features import (
    build_and_persist_features,
    build_and_persist_multires_features,
    run_all_feature_checks,
    run_all_multires_checks,
    run_test_sealing_check,
)
from auto_trading.features.views import resolve_feature_view
from auto_trading.labels import (
    build_persisted_event_dataset,
    run_label_causality_check,
)
from auto_trading.runtime.config import (
    ConfigError,
    calculate_event_payout,
    default_config_path,
    dump_config,
    load_config,
)
from auto_trading.runtime.trainer import load_model_config, run_training_pipeline
from auto_trading.splits import run_split_check


def build_parser() -> argparse.ArgumentParser:
    """Build the public command parser."""

    parser = argparse.ArgumentParser(
        prog="run.py",
        description="Auto_Trading Python ML Event Contract research commands.",
    )
    parser.add_argument(
        "--config",
        dest="global_config",
        type=Path,
        default=None,
        help="Path to experiment YAML (default: configs/experiment.yaml).",
    )
    parser.add_argument("--version", action="version", version="0.1.0")

    commands = parser.add_subparsers(dest="command", metavar="COMMAND")
    commands_and_help = (
        ("show-config", "show the resolved public experiment configuration"),
        ("check", "run current configuration and workspace checks"),
        ("data-download", "download verified official Binance 5m and 30m archives"),
        ("data-prepare", "build canonical 5m and 30m OHLC parquet and reports"),
        ("dataset-build", "build causal Event labels and chronological split"),
        ("data-check", "run 5m/30m data, label, and split contract checks"),
        ("feature-build", "build B0 and B1 causal price feature views"),
        ("feature-check", "run B0/B1 feature causality, schema, and alignment checks"),
    )
    for name, help_text in commands_and_help:
        command = commands.add_parser(name, help=help_text)
        command.add_argument(
            "--config",
            dest="command_config",
            type=Path,
            default=None,
            help="Path to experiment YAML (overrides the global option).",
        )

    train_command = commands.add_parser("train", help="train one probability model through the shared path")
    train_command.add_argument(
        "--config", dest="command_config", type=Path, default=None,
        help="Path to experiment YAML (overrides the global option).",
    )
    train_command.add_argument("--model", dest="model", type=str, default="lightgbm")
    train_command.add_argument(
        "--run-id", dest="run_id", type=str, default="b0c_lightgbm_seed2026",
        help="Unique run identifier for output directory.",
    )

    compare_command = commands.add_parser(
        "compare-features",
        help="train and compare B1-C, B1-F, and B1-MR on common samples",
    )
    compare_command.add_argument(
        "--config", dest="command_config", type=Path, default=None,
        help="Path to experiment YAML (overrides the global option).",
    )
    compare_command.add_argument("--model", dest="model", type=str, default="lightgbm")
    compare_command.add_argument(
        "--run-id", dest="run_id", type=str, default="b1_multires_seed2026",
        help="Unique comparison and model run identifier.",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run one public CLI command and return its process exit code."""

    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 0

    config_path = args.command_config or args.global_config or default_config_path()
    try:
        config = load_config(config_path)
    except ConfigError as exc:
        print(f"CONFIG = FAIL: {exc}")
        return 2

    if args.command == "show-config":
        print(dump_config(config), end="")
        return 0
    if args.command == "check":
        return _run_check(config, config_path)
    workspace_root = Path(__file__).resolve().parents[3]
    if args.command == "data-download":
        return _run_data_download(config, workspace_root)
    if args.command == "data-prepare":
        return _run_data_prepare(config, workspace_root)
    if args.command == "dataset-build":
        return _run_dataset_build(config, workspace_root)
    if args.command == "data-check":
        return _run_data_check(config, workspace_root)
    if args.command == "feature-build":
        return _run_feature_build(config, workspace_root)
    if args.command == "feature-check":
        return _run_feature_check(config, workspace_root)
    if args.command == "train":
        return _run_train(config, workspace_root, args.model, args.run_id)
    if args.command == "compare-features":
        return _run_compare_features(config, workspace_root, args.model, args.run_id)

    parser.error(f"unsupported command: {args.command}")
    return 2


def _run_check(config: dict[str, Any], config_path: Path) -> int:
    workspace_root = Path(__file__).resolve().parents[3]
    repository_root = workspace_root.parent
    checks: list[tuple[str, bool, str]] = []
    checks.append(("CONFIG_READABLE", config_path.is_file(), str(config_path)))

    required_directories = [
        workspace_root / "configs",
        workspace_root / "configs" / "models",
        workspace_root / "scripts",
        workspace_root / "src" / "auto_trading",
        workspace_root / "tests",
        workspace_root / "data",
        workspace_root / "data" / "raw",
        workspace_root / "data" / "processed",
        workspace_root / "results",
    ]
    missing_directories = [
        str(path.relative_to(repository_root))
        for path in required_directories
        if not path.is_dir()
    ]
    checks.append(
        (
            "REQUIRED_DIRECTORIES",
            not missing_directories,
            "present" if not missing_directories else "missing: " + ", ".join(missing_directories),
        )
    )

    data = config["data"]
    intervals = data.get("intervals", {})
    public_configuration_ok = (
        data["source"] == "binance_public_data"
        and data["market"] == "usd_m_futures"
        and data["series"] == "index_price_klines"
        and data["symbol"] == "BTCUSDT"
        and data["interval"] == "30m"
        and intervals.get("fine") == "5m"
        and intervals.get("coarse") == "30m"
        and data["timezone"] == "UTC"
        and config["target"]["entry_price"] == "next_bar_open"
        and config["target"]["expiry_price"] == "next_bar_close"
        and config["target"]["horizon_minutes"] == 30
        and config["target"]["horizon_minutes"] == config["event"]["horizon_minutes"]
        and config["prediction"]["frequency_minutes"] == 30
        and config["split"]["method"] == "chronological"
        and config["split"]["train_ratio"] > 0
        and config["split"]["validation_ratio"] > 0
        and config["split"]["test_ratio"] > 0
        and isclose(
            config["split"]["train_ratio"]
            + config["split"]["validation_ratio"]
            + config["split"]["test_ratio"],
            1.0,
            rel_tol=0,
            abs_tol=1e-12,
        )
        and config["split"]["purge_minutes"] >= config["target"]["horizon_minutes"]
        and config["features"]["set"] == "price_multires_v1"
        and config["features"]["fine_max_lookback_bars"] == 288
        and config["features"]["coarse_max_lookback_bars"] == 48
    )
    checks.append(
        ("PUBLIC_CONFIGURATION", public_configuration_ok, "consistent" if public_configuration_ok else "inconsistent")
    )

    required_paths = [
        repository_root / "PROJECT_RULES.md",
        repository_root / "HANDOFF.md",
        workspace_root / "MODEL_INTEGRATION_INDEX.md",
        workspace_root / "configs" / "experiment.yaml",
        workspace_root / "configs" / "models" / "lightgbm.yaml",
        workspace_root / "scripts" / "run.py",
        workspace_root / "src" / "auto_trading" / "runtime" / "config.py",
        workspace_root / "src" / "auto_trading" / "runtime" / "trainer.py",
        workspace_root / "src" / "auto_trading" / "models" / "base.py",
        workspace_root / "src" / "auto_trading" / "models" / "loader.py",
        workspace_root / "src" / "auto_trading" / "models" / "lightgbm" / "model.py",
        workspace_root / "src" / "auto_trading" / "features" / "price_ohlc_v1.py",
        workspace_root / "src" / "auto_trading" / "features" / "price_5m_v1.py",
        workspace_root / "src" / "auto_trading" / "features" / "multires.py",
        workspace_root / "src" / "auto_trading" / "features" / "views.py",
        workspace_root / "src" / "auto_trading" / "evaluation" / "probability.py",
    ]
    missing_paths = [
        str(path.relative_to(repository_root)) for path in required_paths if not path.is_file()
    ]
    checks.append(
        (
            "MODEL_INTEGRATION_PATHS",
            not missing_paths,
            "present" if not missing_paths else "missing: " + ", ".join(missing_paths),
        )
    )

    event = config["event"]
    payout = calculate_event_payout(event["stake_usdt"], event["winning_total_return_usdt"])
    payout_ok = (
        isclose(event["win_net_profit"], payout.win_net_profit, rel_tol=0, abs_tol=1e-12)
        and isclose(event["loss_net_profit"], payout.loss_net_profit, rel_tol=0, abs_tol=1e-12)
        and isclose(event["break_even_win_rate"], payout.break_even_win_rate, rel_tol=0, abs_tol=1e-12)
    )
    checks.append(("EVENT_PAYOUT_MATH", payout_ok, "resolved" if payout_ok else "incorrect"))

    for name, passed, detail in checks:
        print(f"{name} = {'PASS' if passed else 'FAIL'} ({detail})")
    data_configured = _data_is_configured(workspace_root)
    print(f"DATA = {'CONFIGURED' if data_configured else 'NOT_CONFIGURED'}")
    all_passed = all(passed for _, passed, _ in checks) and payout_ok
    print(f"CONFIG_CHECK = {'PASS' if all_passed else 'FAIL'}")
    print(f"CHECK = {'PASS' if all_passed else 'FAIL'}")
    return 0 if all_passed else 1


def _configured_intervals(config: dict[str, Any]) -> tuple[str, str]:
    data = config["data"]
    intervals = data.get("intervals", {})
    return str(intervals.get("fine", "5m")), str(intervals.get("coarse", data.get("interval", "30m")))


def _run_data_download(config: dict[str, Any], workspace_root: Path) -> int:
    paths = default_b0_data_paths(workspace_root)
    data = config["data"]
    fine_interval, coarse_interval = _configured_intervals(config)
    summaries: list[tuple[str, int, int]] = []
    try:
        for interval in (coarse_interval, fine_interval):
            results = download_archives(
                symbol=data["symbol"],
                interval=interval,
                start_date=data["start_date"],
                end_date=data["end_date"],
                raw_root=paths.raw_root,
            )
            summaries.append((interval, len(results), sum(result.reused for result in results)))
    except (BinanceDataError, OSError, ValueError) as exc:
        print(f"DATA_DOWNLOAD = FAIL ({exc})")
        return 1
    for interval, archives, reused in summaries:
        print(f"DATA_DOWNLOAD_{interval.upper()} = PASS (archives={archives}, reused={reused})")
    print(f"DATA_DOWNLOAD = PASS (intervals={coarse_interval},{fine_interval})")
    print(f"RAW_DIRECTORY = {paths.raw_root}")
    return 0


def _run_data_prepare(config: dict[str, Any], workspace_root: Path) -> int:
    paths = default_b0_data_paths(workspace_root)
    data = config["data"]
    fine_interval, coarse_interval = _configured_intervals(config)
    try:
        _, coarse_report = prepare_interval_data(
            config=config,
            interval=coarse_interval,
            raw_root=paths.raw_root,
            output_path=paths.canonical_parquet,
            report_path=paths.data_report,
        )
        _, fine_report = prepare_interval_data(
            config=config,
            interval=fine_interval,
            raw_root=paths.raw_root,
            output_path=paths.fine_canonical_parquet,
            report_path=paths.fine_data_report,
        )
    except (BinanceDataError, DataValidationError, OSError, ValueError) as exc:
        print(f"DATA_PREPARE = FAIL ({exc})")
        return 1
    print(
        "DATA_PREPARE = PASS "
        f"(coarse_rows={coarse_report['rows']}, fine_rows={fine_report['rows']})"
    )
    print(
        f"5M = rows={fine_report['rows']}, duplicates={fine_report['duplicates']}, "
        f"gaps={fine_report['gaps']}"
    )
    print(
        f"30M = rows={coarse_report['rows']}, duplicates={coarse_report['duplicates']}, "
        f"gaps={coarse_report['gaps']}"
    )
    print(f"CANONICAL_5M = {paths.fine_canonical_parquet}")
    print(f"CANONICAL_30M = {paths.canonical_parquet}")
    return 0


def _run_dataset_build(config: dict[str, Any], workspace_root: Path) -> int:
    paths = default_b0_data_paths(workspace_root)
    try:
        _, report = build_persisted_event_dataset(
            config=config,
            canonical_path=paths.canonical_parquet,
            sample_path=paths.samples_parquet,
            split_report_path=paths.split_report,
        )
    except (BinanceDataError, DataValidationError, OSError, ValueError, KeyError) as exc:
        print(f"DATASET_BUILD = FAIL ({exc})")
        return 1
    print(
        "DATASET_BUILD = PASS "
        f"(candidates={report['total_candidate_events']}, valid={report['valid_events']}, "
        f"flat={report['flat_events']}, purged={report['purged_rows']})"
    )
    print(
        f"SPLIT_ROWS = train={report['train_rows']}, "
        f"validation={report['validation_rows']}, test={report['test_rows']}"
    )
    print(f"SAMPLES = {paths.samples_parquet}")
    return 0


def _run_data_check(config: dict[str, Any], workspace_root: Path) -> int:
    paths = default_b0_data_paths(workspace_root)
    checks: list[tuple[str, bool, str]] = []
    coarse_bars: pd.DataFrame | None = None

    for label, path, interval in (
        ("30M", paths.canonical_parquet, 30),
        ("5M", paths.fine_canonical_parquet, 5),
    ):
        if not path.is_file():
            checks.append((f"DATA_PREFLIGHT_{label}", False, f"missing {path}"))
            continue
        try:
            bars = pd.read_parquet(path)
            report = run_data_preflight(bars, expected_interval_minutes=interval)
            checks.append(
                (
                    f"DATA_PREFLIGHT_{label}",
                    bool(report["passed"]),
                    f"rows={report['total_rows']}, gaps={report['gap_count']}"
                    if report["passed"] else "; ".join(report["issues"]),
                )
            )
            if label == "30M":
                coarse_bars = bars
        except (OSError, ValueError, TypeError) as exc:
            checks.append((f"DATA_PREFLIGHT_{label}", False, str(exc)))

    if coarse_bars is not None and paths.samples_parquet.is_file():
        try:
            samples = pd.read_parquet(paths.samples_parquet)
            label_report = run_label_causality_check(coarse_bars, samples, interval_minutes=30)
            checks.append(
                (
                    "LABEL_CAUSALITY",
                    bool(label_report["passed"]),
                    f"rows={label_report['checked_rows']}"
                    if label_report["passed"] else "; ".join(label_report["errors"]),
                )
            )
            split_report = run_split_check(
                samples,
                train_ratio=float(config["split"]["train_ratio"]),
                validation_ratio=float(config["split"]["validation_ratio"]),
                test_ratio=float(config["split"]["test_ratio"]),
            )
            checks.append(
                (
                    "SPLIT_CHECK",
                    bool(split_report["passed"]),
                    str(split_report.get("counts", {}))
                    if split_report["passed"] else "; ".join(split_report["errors"]),
                )
            )
        except (OSError, ValueError, TypeError) as exc:
            checks.append(("LABEL_CAUSALITY", False, str(exc)))
            checks.append(("SPLIT_CHECK", False, "label dataset could not be checked"))
    else:
        checks.append(("LABEL_CAUSALITY", False, f"missing {paths.samples_parquet}"))
        checks.append(("SPLIT_CHECK", False, f"missing {paths.samples_parquet}"))

    for name, passed, detail in checks:
        print(f"{name} = {'PASS' if passed else 'FAIL'} ({detail})")
    all_passed = all(passed for _, passed, _ in checks)
    print(f"DATA_CHECK = {'PASS' if all_passed else 'FAIL'}")
    return 0 if all_passed else 1


def _run_feature_build(config: dict[str, Any], workspace_root: Path) -> int:
    paths = default_b0_data_paths(workspace_root)
    required = (paths.canonical_parquet, paths.fine_canonical_parquet, paths.samples_parquet)
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        print(f"FEATURE_BUILD = FAIL (missing artifacts: {', '.join(missing)})")
        return 1
    try:
        _, _, b0_report = build_and_persist_features(
            canonical_path=paths.canonical_parquet,
            samples_path=paths.samples_parquet,
            features_path=paths.features_parquet,
            model_dataset_path=paths.model_dataset_parquet,
            report_path=paths.feature_report,
        )
        b1 = build_and_persist_multires_features(
            coarse_path=paths.canonical_parquet,
            fine_path=paths.fine_canonical_parquet,
            samples_path=paths.samples_parquet,
            coarse_features_path=paths.features_parquet,
            fine_features_path=paths.fine_features_parquet,
            fused_features_path=paths.fused_features_parquet,
            coarse_model_dataset_path=paths.coarse_model_dataset_parquet,
            fine_model_dataset_path=paths.fine_model_dataset_parquet,
            multires_model_dataset_path=paths.multires_model_dataset_parquet,
            report_path=paths.multires_feature_report,
        )
    except Exception as exc:
        print(f"FEATURE_BUILD = FAIL ({exc})")
        return 1

    report = b1["report"]
    print(
        "FEATURE_BUILD = PASS "
        f"(coarse={report['coarse_feature_count']}, fine={report['fine_feature_count']}, "
        f"multires={report['multires_feature_count']})"
    )
    print(
        f"B0_ROWS = train={b0_report['train_model_rows']}, "
        f"validation={b0_report['validation_model_rows']}"
    )
    print(
        f"FEATURE_VALID = coarse={report['coarse_feature_valid_rows']}, "
        f"fine={report['fine_feature_valid_rows']}, "
        f"multires={report['multires_feature_valid_rows']}"
    )
    print(
        f"COMMON_ELIGIBLE = total={report['common_eligible_rows']}, "
        f"train={report['common_eligible_train_rows']}, "
        f"validation={report['common_eligible_validation_rows']}, "
        f"test={report['common_eligible_test_rows']}"
    )
    print(f"FINE_FEATURES = {paths.fine_features_parquet}")
    print(f"FUSED_FEATURES = {paths.fused_features_parquet}")
    print(f"FEATURE_REPORT = {paths.multires_feature_report}")
    return 0


def _run_feature_check(config: dict[str, Any], workspace_root: Path) -> int:
    paths = default_b0_data_paths(workspace_root)
    b0_required = (paths.features_parquet, paths.model_dataset_parquet, paths.samples_parquet)
    b1_required = (
        paths.canonical_parquet,
        paths.fine_canonical_parquet,
        paths.fused_features_parquet,
        paths.coarse_model_dataset_parquet,
        paths.fine_model_dataset_parquet,
        paths.multires_model_dataset_parquet,
    )
    missing = [str(path) for path in (*b0_required, *b1_required) if not path.is_file()]
    if missing:
        print(f"FEATURE_CHECK = FAIL (missing artifacts: {', '.join(missing)}; run feature-build first)")
        return 1
    try:
        b0_features = pd.read_parquet(paths.features_parquet)
        samples = pd.read_parquet(paths.samples_parquet)
        b0_dataset = pd.read_parquet(paths.model_dataset_parquet)
        b0_results = run_all_feature_checks(
            features=b0_features, samples=samples, model_dataset=b0_dataset
        )

        coarse_bars = pd.read_parquet(paths.canonical_parquet)
        fine_bars = pd.read_parquet(paths.fine_canonical_parquet)
        fused_features = pd.read_parquet(paths.fused_features_parquet)
        datasets = {
            "B1-C": pd.read_parquet(paths.coarse_model_dataset_parquet),
            "B1-F": pd.read_parquet(paths.fine_model_dataset_parquet),
            "B1-MR": pd.read_parquet(paths.multires_model_dataset_parquet),
        }
        b1_results = run_all_multires_checks(
            coarse_bars=coarse_bars,
            fine_bars=fine_bars,
            fused_features=fused_features,
            datasets=datasets,
        )
    except Exception as exc:
        print(f"FEATURE_CHECK = FAIL ({exc})")
        return 1

    print(f"FEATURE_CAUSALITY = {'PASS' if b0_results['causality']['passed'] else 'FAIL'}")
    print(f"FEATURE_SCHEMA = {'PASS' if b0_results['schema']['passed'] else 'FAIL'}")
    print(f"FEATURE_FINITE = {'PASS' if b0_results['finite']['passed'] else 'FAIL'}")
    print(f"FEATURE_ALIGNMENT = {'PASS' if b0_results['alignment']['passed'] else 'FAIL'}")
    print(f"FINE_FEATURE_CAUSALITY = {'PASS' if b1_results['causality']['passed'] else 'FAIL'}")
    print(f"FINE_30M_ALIGNMENT = {'PASS' if b1_results['alignment']['passed'] else 'FAIL'}")
    print(f"MULTIRES_SCHEMA = {'PASS' if b1_results['schema']['passed'] else 'FAIL'}")
    print(f"MULTIRES_FINITE = {'PASS' if b1_results['finite']['passed'] else 'FAIL'}")
    print(f"COMMON_SAMPLE_EQUALITY = {'PASS' if b1_results['common_samples']['passed'] else 'FAIL'}")
    all_passed = bool(b0_results["passed"] and b1_results["passed"])
    print(f"FEATURE_CHECK = {'PASS' if all_passed else 'FAIL'}")
    return 0 if all_passed else 1


def _run_train(config: dict[str, Any], workspace_root: Path, model_name: str, run_id: str) -> int:
    paths = default_b0_data_paths(workspace_root)
    model_cfg_path = workspace_root / "configs" / "models" / f"{model_name}.yaml"
    if not model_cfg_path.is_file():
        print(f"TRAIN = FAIL (model config not found: {model_cfg_path})")
        return 1
    if not paths.model_dataset_parquet.is_file():
        print(f"TRAIN = FAIL (model dataset not found: {paths.model_dataset_parquet}; run feature-build first)")
        return 1
    try:
        train_result = run_training_pipeline(
            config=config,
            model_config_path=model_cfg_path,
            model_dataset_path=paths.model_dataset_parquet,
            results_root=workspace_root / "results",
            model_name=model_name,
            run_id=run_id,
        )
    except Exception as exc:
        print(f"TRAIN = FAIL ({exc})")
        return 1
    _print_training_result("TRAIN", train_result)
    return 0


def _run_compare_features(
    config: dict[str, Any],
    workspace_root: Path,
    model_name: str,
    run_id: str,
) -> int:
    paths = default_b0_data_paths(workspace_root)
    model_cfg_path = workspace_root / "configs" / "models" / f"{model_name}.yaml"
    dataset_paths = {
        "B1-C": paths.coarse_model_dataset_parquet,
        "B1-F": paths.fine_model_dataset_parquet,
        "B1-MR": paths.multires_model_dataset_parquet,
    }
    missing = [str(path) for path in (model_cfg_path, *dataset_paths.values()) if not path.is_file()]
    if missing:
        print(f"COMPARE_FEATURES = FAIL (missing artifacts: {', '.join(missing)}; run feature-build first)")
        return 1

    comparison_dir = workspace_root / "results" / "_runs" / run_id
    model_dirs = {
        variant: workspace_root / "results" / model_name / f"{run_id}_{suffix}"
        for variant, suffix in (("B1-C", "coarse"), ("B1-F", "fine"), ("B1-MR", "multires"))
    }
    unavailable = [str(path) for path in (comparison_dir, *model_dirs.values()) if _path_has_content(path)]
    if unavailable:
        print(f"COMPARE_FEATURES = FAIL (refusing to overwrite non-empty run directories: {', '.join(unavailable)})")
        return 1

    try:
        # Resolve once at the public seam; the three calls below share the
        # Trainer implementation and differ only by FeatureView input columns.
        results: dict[str, dict[str, Any]] = {}
        for variant, view_name in (("B1-C", "coarse"), ("B1-F", "fine"), ("B1-MR", "multires")):
            results[variant] = run_training_pipeline(
                config=config,
                model_config_path=model_cfg_path,
                model_dataset_path=dataset_paths[variant],
                results_root=workspace_root / "results",
                model_name=model_name,
                run_id=f"{run_id}_{view_name}",
                feature_view=resolve_feature_view(view_name),
            )

        comparison_rows = [_comparison_row(variant, results[variant]) for variant in results]
        comparison = pd.DataFrame(comparison_rows, columns=_comparison_columns())
        comparison_dir.mkdir(parents=True, exist_ok=True)
        comparison.to_csv(comparison_dir / "feature_comparison.csv", index=False)
        result_directories = {variant: result["run_dir"] for variant, result in results.items()}
        sealing = run_test_sealing_check(result_directories)
        if not sealing["passed"]:
            raise RuntimeError("; ".join(sealing["errors"]))

        mr_metrics = results["B1-MR"]["metrics"]
        c_metrics = results["B1-C"]["metrics"]
        f_metrics = results["B1-F"]["metrics"]
        best_variant = max(results, key=lambda key: results[key]["metrics"]["roc_auc"])
        run_info = {
            "status": "COMPLETE",
            "run_id": run_id,
            "model": model_name,
            "seed": int(config.get("project", {}).get("seed", 2026)),
            "feature_views": ["B1-C", "B1-F", "B1-MR"],
            "common_samples": _common_sample_counts(dataset_paths),
            "variants": {
                variant: {
                    "run_dir": result["run_dir"],
                    "feature_set": result["feature_view"].feature_set,
                    "feature_count": result["feature_view"].feature_count,
                    "train_rows": result["run_info"]["train_rows"],
                    "validation_rows": result["run_info"]["validation_rows"],
                    "best_iteration": result["best_iteration"],
                    "validation_metrics": result["metrics"],
                    "feature_group_importance": result["feature_group_importance"],
                }
                for variant, result in results.items()
            },
            "best_variant_by_roc_auc": best_variant,
            "incremental_value": {
                "mr_minus_coarse_roc_auc": mr_metrics["roc_auc"] - c_metrics["roc_auc"],
                "mr_minus_fine_roc_auc": mr_metrics["roc_auc"] - f_metrics["roc_auc"],
                "mr_minus_coarse_binary_logloss": mr_metrics["binary_logloss"] - c_metrics["binary_logloss"],
                "mr_minus_fine_binary_logloss": mr_metrics["binary_logloss"] - f_metrics["binary_logloss"],
                "mr_minus_coarse_brier": mr_metrics["brier_score"] - c_metrics["brier_score"],
                "mr_minus_fine_brier": mr_metrics["brier_score"] - f_metrics["brier_score"],
            },
            "test_status": "SEALED",
            "test_sealing_check": sealing,
        }
        atomic_write_json(run_info, comparison_dir / "run_info.json")
    except Exception as exc:
        print(f"COMPARE_FEATURES = FAIL ({exc})")
        return 1

    print(f"COMPARE_FEATURES = PASS (run_id={run_id}, best_by_auc={best_variant})")
    for variant, result in results.items():
        metrics = result["metrics"]
        print(
            f"{variant} = best_iteration={result['best_iteration']}, "
            f"rows={metrics['n_samples']}, auc={metrics['roc_auc']:.6f}, "
            f"logloss={metrics['binary_logloss']:.6f}, brier={metrics['brier_score']:.6f}"
        )
    print(f"COMPARISON_DIRECTORY = {comparison_dir}")
    print("TEST_STATUS = SEALED")
    return 0


def _comparison_columns() -> list[str]:
    columns = [
        "variant", "feature_set", "feature_count", "train_rows", "validation_rows",
        "best_iteration", "roc_auc", "binary_logloss", "brier_score",
        "accuracy_at_0_5", "probability_std",
    ]
    for threshold in ("055", "0575", "060", "0625", "065", "0675", "070"):
        columns.extend((f"q_{threshold}_count", f"q_{threshold}_hit_rate"))
    return columns


def _comparison_row(variant: str, result: dict[str, Any]) -> dict[str, Any]:
    metrics = result["metrics"]
    confidence = result["confidence_report"]
    row: dict[str, Any] = {
        "variant": variant,
        "feature_set": result["feature_view"].feature_set,
        "feature_count": result["feature_view"].feature_count,
        "train_rows": result["run_info"]["train_rows"],
        "validation_rows": result["run_info"]["validation_rows"],
        "best_iteration": result["best_iteration"],
        "roc_auc": metrics["roc_auc"],
        "binary_logloss": metrics["binary_logloss"],
        "brier_score": metrics["brier_score"],
        "accuracy_at_0_5": metrics["accuracy_at_0_5"],
        "probability_std": metrics["probability_std"],
    }
    for q, key in ((0.55, "055"), (0.575, "0575"), (0.60, "060"), (0.625, "0625"), (0.65, "065"), (0.675, "0675"), (0.70, "070")):
        matches = confidence[confidence["threshold_q"] == q]
        record = matches.iloc[0] if not matches.empty else {}
        row[f"q_{key}_count"] = record.get("combined_count")
        row[f"q_{key}_hit_rate"] = record.get("combined_hit_rate")
    return row


def _common_sample_counts(dataset_paths: dict[str, Path]) -> dict[str, Any]:
    counts: dict[str, Any] = {}
    reference: pd.DataFrame | None = None
    for variant, path in dataset_paths.items():
        frame = pd.read_parquet(path)
        current = frame["common_eligible"].astype(bool)
        counts[variant] = {
            "total": int(current.sum()),
            "train": int((current & (frame["split"] == "train")).sum()),
            "validation": int((current & (frame["split"] == "validation")).sum()),
            "test": int((current & (frame["split"] == "test")).sum()),
        }
        if reference is None:
            reference = frame.loc[current, ["sample_id", "prediction_time", "target_up"]].reset_index(drop=True)
    return counts


def _print_training_result(prefix: str, train_result: dict[str, Any]) -> None:
    metrics = train_result["metrics"]
    best_es = train_result["best_es_logloss"]
    print(f"{prefix} = PASS (run_dir={train_result['run_dir']})")
    print(f"BEST_ITERATION = {train_result['best_iteration']}")
    if best_es is not None:
        print(f"INTERNAL_ES_LOGLOSS = {best_es:.6f}")
    print(
        "VALIDATION_METRICS = "
        f"samples={metrics['n_samples']}, positive_rate={metrics['positive_rate']:.4f}, "
        f"binary_logloss={metrics['binary_logloss']:.6f}, brier={metrics['brier_score']:.6f}, "
        f"roc_auc={metrics['roc_auc']:.6f}, accuracy_at_0_5={metrics['accuracy_at_0_5']:.4f}"
    )
    print(f"TEST_STATUS = {train_result['run_info'].get('test_status', 'SEALED')}")


def _path_has_content(path: Path) -> bool:
    return path.exists() and (not path.is_dir() or any(path.iterdir()))


def _data_is_configured(workspace_root: Path) -> bool:
    """Report whether raw or processed contains a non-placeholder file."""

    for directory_name in ("raw", "processed"):
        directory = workspace_root / "data" / directory_name
        if not directory.is_dir():
            continue
        if any(path.is_file() and path.name != ".gitkeep" for path in directory.rglob("*")):
            return True
    return False


__all__ = ["build_parser", "main"]
