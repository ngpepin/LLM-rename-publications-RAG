# LLM-Augmented Renaming of Publications

A Bash-first toolkit for extracting bibliographic metadata from ebooks/publications, renaming files into a stable canonical format, archiving originals, and converting common ebook formats to PDF for downstream indexing or RAG workflows.

## What This Repository Does

The project provides two rename paths:

1. **LLM-based renaming** — `rename-using-llm.sh`
   - extracts text and optional page images from the publication
   - sends bounded evidence to an OpenAI-compatible chat-completions endpoint
   - validates and repairs the model response
   - preserves source volume/edition information
   - archives the original and renames the working file in place

2. **ebook-tools metadata renaming** — `rename-using-ebooks-tools.sh`
   - runs the repository's ebook-tools workflow in Docker
   - fixes/stages the resulting metadata-based names
   - returns renamed files to the input directory and archives originals

For normal use, start with the repository launcher:

```bash
./rename-ebooks.sh /path/to/books
```

`rename-ebooks.sh` is a symlink-safe root launcher for `rename.sh`.

## Canonical Filename Format

The LLM workflow targets conventional English Title Case for the publication title and the canonical structure:

```text
Title - Author(s) (YYYY|NA) [ISBN|NA].ext
```

Examples:

```text
Mastering Linux Security and Hardening - Donald A. Tevault (2023) [9781837630516].pdf
Prometheus: Up & Running, Second Edition - Julien Pivotto and Brian Brazil (2023) [9781098131142].pdf
```

### Author separator rules

The canonical author separator is ` - `.

Do **not** use cover-style `by Author` syntax for the author field. For example:

```text
A Great Book by Jane Smith (2024) [9780306406157]
```

normalizes to:

```text
A Great Book - Jane Smith (2024) [9780306406157]
```

The normalization is context-sensitive rather than global. Legitimate title text containing the word `by` is preserved:

```text
Learn by Doing - Jane Smith (2024) [9780306406157]
```

A title may also contain earlier ` - ` separators. The workflow treats the **final** bibliographic ` - ` as the title/author boundary.

### Volume and edition preservation

The LLM flow preserves explicit bibliographic details rather than trusting a model rewrite blindly:

- numbered source volumes are retained when omitted by the model
- edition evidence is retained and normalized
- stronger source/front-matter evidence takes precedence over weaker model output
- an edition already present in the title is not duplicated

For example, this cover-style output:

```text
Skills for AI Agents, Volume 1 - First Edition (Building Context with Dynamic Skills for Agentic Systems) by Lucas B. Nicolosi Soares (2027) [9798341673991]
```

is normalized to:

```text
Skills for AI Agents, Volume 1 - First Edition (Building Context with Dynamic Skills for Agentic Systems) - Lucas B. Nicolosi Soares (2027) [9798341673991]
```

without creating an extra `First Edition` marker.

## Current File and Directory Behavior

The active Bash workflow does **not** use a `Renamed/` output directory.

### LLM rename flow

- renamed files remain in their working directory
- the pre-rename source is archived in a sibling `Originals/` directory
- unrecoverable files are moved to `Failed/`
- recursive scanning skips `Originals/` and `Failed/`
- CHM and MOBI inputs may be converted to PDF as part of the rename step
- unchanged canonical filenames are not given a pointless `_1` suffix
- `_1`, `_2`, and later suffixes are used only for genuine destination collisions
- the archived original has its own independent collision-safe naming

### Standalone conversion helpers

After a successful conversion:

- the generated PDF stays in the source directory
- the non-PDF source moves into a `Converted/` subdirectory

### ebook-tools flow

The ebook-tools path uses Docker for metadata processing and temporary staging. Final renamed files are moved back into the input directory, while original top-level files are archived under `Originals/`.

## Supported Formats

### `rename-using-llm.sh`

- PDF
- EPUB
- MOBI
- CHM

### Post-rename conversion pass in `rename.sh`

- EPUB → PDF
- MOBI → PDF
- CHM → PDF
- AZW3 → PDF

The conversion pass recursively visits directories under the target while pruning `Originals/`, `Failed/`, and `Converted/`.

## Repository Layout

- `rename-ebooks.sh` — repository-root launcher; forwards to `rename.sh`
- `rename.sh` — preferred end-to-end rename + conversion wrapper
- `rename-using-llm.sh` — primary LLM-based rename implementation
- `rename-using-ebooks-tools.sh` — alternate Docker/ebook-tools metadata flow
- `rename-using-llm.conf` — LLM endpoint/model/features configuration
- `rename-using-ebooks-tools.conf` — ebook-tools wrapper configuration
- `config.json` — ebook-tools JSON configuration
- `install-update.sh` — host dependency checker/installer
- `scripts/clean_quotes.py` — quote cleanup helper used by the LLM renamer
- `fix-matches.sh` — repairs/stages ebook-tools matches
- `prefix-by-year.sh` — prefixes files with a publication year marker
- `convert-epub-to-pdf.sh` — EPUB converter
- `convert-mobi-to-pdf.sh` — MOBI converter
- `convert-chm-to-pdf.sh` — CHM converter
- `convert-azw3-to-pdf.sh` — AZW3 converter
- `logs/` — processing logs

`README-LANGCHAIN.md` documents the older Python/LangChain implementation separately; the Bash workflow described here is the current primary path.

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/ngpepin/LLM-rename-publications-RAG.git rename-ebooks
cd rename-ebooks
```

### 2. Check host dependencies

Use the repository's host dependency entry point:

```bash
./install-update.sh --check
```

The primary LLM flow requires these commands:

- `jq`
- `pdftotext`
- `pdftoppm` when multimodal extraction is enabled
- `ebook-convert`
- `python3`
- `curl`
- `bc`

On Debian/Ubuntu, these correspond mainly to:

- `jq`
- `poppler-utils`
- `calibre`
- `python3`
- `curl`
- `bc`

To preview what the installer would do:

```bash
./install-update.sh --dry-run
```

To let it offer installation of missing Debian/Ubuntu packages interactively:

```bash
./install-update.sh
```

It does not install packages without confirmation.

### 3. ebook-tools dependencies

The alternate metadata flow additionally requires:

- Docker
- the repository's ebook-tools support files/configuration

## Configuration

The primary configuration file is:

```text
rename-using-llm.conf
```

Important values include:

```bash
PROJ_DIR="/path/to/rename-ebooks"
API_ENDPOINT="http://localhost:PORT/v1/chat/completions"
MODEL="your-model"
API_KEY=""
```

The endpoint must be compatible with the OpenAI chat-completions request/response shape expected by `rename-using-llm.sh`.

### LLM extraction and validation features

Extraction defaults include:

```bash
LLM_RESPONSE_FORMAT=json_schema
LLM_TEMPERATURE=0
LLM_MAX_TOKENS=1024
LLM_MAX_OUTPUT_TOKENS=2048
LLM_SEED=""
LLM_REASONING_EFFORT=""
LLM_EXPECTED_CONTEXT_TOKENS=0
LOG_MODEL_METADATA=false
ENABLE_MULTIMODAL=true
MULTIMODAL_INITIAL_IMAGES=3
MULTIMODAL_MAX_IMAGES=3
MULTIMODAL_SCAN_PAGES=8
MULTIMODAL_IMAGE_DPI=110
MULTIMODAL_NONWHITE_FRACTION=0.001
```

`json_schema` requests constrained JSON with separate bibliographic fields, the original title/language, and evidence-source citations. The script verifies this contract on synthetic evidence before touching books. Use `json_object` explicitly for servers that support JSON mode but not schemas, or `text` for legacy endpoints; text mode still receives deterministic cleanup and factual checks. There is no critic phase. The old `ENABLE_CRITIC` setting has no effect.

Title and credited contributors are required. Missing optional year/ISBN fields become `NA`; placeholders such as `Author(s)` are rejected. Contributor names, original titles, years, numbered editions, volumes, and ISBNs are checked against cited text where possible. ISBN-10/13 checksums and ISBN-13 prefixes are validated. Explicit format-labelled digital identifiers take precedence over print identifiers. Missing optional fields are filled deterministically only when evidence is unambiguous. Image citations remain model-derived evidence: this workflow does not independently OCR every visual claim.

When multimodal mode is enabled, `pdftoppm` is required. PDF images are ranked using copyright, ISBN, edition, and contributor clues in the corresponding page text. Image-only scans use spread-out selections when text clues are unavailable. Images carry individual page IDs. `MULTIMODAL_INITIAL_IMAGES` controls the first request; identification retries can add images up to `MULTIMODAL_MAX_IMAGES`. The configured local setup starts with three and allows up to eight. Increasing the cap does not improve every book: compare accuracy and latency on a labelled set.

EPUB OPF metadata and the first four spine resources are read directly. Declared cover and front-matter images are preferred without rendering a temporary PDF. If suitable native images are unavailable, EPUB, MOBI, and CHM can use temporary-PDF rendering. Rendering uses the matching PDF text to rank pages.

Text evidence has independent native, front-matter, bibliographic-clue, and tail budgets, with page IDs and neighboring lines around metadata matches. These settings control its size:

```bash
EXTRACT_SENT_TO_LLM_LENGTH=12000
LLM_HEAD_LINES=240
LLM_METADATA_LINES=160
LLM_TAIL_LINES=100
LLM_CONTEXT_CHARS=18000
```

The character budget excludes prompt/schema instructions and visual tokens. `LLM_EXPECTED_CONTEXT_TOKENS` is an advisory threshold checked against reported prompt usage plus the output budget; it does **not** configure the server. For Ollama, set effective context using `PARAMETER num_ctx` in a model's Modelfile, then use that model name. `LLM_REASONING_EFFORT` is omitted when empty so the model template controls thinking; use a supported value only when the endpoint/model accepts it. `LLM_SEED` is optional and does not guarantee cross-version reproducibility. See [Ollama API compatibility](https://docs.ollama.com/api/openai-compatibility) and [structured outputs](https://docs.ollama.com/capabilities/structured-outputs).

`LOG_MODEL_METADATA=true` optionally saves Ollama model details, digest, server version, and loaded context/GPU allocation when available. Unsupported metadata endpoints do not block renaming. This is enabled in the local Ollama configuration and disabled by default for generic compatible endpoints.

### Retry/timeout tuning

```bash
API_TIMEOUT_SECONDS=120
API_RETRY_DELAY_SECONDS=2
MAX_INVALID_RESPONSE_RETRIES=3
MAX_API_TRANSPORT_RETRIES=3
MAX_API_ATTEMPTS=6
API_FILE_DEADLINE_SECONDS=600
API_RETRY_MAX_DELAY_SECONDS=30
```

Invalid-output retries receive the previous output and the specific validation failure. Identification retries expand evidence within configured limits; truncated output increases the output budget up to `LLM_MAX_OUTPUT_TOKENS`. Transport failures and transient HTTP 408/425/429/500/502/503/504 responses use bounded exponential backoff with jitter and `Retry-After`. Authentication/request failures are not retried. `MAX_API_ATTEMPTS` caps all extraction calls, while the per-file deadline bounds the API/retry phase (not document conversion). Retry delays are capped at 60 seconds or less. Preflight is a separate single request bounded by `API_TIMEOUT_SECONDS`.

`RENAME_LLM_CONFIG=/path/to/config.conf` selects an alternate configuration without editing the repository's local configuration.

## Usage

### Preferred launcher

```bash
./rename-ebooks.sh /path/to/books
./rename-ebooks.sh --llm /path/to/books
./rename-ebooks.sh --ebook-tools /path/to/books
```

Help can be shown without launching the workflow:

```bash
./rename-ebooks.sh --help
```

### End-to-end wrapper

You can also call `rename.sh` directly:

```bash
./rename.sh /path/to/books
./rename.sh --llm /path/to/books
./rename.sh --ebook-tools /path/to/books
```

Options:

```text
-l, --llm          use the LLM rename flow (default)
-e, --ebook-tools  use the ebook-tools metadata flow
-h, --help         show usage
```

After the rename step, `rename.sh` converts remaining EPUB, MOBI, CHM, and AZW3 files to PDF where the corresponding helper applies.

### LLM renaming only

```bash
./rename-using-llm.sh /path/to/books
```

Use this when you want the semantic rename/archive behavior without the wrapper's later conversion pass.

### ebook-tools metadata path

Single-directory shorthand:

```bash
./rename-using-ebooks-tools.sh /path/to/books
```

Or explicit input/output options:

```bash
./rename-using-ebooks-tools.sh -i /path/to/input -o /path/to/output
```

See the script's `--help` output for its additional config, fresh-image, and debug switches.

### Individual conversion helpers

```bash
./convert-epub-to-pdf.sh /path/to/books
./convert-mobi-to-pdf.sh /path/to/books
./convert-chm-to-pdf.sh /path/to/books
./convert-azw3-to-pdf.sh /path/to/books
```

These helpers process files in the directory given to them; successful conversions archive the original source in `Converted/`.

### Prefix existing files by year

```bash
./prefix-by-year.sh /path/to/books
./prefix-by-year.sh --dry-run /path/to/books
```

The utility:

- skips names already prefixed with `YYYY - ` or `____ - `
- uses `YYYY - ` when a valid year is found
- uses `____ - ` when no year is found
- truncates safely when needed to avoid filename-length failures

## How the LLM Rename Flow Works

At a high level, `rename-using-llm.sh` does the following for each supported file:

1. identifies the current filename and extension
2. repairs a legacy possessive-name artifact when present
3. extracts text from the publication
4. reads native EPUB metadata/front matter and builds independently budgeted text sections
5. optionally selects and labels bibliographic page images
6. asks the configured model for structured metadata (or a filename in explicit legacy text mode)
7. validates factual support and retries with targeted feedback/additional evidence when needed
8. constructs the filename and performs deterministic cleanup
9. enforces the required `Title - Author (Year) [ISBN]` structure and ISBN checksums
10. preserves explicit source volume/edition information
11. normalizes terminal `by Author` credits to the canonical ` - Author` form
12. archives the original in `Originals/`
13. renames the working file in place, adding a numeric suffix only for a real collision

This layered approach is intentional: the final filename is not accepted solely because the model returned something plausible.

### Regression checks and model comparisons

Run the dependency-free regression suite with:

```bash
python3 -m unittest discover -s tests -v
bash -n rename-using-llm.sh
git diff --check
```

Each run writes a `.log.metrics.jsonl` sidecar with per-file outcome, final fields, missing optional fields, API calls/usage/time, validation failure details, transport failures, image count, fallback use, and total processing time including extraction/rendering/archive/conversion. Ten runs and their sidecars are retained. API timing excludes conversion; per-file timing includes it. Rename/conversion failures are recorded separately; failed CHM/MOBI conversion retains the working source and its archived copy and removes the partial PDF.

For a representative comparison, label 30–50 publications spanning scanned PDFs, EPUBs, multiple ISBNs, editions, volumes, missing fields, title-internal `by`, and multiple title separators. Create a manifest of expected filename **stems** (without extensions):

```json
[
  {
    "file": "fixtures/learn-by-doing.pdf",
    "expected": "Learn by Doing - Jane Smith (2024) [9780306406157]",
    "tags": ["title_by", "pdf"]
  }
]
```

Paths are relative to the manifest. Compare configurations with:

```bash
python3 scripts/benchmark_llm.py labelled-books.json \
  --config /path/to/three-images.conf \
  --config /path/to/eight-images.conf \
  --output /path/to/new-comparison-directory
```

The benchmark processes temporary copies through the actual Bash workflow and leaves source publications untouched. It saves per-book exact filename/field correctness, missing fields, retry rates, latency, logs, model metadata when enabled, and summaries by tag. Failed/unprocessed books count against accuracy. The run total includes preflight and metadata inspection; per-file totals start before extraction. Hold the corpus and model version/digest constant when evaluating image count, temperature, token budget, or quantization. Synthetic/mock tests establish behavior, not representative model accuracy or host throughput.

## Logging and Troubleshooting

Logs are written under:

```text
logs/
```

Typical filename shape:

```text
rename_books_<PID>_<TIMESTAMP>.log
```

### API connection failures

Check:

- the configured `API_ENDPOINT`
- that the server is running
- the configured `MODEL`
- the API key, if the endpoint requires one

### Text extraction failures

Check the relevant commands:

```bash
command -v pdftotext
command -v pdftoppm
command -v ebook-convert
```

or run:

```bash
./install-update.sh --check
```

### Unexpected `_1` suffixes

A numeric suffix is expected only when another file already occupies the desired destination path. Reprocessing a file whose generated canonical name is already exactly its current filename should not create `_1` just because the source itself exists.

### Author shown as `by ...`

The current canonical format does not use `by` as the author separator. A terminal cover-style `by Author (Year) [ISBN]` credit is normalized to ` - Author (Year) [ISBN]`; title text that legitimately contains `by` is preserved.

## Typical RAG Preparation Workflow

```bash
./rename-ebooks.sh /data/publications
```

Afterward, feed the normalized PDFs (and any source artifacts you intentionally retain) into your chunking, embedding, and indexing pipeline.

## Development and Validation

For shell changes, at minimum run:

```bash
bash -n path/to/changed-script.sh
git diff --check
```

Filename-normalization changes should also exercise focused edge cases such as:

- `by Author` normalization
- legitimate `by` inside a title
- titles containing multiple ` - ` separators
- edition and volume preservation
- duplicate-edition prevention
- unchanged filenames not receiving `_1`

## License

MIT License.
