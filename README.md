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
A Great Book by Jane Smith (2024) [9781234567890]
```

normalizes to:

```text
A Great Book - Jane Smith (2024) [9781234567890]
```

The normalization is context-sensitive rather than global. Legitimate title text containing the word `by` is preserved:

```text
Learn by Doing - Jane Smith (2024) [9781234567890]
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

Current feature switches include:

```bash
ENABLE_CRITIC=true
ENABLE_MULTIMODAL=true
MULTIMODAL_MAX_IMAGES=3
MULTIMODAL_SCAN_PAGES=8
MULTIMODAL_IMAGE_DPI=110
MULTIMODAL_NONWHITE_FRACTION=0.001
```

When multimodal mode is enabled, `pdftoppm` is required. PDF inputs are scanned directly. EPUB, MOBI, and CHM inputs are first converted to a temporary PDF for page-image extraction; for EPUB specifically, if that temporary PDF conversion fails, the script falls back to selected embedded EPUB images (prioritizing declared cover artwork) so multimodal evidence can still be supplied.

### Retry/timeout tuning

```bash
API_TIMEOUT_SECONDS=120
API_RETRY_DELAY_SECONDS=2
MAX_INVALID_RESPONSE_RETRIES=3
```

The script tests API connectivity before processing the input set and writes failures to the processing log.

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
4. builds a bounded evidence packet from likely bibliographic portions of the document
5. optionally extracts page images for multimodal evidence
6. asks the configured model for a canonical filename stem
7. optionally asks a critic pass to repair a weak first result
8. performs deterministic cleanup
9. enforces the required `Title - Author (Year) [ISBN]` structure
10. preserves explicit source volume/edition information
11. normalizes terminal `by Author` credits to the canonical ` - Author` form
12. archives the original in `Originals/`
13. renames the working file in place, adding a numeric suffix only for a real collision

This layered approach is intentional: the final filename is not accepted solely because the model returned something plausible.

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
