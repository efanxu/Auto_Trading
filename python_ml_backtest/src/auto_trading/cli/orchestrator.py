"""Single public CLI for the Python ML Event Contract workspace."""

from __future__ import annotations

import argparse
from math import isclose
from pathlib import Path
from typing import Sequence

import pandas as pd

from auto_trading.data import (
    BinanceDataError,
    DataValidationError,
    default_b0_data_paths,
    download_archives,
    prepare_canonical_data,
    run_data_preflight,
)
from auto_trading.features import (
    build_and_persist_features,
    run_all_feature_checks,
)
from auto_trading.labels import (
    build_persisted_event_dataset,
    run_label_causality_check,
)
from auto_trading.runtime.trainer import run_training_pipeline
from auto_trading.runtime.config import (
    ConfigError,
    calculate_event_payout,
    default_config_path,
    dump_config,
    load_config,
)
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
        ("data-download", "download verified official Binance archives"),
        ("data-prepare", "build canonical 30m OHLC parquet and data report"),
        ("dataset-build", "build causal Event labels and chronological split"),
        ("data-check", "run data, label, and split contract checks"),
        ("feature-build", "build causal price_ohlc_v1 features and model dataset"),
        ("feature-check", "run feature causality, schema, finite, and alignment checks"),
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

    train_command = commands.add_parser("train", help="train probability baseline model")
    train_command.add_argument(
        "--config",
        dest="command_config",
        type=Path,
        default=None,
        help="Path to experiment YAML (overrides the global option).",
    )
    train_command.add_argument(
        "--model",
        dest="model",
        type=str,
        default="lightgbm",
        help="Model architecture name (default: lightgbm).",
    )
    train_command.add_argument(
        "--run-id",
        dest="run_id",
        type=str,
        default="b0c_lightgbm_seed2026",
        help="Unique run identifier for output directory.",
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
        return _run_train(
            config,
            workspace_root,
            model_name=args.model,
            run_id=args.run_id,
        )

    parser.error(f"unsupported command: {args.command}")
    return 2


def _run_check(config: dict, config_path: Path) -> int:
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

    public_configuration_ok = (
        config["data"]["source"] == "binance_public_data"
        and config["data"]["market"] == "usd_m_futures"
        and config["data"]["series"] == "index_price_klines"
        and config["data"]["symbol"] == "BTCUSDT"
        and config["data"]["interval"] == "30m"
        and config["data"]["timezone"] == "UTC"
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
    )
    checks.append(
        (
            "PUBLIC_CONFIGURATION",
            public_configuration_ok,
            "consistent" if public_configuration_ok else "inconsistent",
        )
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
    payout = calculate_event_payout(
        event["stake_usdt"],
        event["winning_total_return_usdt"],
    )
    payout_ok = (
        isclose(event["win_net_profit"], payout.win_net_profit, rel_tol=0, abs_tol=1e-12)
        and isclose(event["loss_net_profit"], payout.loss_net_profit, rel_tol=0, abs_tol=1e-12)
        and isclose(
            event["break_even_win_rate"],
            payout.break_even_win_rate,
            rel_tol=0,
            abs_tol=1e-12,
        )
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


def _run_data_download(config: dict, workspace_root: Path) -> int:
    paths = default_b0_data_paths(workspace_root)
    data = config["data"]
    try:
        results = download_archives(
            symbol=data["symbol"],
            interval=data["interval"],
            start_date=data["start_date"],
            end_date=data["end_date"],
            raw_root=paths.raw_root,
        )
    except (BinanceDataError, OSError, ValueError) as exc:
        print(f"DATA_DOWNLOAD = FAIL ({exc})")
        return 1
    reused = sum(result.reused for result in results)
    print(f"DATA_DOWNLOAD = PASS (archives={len(results)}, reused={reused})")
    print(f"RAW_DIRECTORY = {paths.raw_root}")
    return 0


def _run_data_prepare(config: dict, workspace_root: Path) -> int:
    paths = default_b0_data_paths(workspace_root)
    try:
        _, report = prepare_canonical_data(
            config=config,
            raw_root=paths.raw_root,
            output_path=paths.canonical_parquet,
            report_path=paths.data_report,
        )
    except (BinanceDataError, DataValidationError, OSError, ValueError) as exc:
        print(f"DATA_PREPARE = FAIL ({exc})")
        return 1
    print(f"DATA_PREPARE = PASS (rows={report['rows']})")
    print(f"DUPLICATES = {report['duplicates']}")
    print(f"GAPS = {report['gaps']}")
    print(f"CANONICAL = {paths.canonical_parquet}")
    return 0


def _run_dataset_build(config: dict, workspace_root: Path) -> int:
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
        f"(candidates={report['total_candidate_events']}, "
        f"valid={report['valid_events']}, flat={report['flat_events']}, "
        f"purged={report['purged_rows']})"
    )
    print(
        "SPLIT_ROWS = "
        f"train={report['train_rows']}, "
        f"validation={report['validation_rows']}, "
        f"test={report['test_rows']}"
    )
    print(f"SAMPLES = {paths.samples_parquet}")
    return 0


def _run_data_check(config: dict, workspace_root: Path) -> int:
    paths = default_b0_data_paths(workspace_root)
    checks: list[tuple[str, bool, str]] = []

    if paths.canonical_parquet.is_file():
        try:
            bars = pd.read_parquet(paths.canonical_parquet)
            data_report = run_data_preflight(bars, expected_interval_minutes=30)
            checks.append(
                (
                    "DATA_PREFLIGHT",
                    bool(data_report["passed"]),
                    f"rows={data_report['total_rows']}, gaps={data_report['gap_count']}"
                    if data_report["passed"]
                    else "; ".join(data_report["issues"]),
                )
            )
        except (OSError, ValueError, TypeError) as exc:
            bars = None
            checks.append(("DATA_PREFLIGHT", False, str(exc)))
    else:
        bars = None
        checks.append(("DATA_PREFLIGHT", False, f"missing {paths.canonical_parquet}"))

    if bars is not None and paths.samples_parquet.is_file():
        try:
            samples = pd.read_parquet(paths.samples_parquet)
            label_report = run_label_causality_check(bars, samples, interval_minutes=30)
            checks.append(
                (
                    "LABEL_CAUSALITY",
                    bool(label_report["passed"]),
                    f"rows={label_report['checked_rows']}"
                    if label_report["passed"]
                    else "; ".join(label_report["errors"]),
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
                    if split_report["passed"]
                    else "; ".join(split_report["errors"]),
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


def _run_feature_build(config: dict, workspace_root: Path) -> int:
    paths = default_b0_data_paths(workspace_root)
    if not paths.canonical_parquet.is_file():
        print(f"FEATURE_BUILD = FAIL (missing canonical data: {paths.canonical_parquet})")
        return 1
    if not paths.samples_parquet.is_file():
        print(f"FEATURE_BUILD = FAIL (missing sample data: {paths.samples_parquet})")
        return 1

    try:
        _, _, report = build_and_persist_features(
            canonical_path=paths.canonical_parquet,
            samples_path=paths.samples_parquet,
            features_path=paths.features_parquet,
            model_dataset_path=paths.model_dataset_parquet,
            report_path=paths.feature_report,
        )
    except Exception as exc:
        print(f"FEATURE_BUILD = FAIL ({exc})")
        return 1

    print(
        "FEATURE_BUILD = PASS "
        f"(features={report['feature_count']}, total_rows={report['total_rows']}, "
        f"valid={report['valid_feature_rows']}, invalid={report['invalid_feature_rows']})"
    )
    print(
        "MODEL_ROWS = "
        f"train={report['train_model_rows']}, "
        f"validation={report['validation_model_rows']}, "
        f"test_features={report['test_feature_rows']}"
    )
    print(f"FEATURES = {paths.features_parquet}")
    print(f"MODEL_DATASET = {paths.model_dataset_parquet}")
    print(f"FEATURE_REPORT = {paths.feature_report}")
    return 0


def _run_feature_check(config: dict, workspace_root: Path) -> int:
    paths = default_b0_data_paths(workspace_root)
    if not paths.features_parquet.is_file() or not paths.model_dataset_parquet.is_file() or not paths.samples_parquet.is_file():
        print("FEATURE_CHECK = FAIL (missing feature or dataset artifacts; run feature-build first)")
        return 1

    try:
        features = pd.read_parquet(paths.features_parquet)
        samples = pd.read_parquet(paths.samples_parquet)
        model_dataset = pd.read_parquet(paths.model_dataset_parquet)

        results = run_all_feature_checks(
            features=features,
            samples=samples,
            model_dataset=model_dataset,
        )
    except Exception as exc:
        print(f"FEATURE_CHECK = FAIL ({exc})")
        return 1

    causality_ok = results["causality"]["passed"]
    schema_ok = results["schema"]["passed"]
    finite_ok = results["finite"]["passed"]
    alignment_ok = results["alignment"]["passed"]

    print(f"FEATURE_CAUSALITY = {'PASS' if causality_ok else 'FAIL'}")
    print(f"FEATURE_SCHEMA = {'PASS' if schema_ok else 'FAIL'}")
    print(f"FEATURE_FINITE = {'PASS' if finite_ok else 'FAIL'}")
    print(f"FEATURE_ALIGNMENT = {'PASS' if alignment_ok else 'FAIL'}")

    all_passed = results["passed"]
    print(f"FEATURE_CHECK = {'PASS' if all_passed else 'FAIL'}")
    return 0 if all_passed else 1


def _run_train(config: dict, workspace_root: Path, model_name: str, run_id: str) -> int:
    paths = default_b0_data_paths(workspace_root)
    model_cfg_path = workspace_root / "configs" / "models" / f"{model_name}.yaml"
    if not model_cfg_path.is_file():
        print(f"TRAIN = FAIL (model config not found: {model_cfg_path})")
        return 1
    if not paths.model_dataset_parquet.is_file():
        print(f"TRAIN = FAIL (model dataset not found: {paths.model_dataset_parquet}; run feature-build first)")
        return 1

    results_root = workspace_root / "results"
    try:
        train_result = run_training_pipeline(
            config=config,
            model_config_path=model_cfg_path,
            model_dataset_path=paths.model_dataset_parquet,
            results_root=results_root,
            model_name=model_name,
            run_id=run_id,
        )
    except Exception as exc:
        print(f"TRAIN = FAIL ({exc})")
        return 1

    metrics = train_result["metrics"]
    run_info = train_result["run_info"]

    print(f"TRAIN = PASS (model={model_name}, run_id={run_id})")
    print(f"BEST_ITERATION = {train_result['best_iteration']}")
    print(f"INTERNAL_ES_LOGLOSS = {train_result['best_es_logloss']:.6f}")
    print("VALIDATION_METRICS = {")
    print(f"  samples: {metrics['n_samples']},")
    print(f"  positive_rate: {metrics['positive_rate']:.4f},")
    print(f"  binary_logloss: {metrics['binary_logloss']:.6f},")
    print(f"  brier_score: {metrics['brier_score']:.6f},")
    print(f"  roc_auc: {metrics['roc_auc']:.6f},")
    print(f"  accuracy_at_0_5: {metrics['accuracy_at_0_5']:.4f},")
    print(f"  probability_mean: {metrics['probability_mean']:.4f},")
    print(f"  probability_std: {metrics['probability_std']:.4f},")
    print(f"  probability_min: {metrics['probability_min']:.4f},")
    print(f"  probability_max: {metrics['probability_max']:.4f}")
    print("}")
    print(f"RESULTS_DIRECTORY = {train_result['run_dir']}")
    print(f"TEST_STATUS = {run_info.get('test_status', 'SEALED')}")
    return 0



def _data_is_configured(workspace_root: Path) -> bool:
    """Report whether raw or processed contains a non-placeholder file."""

    for directory_name in ("raw", "processed"):
        directory = workspace_root / "data" / directory_name
        if not directory.is_dir():
            continue
        if any(
            path.is_file() and path.name != ".gitkeep"
            for path in directory.rglob("*")
        ):
            return True
    return False


__all__ = ["build_parser", "main"]
