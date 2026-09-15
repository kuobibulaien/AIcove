#!/usr/bin/env python3
"""Measure a v3 sync inbox without modifying it or exporting message contents."""

import argparse
from collections import Counter
import gzip
import json
import math
from pathlib import Path
import sqlite3


def encoded(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def measure(database):
    connection = sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)
    connection.execute("PRAGMA query_only=ON")
    try:
        connection.execute("BEGIN")
        count = connection.execute("SELECT COUNT(*) FROM cloud_inbox").fetchone()[0]
        latest = connection.execute(
            "SELECT i.kind,i.entity_id,i.document_json FROM cloud_inbox i "
            "JOIN (SELECT kind,entity_id,MAX(seq) seq FROM cloud_inbox "
            "GROUP BY kind,entity_id) newest ON i.seq=newest.seq ORDER BY i.seq"
        ).fetchall()
        connection.rollback()
    finally:
        connection.close()

    counts, sizes, covered = Counter(), Counter(), Counter()
    snapshots, snapshot_ids = [], set()
    raw_bytes = projected_bytes = covered_bytes = 0
    for kind, entity_id, document_json in latest:
        counts[kind] += 1
        sizes[kind] += len(document_json.encode("utf-8"))
        if kind != "messages":
            continue
        document = json.loads(document_json)
        payload = document.get("payload") or {}
        if payload.get("message_snapshot_version") != 1:
            continue
        snapshots.append(document)
        snapshot_ids.add(entity_id)
        raw = (payload.get("row") or {}).get("raw_payload")
        if isinstance(raw, str):
            raw_bytes += len(raw.encode("utf-8"))
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if isinstance(parsed, dict) and "projectedMessages" in parsed:
                projected_bytes += len(encoded(parsed["projectedMessages"]))

    for kind, _, document_json in latest:
        owner = {
            "message_blocks": "message_id",
            "message_projection_mappings": "raw_message_id",
        }.get(kind)
        if owner is None:
            continue
        row = (json.loads(document_json).get("payload") or {}).get("row") or {}
        if row.get(owner) in snapshot_ids:
            covered[kind] += 1
            covered_bytes += len(document_json.encode("utf-8"))

    page_size = 100
    return {
        "method": "read-only consistent inbox snapshot; latest entity revision; UTF-8 JSON",
        "limits": "counts and serialization sizes only; excludes file bytes and HTTP framing; not a throughput benchmark",
        "inbox_records": count,
        "latest_entities": len(latest),
        "counts_by_kind": dict(counts),
        "stored_document_bytes_by_kind": dict(sizes),
        "message_snapshots": len(snapshots),
        "legacy_children_with_snapshot_parent": dict(covered),
        "legacy_child_document_bytes": covered_bytes,
        "legacy_child_equivalent_pages_at_100": math.ceil(sum(covered.values()) / page_size),
        "snapshot_raw_payload_utf8_bytes": raw_bytes,
        "projected_messages_json_bytes_within_raw": projected_bytes,
        "snapshot_document_json_bytes": sum(len(encoded(s)) for s in snapshots),
        "snapshot_arrays_gzip_bytes_in_100_record_pages": sum(
            len(gzip.compress(encoded(snapshots[i:i + page_size]), mtime=0))
            for i in range(0, len(snapshots), page_size)
        ),
        "gzip_level": 9,
        "note": "A covered child is superseded under the snapshot contract, not evidence it is safe to delete history.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = json.dumps(measure(args.database), ensure_ascii=False, indent=2) + "\n"
    if args.output:
        if args.output.resolve() == args.database.resolve():
            parser.error("output must not overwrite the input database")
        args.output.write_text(report, encoding="utf-8")
    else:
        print(report, end="")


if __name__ == "__main__":
    main()
