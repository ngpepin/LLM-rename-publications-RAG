# AGENTS.md

## Purpose

This repository is a Bash-first toolkit for normalizing ebook/publication filenames, archiving originals, converting formats, and preparing files for downstream indexing or RAG workflows.

The current primary workflow is the Bash implementation. The older LangChain implementation is retained as an auxiliary/legacy path and is not the source of truth for the main rename behavior.

## Primary Entry Points

- `rename-ebooks.sh`
  Repository-root launcher. It resolves symlinks, changes to the project root, forwards arguments to `rename.sh`, and handles `-h`/`--help` without launching the workflow.
- `rename.sh`
  Preferred end-to-end workflow. Defaults to the LLM rename flow and then runs format converters where applicable.
- `rename-using-llm.sh`
  Primary content-based renamer. Reads publication evidence from the source file, calls an OpenAI-compatible chat-completions endpoint, validates/repairs the response, archives the original, and renames the working copy in place.
- `rename-using-ebooks-tools.sh`
  Alternate metadata-based path using the `didc/ebook-tools:latest` Docker image and the repository's ebook-tools support scripts.
- `convert-epub-to-pdf.sh`, `convert-mobi-to-pdf.sh`, `convert-chm-to-pdf.sh`, `convert-azw3-to-pdf.sh`
  Format-specific conversion helpers.
- `install-update.sh`
  Host dependency checker/installer entry point. `--check` and `--dry-run` must remain non-mutating.

## Canonical Filename Contract

The LLM workflow must converge on this bibliographic structure, with the publication title normalized to conventional English Title Case:

```text
Title - Author(s) (YYYY|NA) [ISBN|NA]
```

The original extension is retained unless the workflow intentionally converts the format.

Important normalization rules:

- The author boundary is the final bibliographic ` - ` separator.
- Never use `by` to introduce the author in the canonical filename.
- Cover-style terminal credits such as `... by Jane Smith (2024) [ISBN]` must normalize to `... - Jane Smith (2024) [ISBN]`.
- Legitimate `by` text inside a title must be preserved, for example `Learn by Doing - Jane Smith (2024) [ISBN]`.
- A title may itself contain earlier ` - ` separators. Code that needs the title/author boundary should use the final separator, not the first.
- Preserve explicit volume information from the source filename when the model omits it.
- Preserve edition information, preferring stronger source/front-matter evidence over weaker model output.
- Do not duplicate edition markers. A title that already contains `First Edition` must not become `First Edition - First Edition` or otherwise repeat the same edition.
- Normalize common edition spellings to the repository's canonical form where the existing helpers do so.

## Current LLM Rename Behavior

`rename-using-llm.sh` currently supports:

- PDF
- EPUB
- MOBI
- CHM

The script:

1. extracts text (`pdftotext` for PDF, `ebook-convert` for other supported formats)
2. builds a bounded evidence packet from the document
3. optionally selects and labels bibliographic page images; EPUB inputs prefer native metadata/front-matter/images and use temporary-PDF rendering when suitable native images are unavailable
4. calls the configured OpenAI-compatible chat-completions API
5. validates structured metadata and factual support, retrying with targeted feedback/additional evidence when needed; there is no critic phase
6. performs deterministic cleanup and strict filename validation
7. preserves explicit source volume/edition evidence
8. archives the pre-rename source in `Originals/`
9. leaves the renamed working file in its existing directory
10. moves unrecoverable files to `Failed/`

Additional behavior to preserve:

- `Originals/` and `Failed/` are skipped during recursive processing.
- CHM and MOBI inputs may be converted to PDF as part of the LLM rename flow.
- For other supported formats, the renamed file normally keeps its source extension until another converter is run.
- If the generated filename is exactly the current filename, do not create an unnecessary `_1` suffix merely because the source path already exists.
- Add `_1`, `_2`, etc. only when there is a genuine destination collision.
- Archiving to `Originals/` uses collision-safe naming independently of the working filename.
- Logs are written under `logs/`.

## End-to-End Wrapper Behavior

`rename.sh` accepts:

```text
-l, --llm          use the LLM rename flow (default)
-e, --ebook-tools  use the ebook-tools metadata flow
-h, --help         show help
```

After renaming, it recursively visits directories under the target and runs the individual converters for remaining:

- EPUB
- MOBI
- CHM
- AZW3

The conversion pass prunes `Originals/`, `Failed/`, and `Converted/`.

The repository-root `rename-ebooks.sh` launcher should remain a thin, symlink-safe wrapper around `rename.sh`.

## File Placement Rules

Preserve these directory semantics unless the user explicitly asks for a different model:

- successful renamed files stay in their working directory
- pre-rename originals go to sibling `Originals/`
- unrecoverable rename failures go to `Failed/`
- successful standalone conversion helpers move source files to `Converted/`
- do not reintroduce the old `Renamed/` output model for the current Bash LLM workflow

## Configuration

### LLM flow

`rename-using-llm.sh` sources `rename-using-llm.conf`.

Important settings include:

- `PROJ_DIR`
- `API_ENDPOINT`
- `MODEL`
- `API_KEY`
- `LLM_RESPONSE_FORMAT`
- `LLM_TEMPERATURE`
- `LLM_MAX_TOKENS`
- `LLM_MAX_OUTPUT_TOKENS`
- `LLM_SEED`
- `LLM_REASONING_EFFORT`
- `LLM_EXPECTED_CONTEXT_TOKENS` (advisory; actual context belongs to the server)
- `LOG_MODEL_METADATA`
- `ENABLE_MULTIMODAL`
- `MULTIMODAL_MAX_IMAGES`
- `MULTIMODAL_INITIAL_IMAGES`
- `MULTIMODAL_SCAN_PAGES`
- `MULTIMODAL_IMAGE_DPI`
- `MULTIMODAL_NONWHITE_FRACTION`
- `API_TIMEOUT_SECONDS`
- `API_RETRY_DELAY_SECONDS`
- `MAX_INVALID_RESPONSE_RETRIES`
- `MAX_API_TRANSPORT_RETRIES`
- `MAX_API_ATTEMPTS`
- `API_FILE_DEADLINE_SECONDS`
- `API_RETRY_MAX_DELAY_SECONDS`

`RENAME_LLM_CONFIG` selects an alternate config for isolated tests/benchmarks. Per-file metrics and optional model metadata are saved alongside logs. `scripts/benchmark_llm.py` processes temporary copies of a labelled corpus; originals are not renamed by the benchmark.

Do not hardcode machine-specific paths or private endpoint values into general-purpose scripts or documentation. Keep machine-specific values in configuration files.

### ebook-tools flow

`rename-using-ebooks-tools.sh` depends on:

- `rename-using-ebooks-tools.conf`
- `config.json`
- Docker
- `fix-matches.sh`
- repository ebook-tools support files

## Dependencies

For the primary LLM flow, `install-update.sh` checks these host commands:

- `jq`
- `pdftotext`
- `pdftoppm`
- `ebook-convert`
- `python3`
- `curl`
- `bc`

On Debian/Ubuntu these map primarily to `jq`, `poppler-utils`, `calibre`, `python3`, `curl`, and `bc`.

The ebook-tools path additionally requires Docker.

## Editing Rules

- Prefer focused Bash changes over new frameworks unless there is a clear repository-wide benefit.
- Bash is the default shell target; keep existing Bash idioms unless a change requires otherwise.
- Quote paths and variables unless intentional word splitting is required.
- Preserve support for filenames containing spaces and punctuation.
- Avoid broad text replacements for bibliographic cleanup. Normalize only when the surrounding filename structure establishes the intended field.
- Treat the final bibliographic separator as the author boundary when titles contain their own separators.
- Do not silently change archival or collision behavior while fixing metadata normalization.
- Keep configuration defaults backward-compatible when practical.
- Do not modify unrelated pre-existing working-tree changes.

## Verification

For any modified shell script, run at minimum:

```bash
bash -n path/to/script.sh
git diff --check
```

For `rename-using-llm.sh` changes that affect filename normalization or validation, add focused regressions for the affected edge cases. Current critical cases include:

```text
Skills for AI Agents, Volume 1 - First Edition (...) by Lucas B. Nicolosi Soares (2027) [9798341673991]
```

which must normalize to:

```text
Skills for AI Agents, Volume 1 - First Edition (...) - Lucas B. Nicolosi Soares (2027) [9798341673991]
```

Also verify:

- residual terminal `by Author` syntax is rejected by strict validation
- `Learn by Doing - Jane Smith (...)` remains unchanged
- multiple title separators still use the final ` - ` as the author boundary
- edition markers are not duplicated
- unchanged canonical filenames do not acquire a spurious `_1`

When tests are run from the gateway/container environment, report them as container validation only; do not claim host-runtime validation without explicit host-execution evidence.

## Documentation

Update `README.md` whenever any of the following changes:

- supported formats
- canonical filename format
- archive/failure/conversion directory behavior
- CLI switches or preferred entry points
- LLM configuration knobs
- host dependency requirements
- collision handling or rename semantics

Keep examples synchronized with scripts that actually exist in the repository.
