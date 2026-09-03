"""Binance public-data archive access and canonical OHLC preparation."""

from __future__ import annotations

import hashlib
import io
import os
import re
import tempfile
import zipfile
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, BinaryIO
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import pandas as pd

from .schema import CANONICAL_COLUMNS, empty_canonical_frame
from .storage import atomic_write_json, atomic_write_parquet
from .validation import DataValidationError, assert_data_preflight


BINANCE_ARCHIVE_BASE_URL = "https://data.binance.vision/data/futures/um"
FetchBytes = Callable[[str], bytes]


class BinanceDataError(RuntimeError):
    """Base error for official Binance archive operations."""


class ArchiveNotFound(BinanceDataError):
    """Raised when an official archive URL returns HTTP 404."""


class ChecksumError(BinanceDataError):
    """Raised when an archive checksum is absent, malformed, or mismatched."""


class DuplicateTimestampError(DataValidationError):
    """Raised when duplicate ``open_time`` rows have conflicting content."""


@dataclass(frozen=True)
class ArchiveDownload:
    """Result for one verified archive."""

    url: str
    path: Path
    checksum_path: Path | None
    reused: bool
    checksum: str | None


def build_monthly_archive_url(
    symbol: str,
    interval: str,
    year: int,
    month: int,
    *,
    base_url: str = BINANCE_ARCHIVE_BASE_URL,
) -> str:
    """Build the official USD-M monthly index-price-kline URL."""

    period = f"{int(year):04d}-{int(month):02d}"
    filename = f"{symbol}-{interval}-{period}.zip"
    return _archive_url(base_url, "monthly", symbol, interval, filename)


def build_daily_archive_url(
    symbol: str,
    interval: str,
    day: date | datetime | str,
    *,
    base_url: str = BINANCE_ARCHIVE_BASE_URL,
) -> str:
    """Build the official USD-M daily index-price-kline URL."""

    resolved_day = _as_date(day)
    period = resolved_day.isoformat()
    filename = f"{symbol}-{interval}-{period}.zip"
    return _archive_url(base_url, "daily", symbol, interval, filename)


# Short aliases make the URL contract convenient to use in tests and scripts.
monthly_archive_url = build_monthly_archive_url
daily_archive_url = build_daily_archive_url


def checksum_url(archive_url: str) -> str:
    """Return the official sidecar URL for an archive."""

    return f"{archive_url}.CHECKSUM"


def archive_directory(raw_root: str | Path, symbol: str, interval: str) -> Path:
    """Return the stable local raw-archive directory."""

    return (
        Path(raw_root)
        / "futures"
        / "um"
        / "indexPriceKlines"
        / symbol
        / interval
    )


def download_verified_archive(
    archive_url: str,
    destination: str | Path,
    *,
    fetch_bytes: FetchBytes | None = None,
    verify_checksum: bool = True,
    allow_missing_checksum: bool = False,
) -> ArchiveDownload:
    """Download one archive using checksum validation and atomic replacement.

    A valid local archive plus its checksum is reused.  New bytes are first
    written to a temporary file in the destination directory and only then
    atomically replace the requested path.
    """

    fetch = fetch_bytes or _fetch_url
    path = Path(destination)
    path.parent.mkdir(parents=True, exist_ok=True)
    sidecar = Path(f"{path}.CHECKSUM")

    if not verify_checksum:
        if path.is_file():
            return ArchiveDownload(archive_url, path, None, True, None)
        payload = _fetch_archive(fetch, archive_url)
        _atomic_write_bytes(payload, path)
        return ArchiveDownload(archive_url, path, None, False, None)

    sidecar_payload: bytes | None = None
    expected_checksum: str | None = None
    archive_payload: bytes | None = None
    if path.is_file() and sidecar.is_file():
        try:
            expected_checksum = parse_checksum(sidecar.read_bytes())
        except (OSError, ChecksumError):
            expected_checksum = None
        if expected_checksum and sha256_file(path) == expected_checksum:
            return ArchiveDownload(
                archive_url,
                path,
                sidecar,
                True,
                expected_checksum,
            )

    try:
        sidecar_payload = _fetch_archive(fetch, checksum_url(archive_url))
        expected_checksum = parse_checksum(sidecar_payload)
    except ArchiveNotFound:
        # A missing checksum must not hide a missing monthly archive: the
        # caller uses ArchiveNotFound to activate the official daily fallback.
        try:
            archive_payload = _fetch_archive(fetch, archive_url)
        except ArchiveNotFound:
            raise
        if not allow_missing_checksum:
            raise ChecksumError(
                f"official checksum not found for archive: {checksum_url(archive_url)}"
            )
        sidecar_payload = None
        expected_checksum = None
    except (HTTPError, URLError, OSError) as exc:
        raise BinanceDataError(
            f"cannot download checksum for {archive_url}: {exc}"
        ) from exc

    if path.is_file() and expected_checksum:
        if sha256_file(path) == expected_checksum:
            if sidecar_payload is not None:
                _atomic_write_bytes(sidecar_payload, sidecar)
            return ArchiveDownload(
                archive_url,
                path,
                sidecar if sidecar_payload is not None else None,
                True,
                expected_checksum,
            )

    payload = archive_payload if archive_payload is not None else _fetch_archive(fetch, archive_url)
    if expected_checksum:
        actual_checksum = hashlib.sha256(payload).hexdigest()
        if actual_checksum != expected_checksum:
            raise ChecksumError(
                f"checksum mismatch for {archive_url}: "
                f"expected {expected_checksum}, got {actual_checksum}"
            )
    _atomic_write_bytes(payload, path)
    if sidecar_payload is not None:
        _atomic_write_bytes(sidecar_payload, sidecar)
    return ArchiveDownload(
        archive_url,
        path,
        sidecar if sidecar_payload is not None else None,
        False,
        expected_checksum,
    )


def download_archives(
    *,
    symbol: str,
    interval: str,
    start_date: date | datetime | str,
    end_date: date | datetime | str,
    raw_root: str | Path,
    base_url: str = BINANCE_ARCHIVE_BASE_URL,
    fetch_bytes: FetchBytes | None = None,
) -> list[ArchiveDownload]:
    """Download the fixed inclusive date range, preferring monthly archives."""

    start = _as_date(start_date)
    end = _as_date(end_date)
    if start >= end:
        raise ValueError("start_date must be before end_date")

    destination_dir = archive_directory(raw_root, symbol, interval)
    results: list[ArchiveDownload] = []
    current = date(start.year, start.month, 1)
    final_month = date(end.year, end.month, 1)
    while current <= final_month:
        monthly_url = build_monthly_archive_url(
            symbol,
            interval,
            current.year,
            current.month,
            base_url=base_url,
        )
        monthly_destination = destination_dir / Path(monthly_url).name
        try:
            results.append(
                download_verified_archive(
                    monthly_url,
                    monthly_destination,
                    fetch_bytes=fetch_bytes,
                )
            )
        except ArchiveNotFound:
            month_end = _month_end(current)
            daily_start = max(start, current)
            daily_end = min(end, month_end)
            day = daily_start
            while day <= daily_end:
                daily_url = build_daily_archive_url(
                    symbol,
                    interval,
                    day,
                    base_url=base_url,
                )
                daily_destination = destination_dir / Path(daily_url).name
                results.append(
                    download_verified_archive(
                        daily_url,
                        daily_destination,
                        fetch_bytes=fetch_bytes,
                    )
                )
                day += timedelta(days=1)
        current = _next_month(current)
    return results


def parse_checksum(payload: bytes | str) -> str:
    """Extract a SHA-256 digest from Binance's ``.CHECKSUM`` format."""

    text = payload.decode("utf-8", errors="replace") if isinstance(payload, bytes) else payload
    match = re.search(r"(?i)(?<![0-9a-f])([0-9a-f]{64})(?![0-9a-f])", text)
    if not match:
        raise ChecksumError("checksum payload does not contain a SHA-256 digest")
    return match.group(1).lower()


def sha256_file(path: str | Path) -> str:
    """Calculate a file's SHA-256 digest in streaming mode."""

    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_kline_csv(source: str | Path | bytes | BinaryIO) -> pd.DataFrame:
    """Parse an official kline CSV into the canonical six-column frame."""

    source_name = getattr(source, "name", source)
    try:
        if isinstance(source, bytes):
            payload = source
        elif isinstance(source, (str, Path)):
            payload = Path(source).read_bytes()
        else:
            payload = source.read()
        raw = pd.read_csv(
            io.BytesIO(payload),
            header=None,
            dtype=str,
            keep_default_na=False,
            skip_blank_lines=True,
        )
    except (OSError, ValueError, TypeError) as exc:
        raise BinanceDataError(f"cannot parse kline CSV {source_name!r}: {exc}") from exc

    if raw.empty:
        return empty_canonical_frame()
    raw = raw.loc[~raw.apply(lambda row: all(str(value).strip() == "" for value in row), axis=1)]
    if raw.empty:
        return empty_canonical_frame()

    first_row = [_normalise_header(value) for value in raw.iloc[0].tolist()]
    has_header = "opentime" in first_row and "closetime" in first_row
    if has_header:
        positions = {
            "open_time": first_row.index("opentime"),
            "open": _header_position(first_row, "open"),
            "high": _header_position(first_row, "high"),
            "low": _header_position(first_row, "low"),
            "close": _header_position(first_row, "close"),
            "close_time": first_row.index("closetime"),
        }
        data = raw.iloc[1:].reset_index(drop=True)
    else:
        if raw.shape[1] < 6:
            raise BinanceDataError(
                f"kline CSV {source_name!r} has {raw.shape[1]} columns; at least 6 are required"
            )
        close_time_position = 6 if raw.shape[1] >= 7 else 5
        positions = {
            "open_time": 0,
            "open": 1,
            "high": 2,
            "low": 3,
            "close": 4,
            "close_time": close_time_position,
        }
        data = raw.reset_index(drop=True)

    try:
        parsed = pd.DataFrame(
            {
                name: data.iloc[:, position]
                for name, position in positions.items()
            }
        )
        parsed["open_time"] = _parse_timestamps(parsed["open_time"], "open_time")
        parsed["close_time"] = _parse_timestamps(parsed["close_time"], "close_time")
        for column in ("open", "high", "low", "close"):
            values = pd.to_numeric(parsed[column], errors="coerce")
            if values.isna().any():
                raise BinanceDataError(f"kline CSV {source_name!r} has invalid {column} values")
            parsed[column] = values.astype("float64")
    except IndexError as exc:
        raise BinanceDataError(f"kline CSV {source_name!r} has missing required columns") from exc
    return parsed.loc[:, list(CANONICAL_COLUMNS)]


def read_zip_archive(path: str | Path) -> pd.DataFrame:
    """Read and merge all CSV members in one Binance ZIP archive."""

    frame, _ = read_zip_archive_with_stats(path)
    return frame


def read_zip_archive_with_stats(path: str | Path) -> tuple[pd.DataFrame, int]:
    """Read one archive and return its canonical frame plus dedupe count."""

    archive_path = Path(path)
    try:
        with zipfile.ZipFile(archive_path) as archive:
            members = [
                name
                for name in archive.namelist()
                if not name.endswith("/") and name.lower().endswith(".csv")
            ]
            if not members:
                raise BinanceDataError(f"archive contains no CSV: {archive_path}")
            frames = [parse_kline_csv(archive.read(name)) for name in sorted(members)]
    except (OSError, zipfile.BadZipFile) as exc:
        raise BinanceDataError(f"cannot read Binance archive {archive_path}: {exc}") from exc
    return merge_canonical_frames(frames)


def merge_canonical_frames(
    frames: Iterable[pd.DataFrame],
) -> tuple[pd.DataFrame, int]:
    """Merge frames, deduplicate identical timestamps, and reject conflicts."""

    materialised = [frame.loc[:, list(CANONICAL_COLUMNS)].copy() for frame in frames]
    if not materialised:
        return empty_canonical_frame(), 0
    merged = pd.concat(materialised, ignore_index=True)
    if merged.empty:
        return empty_canonical_frame(), 0

    duplicate_count = 0
    conflicting: list[str] = []
    for timestamp, group in merged.groupby("open_time", sort=False, dropna=False):
        if len(group) <= 1:
            continue
        unique_rows = group.loc[:, list(CANONICAL_COLUMNS)].drop_duplicates()
        if len(unique_rows) > 1:
            conflicting.append(_timestamp_to_iso(timestamp) or str(timestamp))
        else:
            duplicate_count += len(group) - 1
    if conflicting:
        joined = ", ".join(conflicting[:10])
        suffix = "" if len(conflicting) <= 10 else f" (and {len(conflicting) - 10} more)"
        raise DuplicateTimestampError(
            "conflicting duplicate open_time timestamp(s): " + joined + suffix
        )

    deduplicated = merged.drop_duplicates(subset=list(CANONICAL_COLUMNS), keep="first")
    deduplicated = deduplicated.sort_values("open_time", kind="mergesort").reset_index(drop=True)
    return deduplicated.loc[:, list(CANONICAL_COLUMNS)], duplicate_count


def prepare_canonical_data(
    *,
    config: Mapping[str, Any],
    raw_root: str | Path,
    output_path: str | Path,
    report_path: str | Path,
    interval: str | None = None,
) -> tuple[pd.DataFrame, dict[str, Any]]:
    """Convert downloaded archives into canonical parquet and a data report.

    ``interval`` defaults to the legacy ``data.interval`` field, and can be
    supplied explicitly for the B1 fine/coarse dual-interval protocol.
    """

    data_config = config["data"]
    resolved_interval = interval or data_config.get("interval", "30m")
    raw_directory = archive_directory(raw_root, data_config["symbol"], resolved_interval)
    archive_paths = sorted(raw_directory.rglob("*.zip")) if raw_directory.is_dir() else []
    if not archive_paths:
        raise BinanceDataError(f"no Binance ZIP archives found under {raw_directory}")

    frames: list[pd.DataFrame] = []
    duplicate_count = 0
    for path in archive_paths:
        frame, archive_duplicate_count = read_zip_archive_with_stats(path)
        frames.append(frame)
        duplicate_count += archive_duplicate_count
    merged, cross_archive_duplicate_count = merge_canonical_frames(frames)
    duplicate_count += cross_archive_duplicate_count
    start = pd.Timestamp(_as_date(data_config["start_date"]), tz="UTC")
    end_exclusive = pd.Timestamp(_as_date(data_config["end_date"]), tz="UTC") + pd.Timedelta(days=1)
    in_range = merged["open_time"].ge(start) & merged["open_time"].lt(end_exclusive)
    canonical = merged.loc[in_range].reset_index(drop=True)
    if canonical.empty:
        raise BinanceDataError(
            f"archives under {raw_directory} contain no rows in {start.date()}..{end_exclusive.date() - timedelta(days=1)}"
        )

    preflight = assert_data_preflight(
        canonical,
        expected_interval_minutes=_interval_minutes(resolved_interval),
    )
    atomic_write_parquet(canonical, Path(output_path))
    report = {
        "source": data_config["source"],
        "market": data_config["market"],
        "series": data_config["series"],
        "symbol": data_config["symbol"],
        "interval": resolved_interval,
        "timezone": data_config["timezone"],
        "start_date": _date_string(data_config["start_date"]),
        "end_date": _date_string(data_config["end_date"]),
        "rows": len(canonical),
        "first_open_time": preflight["first_open_time"],
        "last_close_time": preflight["last_close_time"],
        "duplicates": duplicate_count,
        "duplicate_count": duplicate_count,
        "gaps": preflight["gap_count"],
        "gap_count": preflight["gap_count"],
        "gap_ranges": preflight["gap_ranges"],
        "data_preflight": preflight,
        "archives": [path.name for path in archive_paths],
    }
    atomic_write_json(report, Path(report_path))
    return canonical, report


def prepare_interval_data(
    *,
    config: Mapping[str, Any],
    interval: str,
    raw_root: str | Path,
    output_path: str | Path,
    report_path: str | Path,
) -> tuple[pd.DataFrame, dict[str, Any]]:
    """Explicit B1 alias for preparing one configured data interval."""

    return prepare_canonical_data(
        config=config,
        raw_root=raw_root,
        output_path=output_path,
        report_path=report_path,
        interval=interval,
    )


def _archive_url(
    base_url: str,
    cadence: str,
    symbol: str,
    interval: str,
    filename: str,
) -> str:
    return "/".join(
        part.strip("/")
        for part in (base_url, cadence, "indexPriceKlines", symbol, interval, filename)
    )


def _fetch_url(url: str) -> bytes:
    request = Request(url, headers={"User-Agent": "Auto_Trading-B0-data-client/1.0"})
    try:
        with urlopen(request, timeout=60) as response:
            return response.read()
    except HTTPError as exc:
        if exc.code == 404:
            raise ArchiveNotFound(url) from exc
        raise BinanceDataError(f"HTTP {exc.code} while downloading {url}") from exc
    except (URLError, OSError) as exc:
        raise BinanceDataError(f"cannot download {url}: {exc}") from exc


def _fetch_archive(fetch: FetchBytes, url: str) -> bytes:
    try:
        return fetch(url)
    except HTTPError as exc:
        if exc.code == 404:
            raise ArchiveNotFound(url) from exc
        raise BinanceDataError(f"HTTP {exc.code} while downloading {url}") from exc
    except ArchiveNotFound:
        raise
    except (URLError, OSError) as exc:
        raise BinanceDataError(f"cannot download {url}: {exc}") from exc


def _atomic_write_bytes(payload: bytes, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.",
        suffix=".tmp",
        dir=destination.parent,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(file_descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, destination)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def _parse_timestamps(values: pd.Series, field: str) -> pd.Series:
    numeric = pd.to_numeric(values, errors="coerce")
    if numeric.notna().all():
        maximum = float(numeric.abs().max()) if len(numeric) else 0
        unit = "ms" if maximum >= 10**11 else "s"
        parsed = pd.to_datetime(numeric, unit=unit, utc=True, errors="coerce")
    else:
        parsed = pd.to_datetime(values, utc=True, errors="coerce")
    if parsed.isna().any():
        raise BinanceDataError(f"CSV contains invalid {field} timestamps")
    return parsed


def _normalise_header(value: Any) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value).strip().lstrip("\ufeff").lower())


def _header_position(header: list[str], name: str) -> int:
    try:
        return header.index(name)
    except ValueError as exc:
        raise BinanceDataError(f"CSV header is missing '{name}'") from exc


def _as_date(value: date | datetime | str) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    if isinstance(value, str):
        return date.fromisoformat(value)
    raise TypeError(f"expected date or ISO date string, got {type(value).__name__}")


def _date_string(value: date | datetime | str) -> str:
    return _as_date(value).isoformat()


def _month_end(first_day: date) -> date:
    return _next_month(first_day) - timedelta(days=1)


def _next_month(first_day: date) -> date:
    if first_day.month == 12:
        return date(first_day.year + 1, 1, 1)
    return date(first_day.year, first_day.month + 1, 1)


def _interval_minutes(interval: str) -> int:
    match = re.fullmatch(r"(\d+)([mhd])", str(interval).strip().lower())
    if not match:
        raise ValueError(f"unsupported Binance interval: {interval!r}")
    amount = int(match.group(1))
    unit = match.group(2)
    multiplier = {"m": 1, "h": 60, "d": 1440}[unit]
    minutes = amount * multiplier
    if minutes <= 0:
        raise ValueError(f"unsupported Binance interval: {interval!r}")
    return minutes


def _timestamp_to_iso(value: Any) -> str | None:
    if value is None or pd.isna(value):
        return None
    timestamp = pd.Timestamp(value)
    if timestamp.tzinfo is None:
        return timestamp.isoformat()
    return timestamp.tz_convert("UTC").isoformat().replace("+00:00", "Z")


__all__ = [
    "ArchiveDownload",
    "ArchiveNotFound",
    "BINANCE_ARCHIVE_BASE_URL",
    "BinanceDataError",
    "ChecksumError",
    "DuplicateTimestampError",
    "archive_directory",
    "build_daily_archive_url",
    "build_monthly_archive_url",
    "checksum_url",
    "daily_archive_url",
    "download_archives",
    "download_verified_archive",
    "merge_canonical_frames",
    "monthly_archive_url",
    "parse_checksum",
    "parse_kline_csv",
    "prepare_canonical_data",
    "prepare_interval_data",
    "read_zip_archive",
    "read_zip_archive_with_stats",
    "sha256_file",
]
