"""Run the real Bash workflow with a local mock API and isolated publication copies."""

import json
import os
import shlex
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from test_bibliographic_metadata import ROOT, record


TEXT = "Learn by Doing\nJane Smith\nPublished 2024\nISBN: 9780306406157\n"
CANONICAL = "Learn by Doing - Jane Smith (2024) [9780306406157]"


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rename workflow ")
        self.root = Path(self.temp.name)
        self.books = self.root / "books"
        self.books.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.requests = []
        self.actions = []
        self.preflight_mode = None
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                content = payload["messages"][-1]["content"]
                prompt = content[0]["text"] if isinstance(content, list) else content
                preflight = "Connection Check" in prompt
                if not preflight:
                    outer.requests.append(payload)
                action = (outer.preflight_mode if preflight else outer.actions.pop(0) if outer.actions else "valid")
                if action in (429, 503, 401):
                    self.send_response(action)
                    self.send_header("Retry-After", "0")
                    self.end_headers()
                    self.wfile.write(b'{"error":{"message":"mock API failure"}}')
                    return
                if action == "slow":
                    import time
                    time.sleep(2)
                data = record(title="Connection Check" if preflight else "Learn by Doing")
                finish = "stop"
                if action == "placeholder":
                    data["authors"] = ["Author(s)"]
                elif action == "bad_isbn":
                    data["isbn"] = "9780306406158"
                elif action == "unidentified":
                    data.update(status="unidentified", title=None, authors=[], year=None, isbn=None,
                                sources={field: [] for field in data["sources"]})
                elif action == "truncated":
                    finish = "length"
                elif action == "foreign_author":
                    data["authors"] = ["John Doe"]
                body = {"model": "test-model", "choices": [{"message": {"content": json.dumps(data)}, "finish_reason": finish}],
                        "usage": {"prompt_tokens": 123, "completion_tokens": 80}}
                if "response_format" not in payload:
                    body["choices"][0]["message"]["content"] = ("Connection Check" if preflight else "Learn by Doing") + " - Jane Smith (2024) [9780306406157]"
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                try:
                    self.wfile.write(json.dumps(body).encode())
                except BrokenPipeError:
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.install_command("pdftotext", """import shutil,sys
shutil.copyfile(sys.argv[1],sys.argv[2])
""")
        self.install_command("ebook-convert", """import os,shutil,sys
if os.environ.get('FAKE_CONVERSION_FAIL') and sys.argv[2].endswith('.pdf'):
    open(sys.argv[2], 'w').write('partial output')
    raise SystemExit(1)
shutil.copyfile(sys.argv[1],sys.argv[2])
""")
        self.install_command("pdftoppm", """import json,os,sys
from pathlib import Path
a=sys.argv[1:]; start=int(a[a.index('-f')+1]); end=int(a[a.index('-l')+1]); source=Path(a[-2]); prefix=a[-1]
if '-jpeg' in a:
    Path(prefix+'.jpg').write_bytes(b'jpeg mock')
    with open(os.environ['FAKE_RENDER_LOG'],'a') as f: f.write(json.dumps({'page':start})+'\\n')
else:
    pages=source.read_text().split('\\f')
    for i in range(start,end+1):
        pixels=bytes([30]*4) if i<=len(pages) and pages[i-1].strip() else bytes([255]*4)
        Path(prefix+f'-{i:02}.pgm').write_bytes(b'P5\\n2 2\\n255\\n'+pixels)
""")
        self.config = self.root / "test.conf"
        self.settings = dict(PROJ_DIR=str(self.root), API_ENDPOINT=f"http://127.0.0.1:{self.server.server_port}/v1/chat/completions",
                             MODEL="test-model", API_KEY="", ENABLE_MULTIMODAL="false", LOG_MODEL_METADATA="false",
                             API_RETRY_DELAY_SECONDS="0", API_RETRY_MAX_DELAY_SECONDS="0", MAX_API_TRANSPORT_RETRIES="2",
                             MAX_INVALID_RESPONSE_RETRIES="3", MAX_API_ATTEMPTS="4", API_FILE_DEADLINE_SECONDS="20",
                             API_TIMEOUT_SECONDS="5", LLM_RESPONSE_FORMAT="json_schema")

    def install_command(self, name, code):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + code)
        path.chmod(0o755)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.temp.cleanup()

    def run_workflow(self, **env_changes):
        self.config.write_text("\n".join(f"{k}={shlex.quote(str(v))}" for k, v in self.settings.items()) + "\n")
        env = dict(os.environ, RENAME_LLM_CONFIG=str(self.config), PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   FAKE_RENDER_LOG=str(self.root / "renders.jsonl"), **env_changes)
        run = subprocess.run(["bash", str(ROOT / "rename-using-llm.sh"), str(self.books)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        files = list((self.root / "logs").glob("*.metrics.jsonl"))
        self.metrics = [json.loads(line) for path in files for line in path.read_text().splitlines()]
        return run

    def test_success_archives_original_and_skips_archive_directories(self):
        (self.books / "book with punctuation & spaces.pdf").write_text(TEXT)
        for directory in ("Originals", "Failed"):
            (self.books / directory).mkdir()
            (self.books / directory / "ignored.pdf").write_text(TEXT)
        self.run_workflow()
        self.assertTrue((self.books / (CANONICAL + ".pdf")).exists())
        self.assertTrue((self.books / "Originals/book with punctuation & spaces.pdf").exists())
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.metrics[0]["outcome"], "success")
        self.assertEqual(self.metrics[0]["api_calls"], 1)
        self.assertEqual(self.metrics[0]["prompt_tokens"], 123)
        self.assertGreaterEqual(self.metrics[0]["total_seconds"], self.metrics[0]["api_seconds"])

    def test_unchanged_name_and_independent_archive_collision(self):
        (self.books / (CANONICAL + ".pdf")).write_text(TEXT)
        (self.books / "Originals").mkdir()
        (self.books / "Originals" / (CANONICAL + ".pdf")).write_text("older archive")
        self.run_workflow()
        self.assertTrue((self.books / (CANONICAL + ".pdf")).exists())
        self.assertFalse((self.books / (CANONICAL + "_1.pdf")).exists())
        self.assertEqual((self.books / "Originals" / (CANONICAL + "_1.pdf")).read_text(), TEXT)

    def test_genuine_working_collision(self):
        (self.books / "original.pdf").write_text(TEXT)
        (self.books / (CANONICAL + ".pdf")).write_text(TEXT)
        self.run_workflow()
        self.assertTrue((self.books / (CANONICAL + ".pdf")).exists())
        self.assertTrue((self.books / (CANONICAL + "_1.pdf")).exists())

    def test_placeholder_retry_has_targeted_feedback(self):
        (self.books / "original.pdf").write_text(TEXT)
        self.actions = ["placeholder", "valid"]
        self.run_workflow()
        self.assertEqual(len(self.requests), 2)
        self.assertIn("placeholder", self.requests[1]["messages"][-1]["content"])
        self.assertEqual(self.metrics[0]["invalid_responses"], 1)
        self.assertTrue((self.books / (CANONICAL + ".pdf")).exists())

    def test_truncated_output_retry_increases_budget(self):
        (self.books / "original.pdf").write_text(TEXT)
        self.actions = ["truncated", "valid"]
        self.run_workflow()
        self.assertEqual(self.requests[1]["max_tokens"], 2 * self.requests[0]["max_tokens"])
        self.assertIn("finish_reason=length", self.requests[1]["messages"][-1]["content"])

    def test_transport_retries_bounded(self):
        (self.books / "original.pdf").write_text(TEXT)
        self.actions = [429, 503, "valid"]
        self.run_workflow()
        self.assertEqual(len(self.requests), 2)
        self.assertTrue((self.books / "Failed/original.pdf").exists())
        self.assertEqual(self.metrics[0]["transport_failures"], 2)
        self.assertEqual(self.metrics[0]["outcome"], "failed")

    def test_auth_failure_not_retried(self):
        (self.books / "original.pdf").write_text(TEXT)
        self.actions = [401, "valid"]
        self.run_workflow()
        self.assertEqual(len(self.requests), 1)

    def test_total_attempt_cap_covers_transport_and_invalid_output(self):
        self.settings.update(MAX_API_ATTEMPTS="2", MAX_API_TRANSPORT_RETRIES="5")
        (self.books / "original.pdf").write_text(TEXT)
        self.actions = ["placeholder", 503, "valid"]
        self.run_workflow()
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(self.metrics[0]["outcome"], "failed")

    def test_api_deadline_bounds_a_slow_call(self):
        self.settings["API_FILE_DEADLINE_SECONDS"] = "1"
        (self.books / "original.pdf").write_text(TEXT)
        self.actions = ["slow", "valid"]
        self.run_workflow()
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.metrics[0]["outcome"], "failed")
        self.assertEqual(self.metrics[0]["transport_failures"], 1)

    def test_invalid_metadata_never_renamed(self):
        (self.books / "original.pdf").write_text(TEXT)
        self.actions = ["bad_isbn"] * 3
        self.run_workflow()
        self.assertEqual(len(self.requests), 3)
        self.assertTrue((self.books / "Failed/original.pdf").exists())
        self.assertFalse((self.books / (CANONICAL + ".pdf")).exists())

    def test_source_fallback_preserves_existing_canonical_name(self):
        (self.books / (CANONICAL + ".pdf")).write_text(TEXT)
        self.actions = ["unidentified"]
        self.run_workflow()
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.metrics[0]["fallback"], "source_filename")
        self.assertTrue((self.books / (CANONICAL + ".pdf")).exists())

    def test_images_ranked_labelled_and_expanded_on_retry(self):
        self.settings.update(ENABLE_MULTIMODAL="true", MULTIMODAL_INITIAL_IMAGES="2", MULTIMODAL_MAX_IMAGES="4", MULTIMODAL_SCAN_PAGES="6")
        (self.books / "original.pdf").write_text(TEXT + "\fBody\fContents\fBody\fCopyright 2024 ISBN: 9780306406157\fBody")
        self.actions = ["unidentified", "valid"]
        self.run_workflow()
        counts = [sum(c["type"] == "image_url" for c in r["messages"][-1]["content"]) for r in self.requests]
        self.assertEqual(counts, [2, 4])
        self.assertIn("IMAGE_P5", json.dumps(self.requests[0]))

    def test_legacy_text_endpoint(self):
        self.settings["LLM_RESPONSE_FORMAT"] = "text"
        (self.books / "original.pdf").write_text(TEXT)
        self.run_workflow()
        self.assertTrue((self.books / (CANONICAL + ".pdf")).exists())
        self.assertNotIn("response_format", self.requests[0])

    def test_chm_conversion_archives_source(self):
        (self.books / "original.chm").write_text(TEXT)
        self.run_workflow()
        self.assertTrue((self.books / (CANONICAL + ".pdf")).exists())
        self.assertFalse((self.books / "original.chm").exists())
        self.assertTrue((self.books / "Originals/original.chm").exists())

    def test_failed_conversion_retains_source_and_records_failure(self):
        (self.books / "original.chm").write_text(TEXT)
        self.run_workflow(FAKE_CONVERSION_FAIL="1")
        self.assertTrue((self.books / "original.chm").exists())
        self.assertTrue((self.books / "Originals/original.chm").exists())
        self.assertFalse((self.books / (CANONICAL + ".pdf")).exists())
        self.assertEqual(self.metrics[0]["outcome"], "conversion_failed")

    def test_benchmark_processes_copies_and_reports_accuracy(self):
        original = self.books / "original.pdf"
        original.write_text(TEXT)
        self.config.write_text("\n".join(f"{k}={shlex.quote(str(v))}" for k, v in self.settings.items()) + "\n")
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps([{"file": "books/original.pdf", "expected": CANONICAL, "tags": ["title_by"]}]))
        output = self.root / "comparison"
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], FAKE_RENDER_LOG=str(self.root / "renders.jsonl"))
        run = subprocess.run(["python3", str(ROOT / "scripts/benchmark_llm.py"), str(manifest),
                              "--config", str(self.config), "--config", str(self.config), "--output", str(output)],
                             env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        summaries = json.loads((output / "summary.json").read_text())
        self.assertEqual(len(summaries), 2)
        self.assertTrue(all(s["exact_filename_accuracy"] == 1 for s in summaries))
        self.assertEqual(summaries[0]["by_tag"]["title_by"]["books"], 1)
        self.assertEqual(original.read_text(), TEXT)
        self.assertFalse((self.books / "Originals").exists())


if __name__ == "__main__":
    unittest.main()
