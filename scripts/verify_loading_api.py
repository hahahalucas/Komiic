#!/usr/bin/env python3
"""Check v0.7.0's combined detail query and public covers without account cookies.

Timings describe this runner and network only; they are not a device speed benchmark.
No protected page images, image tickets, credentials, or mutations are requested.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import http.client
import json
from pathlib import Path
import time
from urllib.parse import urlsplit, urlunsplit

ROOT = Path(__file__).resolve().parents[1]


def fields() -> str:
    source = (ROOT / "Komiic/Core/KomiicAPI.swift").read_text(encoding="utf-8-sig")
    return source.split('private static let comicFields = """', 1)[1].split('"""', 1)[0].strip()


def query(connection, origin, operation, text, variables):
    started = time.perf_counter()
    body = json.dumps(dict(operationName=operation, query=text, variables=variables)).encode()
    connection.request("POST", "/api/query", body, {
        "Content-Type": "application/json", "Accept": "application/json",
        "Origin": origin, "Referer": origin + "/", "User-Agent": "Komiic-Validation/0.7.0",
    })
    response = connection.getresponse()
    raw = response.read()
    elapsed = round((time.perf_counter() - started) * 1000, 1)
    if response.status != 200:
        raise RuntimeError(f"{origin} {operation}: HTTP {response.status}")
    result = json.loads(raw)
    if result.get("errors") or result.get("data") is None:
        raise RuntimeError(f"{origin} {operation}: GraphQL query failed")
    return result["data"], {"operation": operation, "http": response.status, "milliseconds": elapsed, "bytes": len(raw)}


def check_origin(origin, content_mode):
    connection = http.client.HTTPSConnection(urlsplit(origin).hostname, timeout=25)
    try:
        listing, listing_check = query(connection, origin, "recentUpdate",
            "query recentUpdate($pagination: Pagination!) { comics: recentUpdate(pagination: $pagination) { " + fields() + " } }",
            {"pagination": {"limit": 1, "offset": 0, "asc": False, "orderBy": "DATE_UPDATED"}})
        comic = next(row for row in listing["comics"] if row)
        if comic.get("contentType") != content_mode:
            raise RuntimeError(f"{origin}: catalog returned a different content mode")
        details, detail_check = query(connection, origin, "comicDetails",
            "query comicDetails($comicId: ID!) { comicById(comicId: $comicId) { " + fields() +
            " description sexyLevel sexyLevelReason } chaptersByComicId(comicId: $comicId) { id serial type size } }",
            {"comicId": comic["id"]})
        if details["comicById"]["id"] != comic["id"] or not isinstance(details["chaptersByComicId"], list):
            raise RuntimeError(f"{origin}: combined response missing comic or chapter directory")
        detail_check["chapters"] = sum(row is not None for row in details["chaptersByComicId"])
    finally:
        connection.close()
    checks = [listing_check, detail_check]
    cover = comic.get("imageUrl")
    if cover:
        parts = urlsplit(cover)
        if parts.hostname in ("img.komiic.com", "public.komiic.com", "download.komiic.com"):
            parts = parts._replace(netloc=parts.netloc.replace("komiic.com", "komiic.cc"))
        if parts.scheme != "https" or not (parts.hostname == "komiic.cc" or parts.hostname.endswith(".komiic.cc")):
            raise RuntimeError("Cover is not on the official HTTPS CDN")
        image_connection = http.client.HTTPSConnection(parts.hostname, timeout=25)
        try:
            started = time.perf_counter()
            image_connection.request("GET", urlunsplit(("", "", parts.path, parts.query, "")), headers={"Referer": origin + "/"})
            response = image_connection.getresponse()
            data = response.read(8 * 1024 * 1024 + 1)
            if response.status != 200 or not response.getheader("Content-Type", "").startswith("image/") or not data or len(data) > 8 * 1024 * 1024:
                raise RuntimeError(f"{origin}: invalid public cover response")
            checks.append({"operation": "publicCover", "http": response.status,
                "milliseconds": round((time.perf_counter() - started) * 1000, 1), "bytes": len(data),
                "contentType": response.getheader("Content-Type"), "cookiesSent": False})
        finally:
            image_connection.close()
    return {"origin": origin, "contentMode": content_mode, "checks": checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/v0.7.0-loading-api.json")
    options = parser.parse_args()
    report = {"version": "0.7.0", "checkedAtUTC": datetime.now(timezone.utc).isoformat(),
        "limitations": "Runner timings only; no device benchmark or authenticated session test.", "checks": []}
    try:
        for origin, mode in [("https://komiic.cc", "REGULAR"), ("https://h.komiic.cc", "H_MANGA")]:
            report["checks"].append(check_origin(origin, mode))
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=True))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
