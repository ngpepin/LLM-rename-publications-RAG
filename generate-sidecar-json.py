#!/usr/bin/env python3
import argparse
import hashlib
import json
import mimetypes
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Any, Optional, List

SUPPORTED_EXTS = {".pdf", ".epub", ".mobi", ".chm", ".txt"}

LOG_JSONL_PATTERN_KEYS = {
    "original_path", "renamed_path", "original", "renamed",
    "orig_path", "new_path"
}

RENAMED_LINE_REGEXES = [
    re.compile(r"Renamed:\s*(?P<original>.+?)\s*->\s*(?P<renamed>.+)", re.IGNORECASE),
    re.compile(r"Original:\s*(?P<original>.+?)\s*New:\s*(?P<renamed>.+)", re.IGNORECASE),
    re.compile(r"(?P<original>.+?)\s*=>\s*(?P<renamed>.+)")
]

FILENAME_METADATA_REGEXES = [
    # e.g., 2021_DeepLearningForFinance_Smith.pdf
    re.compile(r"^(?P<year>\d{4})[_\- ](?P<title>[^_\-]+)[_\- ](?P<author>[^.]+)$"),
    # e.g., DeepLearningForFinance - John Smith.pdf
    re.compile(r"^(?P<title>[^\-]+)\s*-\s*(?P<author>[^.]+)$"),
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def load_config(conf_path: Optional[Path], json_path: Optional[Path]) -> Dict[str, Any]:
    cfg: Dict[str, Any] = {}
    if json_path and json_path.exists():
        try:
            with json_path.open("r", encoding="utf-8") as f:
                cfg.update(json.load(f))
        except Exception:
            pass
    if conf_path and conf_path.exists():
        # simple key=value parser
        try:
            for line in conf_path.read_text(encoding="utf-8", errors="ignore").splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    cfg.setdefault(k.strip(), v.strip())
        except Exception:
            pass
    return cfg


def build_log_mapping(logs_dir: Optional[Path]) -> Dict[str, Dict[str, Any]]:
    """Return mapping from canonical path to info: {original_path, metadata, llm}.
    Attempts to read *.jsonl/*.ndjson first, then falls back to regex parsing of .log/.txt.
    """
    mapping: Dict[str, Dict[str, Any]] = {}
    if not logs_dir or not logs_dir.exists():
        return mapping

    # JSONL/NDJSON
    for p in logs_dir.glob("**/*"):
        if p.suffix.lower() in {".jsonl", ".ndjson"}:
            try:
                with p.open("r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            obj = json.loads(line)
                        except Exception:
                            continue
                        keys = set(obj.keys())
                        key_candidates = keys & LOG_JSONL_PATTERN_KEYS
                        renamed = None
                        original = None
                        if "renamed_path" in obj:
                            renamed = obj["renamed_path"]
                        elif "renamed" in obj:
                            renamed = obj["renamed"]
                        elif "new_path" in obj:
                            renamed = obj["new_path"]
                        if "original_path" in obj:
                            original = obj["original_path"]
                        elif "original" in obj:
                            original = obj["original"]
                        elif "orig_path" in obj:
                            original = obj["orig_path"]
                        if renamed:
                            info = {
                                "original_path": original,
                                "metadata": obj.get("metadata", {}),
                                "llm": {
                                    "model": obj.get("model") or obj.get("llm_model"),
                                    "endpoint": obj.get("endpoint") or obj.get("llm_endpoint"),
                                    "confidence": obj.get("confidence")
                                }
                            }
                            mapping[Path(renamed).resolve().as_posix()] = info
            except Exception:
                continue

    # Regex logs (*.log, *.txt)
    for p in logs_dir.glob("**/*"):
        if p.suffix.lower() in {".log", ".txt"}:
            try:
                text = p.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue
            for line in text.splitlines():
                for rgx in RENAMED_LINE_REGEXES:
                    m = rgx.search(line)
                    if m:
                        original = m.group("original").strip()
                        renamed = m.group("renamed").strip()
                        mapping[Path(renamed).resolve().as_posix()] = {
                            "original_path": original,
                            "metadata": {},
                            "llm": {}
                        }
                        break
    return mapping


def infer_metadata_from_filename(stem: str) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for rgx in FILENAME_METADATA_REGEXES:
        m = rgx.match(stem)
        if m:
            gd = m.groupdict()
            if gd.get("title"):
                result["title"] = gd["title"].replace("_", " ").strip()
            if gd.get("author"):
                result["author"] = gd["author"].replace("_", " ").strip()
            if gd.get("year"):
                result["publication_date"] = gd["year"]
            result["metadata_source"] = "filename"
            return result
    result["metadata_source"] = "unknown"
    return result


def build_sidecar_for_file(file_path: Path,
                            mapping: Dict[str, Dict[str, Any]],
                            cfg: Dict[str, Any]) -> Dict[str, Any]:
    canonical = file_path.resolve()
    canonical_key = canonical.as_posix()

    stat = file_path.stat()
    ext = file_path.suffix.lower().lstrip(".")
    mime, _ = mimetypes.guess_type(str(file_path))

    entry = {
        "source_path": canonical_key,
        "canonical_filename": file_path.name,
        "original_filename": None,
        "file_format": ext,
        "mime_type": mime,
        "size_bytes": stat.st_size,
        "sha256": sha256_file(file_path),
        "title": None,
        "author": None,
        "publication_date": None,
        "summary": None,
        "domain_topics": [],
        "llm": {
            "model": cfg.get("model") or cfg.get("llm_model") or cfg.get("MODEL"),
            "endpoint": cfg.get("endpoint") or cfg.get("llm_endpoint") or cfg.get("ENDPOINT"),
            "confidence": None,
        },
        "metadata_source": "unknown",
        "created_at": datetime.now(timezone.utc).isoformat(),
    }

    # Logs mapping enrichment
    info = mapping.get(canonical_key)
    if info:
        entry["original_filename"] = Path(info.get("original_path") or "").name or entry["original_filename"]
        md = info.get("metadata") or {}
        for k in ("title", "author", "publication_date", "summary", "domain_topics"):
            if md.get(k) is not None:
                entry[k] = md.get(k)
        if info.get("llm"):
            for k in ("model", "endpoint", "confidence"):
                if info["llm"].get(k) is not None:
                    entry["llm"][k] = info["llm"][k]
        entry["metadata_source"] = "llm" if md else entry["metadata_source"]

    # Fallback: infer from filename
    if not entry["title"] and not entry["author"]:
        stem = file_path.stem
        inferred = infer_metadata_from_filename(stem)
        entry.update({k: v for k, v in inferred.items() if k != "metadata_source"})
        entry["metadata_source"] = inferred.get("metadata_source", entry["metadata_source"])

    return entry


def write_sidecar(file_path: Path, sidecar: Dict[str, Any], out_dir: Optional[Path]) -> Path:
    if out_dir:
        rel = file_path.name + ".json"
        target = out_dir / rel
    else:
        target = file_path.with_suffix(file_path.suffix + ".json")
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("w", encoding="utf-8") as f:
        json.dump(sidecar, f, ensure_ascii=False, indent=2)
    return target


def main():
    ap = argparse.ArgumentParser(description="Generate sidecar metadata JSON for RAG indexing from renamed publications and optional logs.")
    ap.add_argument("-i", "--input-dir", type=str, required=True, help="Directory containing renamed publications.")
    ap.add_argument("-l", "--logs-dir", type=str, default=None, help="Directory containing logs (optional).")
    ap.add_argument("-o", "--output-dir", type=str, default=None, help="Directory to write sidecar JSONs (optional; defaults alongside files).")
    ap.add_argument("--config-json", type=str, default="config.json", help="Path to config.json (optional).")
    ap.add_argument("--conf", type=str, default="rename-using-llm.conf", help="Path to rename-using-llm.conf (optional).")
    ap.add_argument("--exts", type=str, default=",".join(sorted(SUPPORTED_EXTS)), help="Comma-separated list of extensions to include.")

    args = ap.parse_args()

    input_dir = Path(args.input_dir).resolve()
    if not input_dir.exists():
        print(f"Input dir not found: {input_dir}", file=sys.stderr)
        sys.exit(1)

    logs_dir = Path(args.logs_dir).resolve() if args.logs_dir else None
    output_dir = Path(args.output_dir).resolve() if args.output_dir else None

    cfg = load_config(Path(args.conf) if args.conf else None,
                      Path(args.config_json) if args.config_json else None)

    include_exts = {e.strip().lower() for e in args.exts.split(",") if e.strip()}

    mapping = build_log_mapping(logs_dir)

    files: List[Path] = [p for p in input_dir.rglob("*") if p.is_file() and p.suffix.lower() in include_exts]
    if not files:
        print("No files found matching provided extensions.")
        sys.exit(0)

    written = 0
    for p in files:
        sidecar = build_sidecar_for_file(p, mapping, cfg)
        target = write_sidecar(p, sidecar, output_dir)
        print(target.as_posix())
        written += 1

    print(f"Generated {written} sidecar JSON files.")


if __name__ == "__main__":
    main()
