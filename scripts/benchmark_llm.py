#!/usr/bin/env python3
"""Compare LLM configurations on isolated copies of a labelled publication set."""

import argparse
import json
import os
import shlex
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

from bibliographic_metadata import filename_parts, folded, validate_filename


def compare(expected, actual):
    expected_parts = validate_filename(expected)
    if actual is None:
        return {"exact_filename": False, **{k: False for k in ("title", "authors", "year", "isbn")}}
    actual_parts = filename_parts(actual)
    return {"exact_filename": expected == actual,
            **{k: folded(a) == folded(b) for k, a, b in zip(("title", "authors", "year", "isbn"), expected_parts, actual_parts)}}


def summarize(rows):
    successful = [r for r in rows if r["outcome"] == "success"]
    n = len(rows)
    missing = sum(r.get("missing_optional_fields", 0) for r in successful)
    retried = sum(r["api_calls"] > 1 for r in rows)
    errors = [error for row in rows for error in row.get("validation_errors", [])]
    return {"books": n, "successful": len(successful),
            "exact_filename_accuracy": sum(r["correct"]["exact_filename"] for r in rows) / n if n else 0,
            "field_accuracy": {field: sum(r["correct"][field] for r in rows) / n if n else 0 for field in ("title", "authors", "year", "isbn")},
            "median_total_seconds": statistics.median(r["total_seconds"] for r in rows) if rows else None,
            "total_api_calls": sum(r["api_calls"] for r in rows),
            "invalid_responses": sum(r["invalid_responses"] for r in rows),
            "transport_failures": sum(r["transport_failures"] for r in rows),
            "missing_optional_fields": missing,
            "missing_optional_field_rate": missing / (2 * len(successful)) if successful else None,
            "placeholder_rejections": sum("placeholder" in error.lower() for error in errors),
            "isbn_checksum_rejections": sum("checksum" in error.lower() for error in errors),
            "results_with_retries": retried, "retry_rate": retried / n if n else 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="JSON array of {file, expected, tags?}; paths relative to manifest")
    parser.add_argument("--config", type=Path, action="append", required=True, help="repeat for each configuration to compare")
    parser.add_argument("--output", type=Path, required=True, help="new or empty results directory")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads(args.manifest.read_text())
    if not isinstance(manifest, list) or not manifest:
        parser.error("manifest must be a nonempty array")
    cases = []
    for index, entry in enumerate(manifest):
        source = (args.manifest.resolve().parent / entry["file"]).resolve()
        if not source.is_file() or source.suffix.lower() not in (".pdf", ".epub", ".mobi", ".chm"):
            parser.error(f"unsupported or missing publication at entry {index}")
        validate_filename(entry["expected"])
        cases.append((source, entry))
    for config in args.config:
        if not config.is_file():
            parser.error(f"configuration not found: {config}")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("output directory must be new or empty")
    args.output.mkdir(parents=True, exist_ok=True)
    summaries = []
    for number, config in enumerate(args.config, 1):
        label = f"{number:02}-{config.stem}"
        destination = args.output / label
        destination.mkdir()
        with tempfile.TemporaryDirectory(prefix="rename-benchmark-") as directory:
            work = Path(directory)
            books = work / "books"
            mapping = {}
            for index, (source, entry) in enumerate(cases):
                book_dir = books / f"case-{index:04}"
                book_dir.mkdir(parents=True)
                copy = book_dir / source.name
                shutil.copy2(source, copy)
                mapping[str(copy)] = (source, entry)
            override = work / "benchmark.conf"
            override.write_text("source " + shlex.quote(str(config.resolve())) + "\nPROJ_DIR=" + shlex.quote(str(work)) + "\n")
            started = time.monotonic()
            env = dict(os.environ, RENAME_LLM_CONFIG=str(override))
            with (destination / "console.log").open("w") as output:
                run = subprocess.run(["bash", str(root / "rename-using-llm.sh"), str(books)],
                                     env=env, stdout=output, stderr=subprocess.STDOUT)
            run_seconds = time.monotonic() - started
            metrics_files = list((work / "logs").glob("*.metrics.jsonl"))
            rows = []
            for path in metrics_files:
                for line in path.read_text().splitlines():
                    row = json.loads(line)
                    source, entry = mapping[row["source"]]
                    row["source"] = str(source)
                    row["expected"] = entry["expected"]
                    row["tags"] = entry.get("tags", [])
                    row["correct"] = compare(entry["expected"], row["candidate"] if row["outcome"] == "success" else None)
                    rows.append(row)
            processed = {r["source"] for r in rows}
            for source, entry in cases:
                if str(source) not in processed:
                    rows.append(dict(source=str(source), expected=entry["expected"], candidate=None,
                                     outcome="not_processed", total_seconds=0, api_calls=0, invalid_responses=0,
                                     transport_failures=0, tags=entry.get("tags", []), correct=compare(entry["expected"], None)))
            with (destination / "results.jsonl").open("w") as output:
                for row in rows:
                    output.write(json.dumps(row, ensure_ascii=False) + "\n")
            logs = work / "logs"
            if logs.exists():
                shutil.copytree(logs, destination / "logs")
            summary = {"configuration": label, "exit_code": run.returncode, "run_total_seconds": run_seconds,
                       **summarize(rows)}
            tags = sorted({tag for row in rows for tag in row["tags"]})
            summary["by_tag"] = {tag: summarize([r for r in rows if tag in r["tags"]]) for tag in tags}
            summaries.append(summary)
            print(json.dumps(summary, ensure_ascii=False), flush=True)
    (args.output / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
    return 1 if any(r["exit_code"] or r["successful"] < r["books"] for r in summaries) else 0


if __name__ == "__main__":
    raise SystemExit(main())
