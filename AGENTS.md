# AGENTS.md

## Purpose

This repository is primarily a shell-script codebase for renaming and converting ebook files for ingestion workflows.

## Working Rules

- Prefer small, direct shell changes over introducing new frameworks or abstractions.
- Keep scripts POSIX-friendly where practical, but this repo already uses Bash features, so Bash is the default target.
- Preserve the current directory semantics:
  renamed files stay in place
  originals are archived into `Originals/`
  failed files go to `Failed/`
  successful conversion-helper runs archive sources into `Converted/`
- Do not reintroduce the old `Renamed/` output model unless explicitly requested.

## Important Entry Points

- `rename.sh`
  Preferred wrapper for rename plus PDF conversion. Defaults to `--llm`; also supports `--ebook-tools`.
- `rename-using-llm.sh`
  Primary LLM-based rename flow.
- `rename-using-ebooks-tools.sh`
  Metadata-based rename flow using `ebook-tools`.
- `prefix-by-year.sh`
  Utility to prefix filenames with `YYYY - `, or `____ - ` when no year is found.
- `fix-matches.sh`
  Post-processes `ebook-tools` output.
- `convert-*-to-pdf.sh`
  Format-specific conversion helpers.

## Configuration Expectations

- `rename-using-llm.sh` depends on `rename-using-llm.conf`.
- `rename-using-ebooks-tools.sh` depends on `rename-using-ebooks-tools.conf` and `config.json`.
- Avoid hardcoding machine-specific paths outside the existing config files unless explicitly requested.

## Verification

For shell-script changes, run at least:

```bash
bash -n <script>
```

If multiple scripts are changed, run `bash -n` on each modified shell script.

## Documentation

- Update `README.md` when workflow or file-placement behavior changes.
- Keep `README.md` aligned with the current `rename.sh` CLI switches and default behavior.
- Keep examples aligned with the scripts that actually exist in the repo.
