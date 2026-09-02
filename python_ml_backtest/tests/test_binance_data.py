from __future__ import annotations

import hashlib
import io
import zipfile
from datetime import date

import pandas as pd
import pytest

from auto_trading.data import (
    ChecksumError,
    DuplicateTimestampError,
    ArchiveNotFound,
    build_daily_archive_url,
    build_monthly_archive_url,
    merge_canonical_frames,
    parse_kline_csv,
    run_data_preflight,
    validate_ohlc,
)
from auto_trading.data.binance_public import download_verified_archive
from auto_trading.data.binance_public import download_archives


def _canonical_rows(*, gap: bool = False) -> pd.DataFrame:
    opens = pd.to_datetime(
        ["2024-01-01 00:00", "2024-01-01 00:30", "2024-01-01 01:00"],
        utc=True,
    )
    if gap:
        opens = opens.delete(1)
    return pd.DataFrame(
        {
            "open_time": opens,
            "open": [100.0, 101.0, 102.0][: len(opens)],
            "high": [101.0, 102.0, 103.0][: len(opens)],
            "low": [99.0, 100.0, 101.0][: len(opens)],
            "close": [100.5, 101.5, 102.5][: len(opens)],
            "close_time": opens + pd.Timedelta(minutes=30) - pd.Timedelta(milliseconds=1),
        }
    )


def test_official_archive_url_generation() -> None:
    monthly = build_monthly_archive_url("BTCUSDT", "30m", 2024, 1)
    daily = build_daily_archive_url("BTCUSDT", "30m", date(2024, 1, 2))

    assert monthly.endswith(
        "/data/futures/um/monthly/indexPriceKlines/BTCUSDT/30m/BTCUSDT-30m-2024-01.zip"
    )
    assert daily.endswith(
        "/data/futures/um/daily/indexPriceKlines/BTCUSDT/30m/BTCUSDT-30m-2024-01-02.zip"
    )


def test_csv_parser_maps_official_columns_and_converts_utc() -> None:
    csv = (
        "open_time,open,high,low,close,volume,close_time,quote_volume\n"
        "1704067200000,100,101,99,100.5,0,1704068999999,0\n"
    ).encode()

    frame = parse_kline_csv(csv)

    assert list(frame.columns) == ["open_time", "open", "high", "low", "close", "close_time"]
    assert str(frame["open_time"].dt.tz) == "UTC"
    assert frame.loc[0, "open_time"] == pd.Timestamp("2024-01-01 00:00", tz="UTC")
    assert frame.loc[0, "close_time"] == pd.Timestamp("2024-01-01 00:29:59.999", tz="UTC")
    assert frame["open"].dtype == "float64"


def test_download_verifies_checksum_with_local_mock(tmp_path) -> None:
    payload = b"small deterministic archive"
    archive_url = "https://data.binance.vision/test/archive.zip"
    checksum = hashlib.sha256(payload).hexdigest()
    calls: list[str] = []

    def fetch(url: str) -> bytes:
        calls.append(url)
        if url.endswith(".CHECKSUM"):
            return f"{checksum}  archive.zip\n".encode()
        return payload

    destination = tmp_path / "archive.zip"
    result = download_verified_archive(archive_url, destination, fetch_bytes=fetch)

    assert result.reused is False
    assert destination.read_bytes() == payload
    assert destination.with_name("archive.zip.CHECKSUM").is_file()
    assert calls == [archive_url + ".CHECKSUM", archive_url]

    second = download_verified_archive(archive_url, destination, fetch_bytes=fetch)
    assert second.reused is True
    assert calls == [archive_url + ".CHECKSUM", archive_url]


def test_checksum_mismatch_does_not_accept_archive(tmp_path) -> None:
    destination = tmp_path / "archive.zip"

    def fetch(url: str) -> bytes:
        if url.endswith(".CHECKSUM"):
            return ("0" * 64 + "  archive.zip\n").encode()
        return b"not-the-checksum"

    with pytest.raises(ChecksumError, match="checksum mismatch"):
        download_verified_archive("https://data.binance.vision/test/archive.zip", destination, fetch_bytes=fetch)
    assert not destination.exists()


def test_download_range_falls_back_to_daily_when_monthly_is_missing(tmp_path) -> None:
    payload = b"daily archive"
    checksum = hashlib.sha256(payload).hexdigest()
    calls: list[str] = []

    # Raise the public not-found error only for the monthly archive and its
    # sidecar; daily fixtures remain fully checksum-verifiable.
    def monthly_missing_fetch(url: str) -> bytes:
        calls.append(url)
        if "/monthly/" in url:
            raise ArchiveNotFound(url)
        if url.endswith(".CHECKSUM"):
            return f"{checksum}  archive.zip\n".encode()
        return payload

    results = download_archives(
        symbol="BTCUSDT",
        interval="30m",
        start_date="2024-01-01",
        end_date="2024-01-02",
        raw_root=tmp_path,
        base_url="https://example.test/data/futures/um",
        fetch_bytes=monthly_missing_fetch,
    )

    assert len(results) == 2
    assert all("/daily/" in url for url in (result.url for result in results))


def test_duplicate_merge_keeps_identical_row_and_rejects_conflict() -> None:
    frame = _canonical_rows().iloc[:1]
    merged, duplicate_count = merge_canonical_frames([frame, frame.copy()])
    assert len(merged) == 1
    assert duplicate_count == 1

    conflicting = frame.copy()
    conflicting.loc[0, "close"] = 999.0
    with pytest.raises(DuplicateTimestampError, match="conflicting duplicate"):
        merge_canonical_frames([frame, conflicting])


def test_data_preflight_reports_gap_and_validates_ohlc() -> None:
    report = run_data_preflight(_canonical_rows(gap=True))

    assert report["passed"] is True
    assert report["gap_count"] == 1
    assert report["gap_ranges"][0]["missing_bars"] == 1
    assert report["duplicate_count"] == 0

    invalid = _canonical_rows()
    invalid.loc[0, "high"] = 1.0
    errors = validate_ohlc(invalid)
    assert "high must be >= max(open, close)" in errors


def test_data_preflight_rejects_duplicate_and_non_monotonic_timestamps() -> None:
    frame = pd.concat([_canonical_rows(), _canonical_rows().iloc[[1]]], ignore_index=True)
    report = run_data_preflight(frame)

    assert report["passed"] is False
    assert report["duplicate_count"] == 1
    assert any("strictly increasing" in error for error in report["issues"])


def test_zip_fixture_can_be_read_without_network(tmp_path) -> None:
    csv = b"1000,1,2,0.5,1.5,0,1999,0\n"
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("BTCUSDT-30m-1970-01.csv", csv)
    from auto_trading.data.binance_public import read_zip_archive

    archive_path = tmp_path / "fixture.zip"
    archive_path.write_bytes(buffer.getvalue())
    frame = read_zip_archive(archive_path)
    assert frame.loc[0, "open"] == pytest.approx(1.0)
