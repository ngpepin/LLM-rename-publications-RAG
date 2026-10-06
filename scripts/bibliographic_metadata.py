#!/usr/bin/env python3
"""Small, dependency-free evidence and validation helpers for the Bash workflow."""

import argparse
import base64
import html
from email.utils import parsedate_to_datetime
import json
import mimetypes
import posixpath
import random
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET


FIELDS = ("title", "authors", "edition", "volume", "year", "isbn")
PLACEHOLDER = re.compile(
    r"(?i)^(?:\(?\s*(?:author(?:\(s\)|s)?|title|book title|unknown|n/?a|none|null|"
    r"not (?:known|available)|editor(?:\(s\)|s)?)\s*\)?|\[.*\]|<.*>)$"
)
CLUES = re.compile(r"(?i)\bisbn(?:-1[03])?\b|©|\bcopyright\b|\b(?:published|publication|edition|written by|edited by|author|volume|publisher|imprint)\b")
STRONG_CLUES = re.compile(r"(?i)\bisbn(?:-1[03])?\b|©|\bcopyright\b|\b(?:edition|published|publication)\b")
NAME_PATTERN = r".+ - .+ \((?:\d{4}|NA)\) \[(?:\d{13}|\d{9}[\dX]|NA)\]"
ORDINALS = "first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth".split()
EDITION_RE = re.compile(r"(?i)\b(\d{1,2}(?:st|nd|rd|th)?|" + "|".join(ORDINALS) + r")\s+(?:edition\b|ed\.?(?=$|[\s,;:)\].-]))")
VOLUME_RE = re.compile(r"(?i)\b(?:volume|vol\.?)\s*([0-9]+|[ivxlcdm]+)\b")


def edition_numbers(text):
    values = {ORDINALS.index(m[1].lower()) + 1 if m[1].lower() in ORDINALS else int(re.match(r"\d+", m[1])[0]) for m in EDITION_RE.finditer(text)}
    for m in re.finditer(r"(?i)\b((?:revised|updated|expanded)(?:\s+(?:and\s+)?(?:revised|updated|expanded))*)\s+edition\b", text):
        values.add(folded(m[1]))
    return values


def volume_numbers(text):
    def value(token):
        if token.isdigit():
            return int(token)
        numerals = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}
        digits = [numerals[c] for c in token.upper()]
        return sum(-v if i + 1 < len(digits) and v < digits[i + 1] else v for i, v in enumerate(digits))
    return {value(m[1]) for m in VOLUME_RE.finditer(text)}


def folded(value):
    value = unicodedata.normalize("NFKD", value).casefold()
    return " ".join(re.findall(r"[^\W_]+", "".join(c for c in value if not unicodedata.combining(c))))


def isbn_normalize(value):
    return re.sub(r"[\s-]", "", re.sub(r"(?i)^ISBN(?:-?1[03])?\s*:?\s*", "", value or "")).upper()


def isbn_valid(value):
    value = isbn_normalize(value)
    if re.fullmatch(r"\d{13}", value):
        return value.startswith(("978", "979")) and sum(int(c) * (1 if i % 2 == 0 else 3) for i, c in enumerate(value)) % 10 == 0
    if re.fullmatch(r"\d{9}[\dX]", value):
        return sum((10 - i) * (10 if c == "X" else int(c)) for i, c in enumerate(value)) % 11 == 0
    return False


def filename_parts(value, partial=False):
    value = value.strip()
    isbn = None
    year = None
    m = re.search(r"\s*\[([^\[\]]+)\]\s*$", value)
    if m:
        isbn = isbn_normalize(m[1])
        value = value[:m.start()].rstrip()
    else:
        m = re.search(r"(?i)\s*\(ISBN(?:-1[03])?\s*:?\s*([^()]+)\)\s*$", value)
        if m:
            isbn = isbn_normalize(m[1])
            value = value[:m.start()].rstrip()
    m = re.search(r"\s*\((\d{4}|NA)\)\s*$", value, re.I)
    if m:
        year = m[1].upper()
        value = value[:m.start()].rstrip()
    if " - " not in value:
        raise ValueError("missing final title/author separator")
    title, authors = value.rsplit(" - ", 1)
    if not title.strip() or not authors.strip():
        raise ValueError("title and authors must be nonempty")
    if not partial and (year is None or isbn is None):
        raise ValueError("missing year or ISBN field")
    return title.strip(), authors.strip(), year, isbn


def validate_filename(value):
    if "\n" in value or "\r" in value or "/" in value or not re.fullmatch(NAME_PATTERN, value):
        raise ValueError("candidate must be one canonical filename line")
    title, authors, year, isbn = filename_parts(value)
    if PLACEHOLDER.fullmatch(title) or any(PLACEHOLDER.fullmatch(n.strip()) for n in re.split(r"\s*;\s*|\s*,\s*", authors)):
        raise ValueError("placeholder title or contributor is not bibliographic metadata")
    if re.search(r"(?i)\bby\s", authors) or re.search(r"\(\d{4}\)", authors):
        raise ValueError("author field contains a residual credit or publication year")
    if isbn != "NA" and not isbn_valid(isbn):
        raise ValueError("ISBN checksum or prefix is invalid")
    return title, authors, year, isbn


def clean_pages(text, max_lines=12000):
    result = []
    remaining = max_lines
    # Keep PDF form-feed boundaries before cleaning OCR whitespace.
    for number, page in enumerate(text.split("\f"), 1):
        if remaining <= 0:
            break
        raw_lines = page.splitlines()[:remaining]
        remaining -= len(raw_lines)
        page = unicodedata.normalize("NFKC", "\n".join(raw_lines)).replace("\u00ad", "")
        page = re.sub(r"(?<=\w)-[ \t]*\n[ \t]*(?=[a-z])", "", page)
        lines = []
        for line in page.splitlines():
            line = re.sub(r"[\x00-\x1f\x7f]", " ", line)
            line = re.sub(r" +", " ", line).strip()
            standalone_page_number = re.fullmatch(r"\d{1,3}", line)
            after_volume_label = lines and re.fullmatch(r"(?i)(?:volume|vol\.?|part|edition)", lines[-1])
            # Uppercase Roman numerals can be volume/title evidence; retain them.
            # Retain a digit on its own line after an explicit volume/edition label.
            if standalone_page_number and not after_volume_label or re.fullmatch(r"[ivxlcdm]{1,8}", line):
                continue
            if line:
                lines.append(line)
        if lines:
            result.append((f"TEXT_P{number}", lines))
    return result


def fit_chunks(chunks, budget):
    out = ""
    for source_id, lines in chunks:
        prefix = f"[{source_id}]\n"
        if budget - len(out) <= len(prefix) + 1:
            break
        content = "\n".join(lines)
        available = budget - len(out) - len(prefix) - 1
        if len(content) > available:
            shortened = content[:available]
            # Prefer complete lines, but retain a useful part of an oversized line.
            content = shortened.rsplit("\n", 1)[0] if "\n" in shortened else shortened
        out += prefix + content + "\n"
    return out


def evidence_packet(text, native="", max_lines=12000, head_lines=240, tail_lines=100,
                    metadata_lines=160, max_chars=18000, front_pages=14):
    pages = clean_pages(text, max_lines)
    head, tail, clues = [], [], []
    remaining = head_lines
    for sid, lines in pages:
        if remaining <= 0:
            break
        if int(sid.removeprefix("TEXT_P")) <= front_pages:
            head.append((sid, lines[:remaining]))
            remaining -= len(lines[:remaining])
    remaining = tail_lines
    for sid, lines in reversed(pages):
        if remaining <= 0:
            break
        tail.insert(0, (sid, lines[-remaining:]))
        remaining -= len(lines[-remaining:])
    for sid, lines in pages:
        indexes = [i for i, line in enumerate(lines) if CLUES.search(line)]
        # Preserve local context and prioritize copyright/edition/ISBN over generic references.
        for i in indexes:
            score = 100 if STRONG_CLUES.search(lines[i]) else 10
            score += 20 if int(sid.removeprefix("TEXT_P")) <= front_pages else 0
            clues.append((score, sid, i, lines[max(0, i - 2):i + 3]))
    clues.sort(key=lambda c: (-c[0], int(c[1].removeprefix("TEXT_P")), c[2]))
    selected, seen, line_count = [], set(), 0
    for _, sid, _, lines in clues:
        if line_count >= metadata_lines:
            break
        key = (sid, tuple(lines))
        if key not in seen:
            seen.add(key)
            selected.append((sid, lines))
            line_count += len(lines)
    headers = ["=== NATIVE EPUB EVIDENCE ===\n", f"=== FRONT MATTER ===\nFront-matter page limit: {front_pages}\n",
               "=== BIBLIOGRAPHIC CLUES ===\n", "=== END OF SAMPLED TEXT ===\n"]
    budget = max(0, max_chars - sum(map(len, headers)))
    native_budget = int(budget * 0.20) if native else 0
    rest = budget - native_budget
    clue_budget = int(rest * 0.45)
    head_budget = int(rest * 0.45)
    native = native[:native_budget]
    # Section budgets are independent: long opening prose cannot evict metadata.
    return (headers[0] + native + headers[1] + fit_chunks(head, head_budget) +
            headers[2] + fit_chunks(selected, clue_budget) +
            headers[3] + fit_chunks(tail, rest - clue_budget - head_budget))[:max_chars]


def epub_package(archive):
    container = ET.fromstring(archive.read("META-INF/container.xml"))
    root = next(e.attrib["full-path"] for e in container.iter() if e.tag.endswith("rootfile") and e.attrib.get("full-path"))
    package = ET.fromstring(archive.read(root))
    base = posixpath.dirname(root)
    items = {}
    for e in package.iter():
        if e.tag.endswith("item") and e.attrib.get("href"):
            path = posixpath.normpath(posixpath.join(base, urllib.parse.unquote(e.attrib["href"].split("#")[0])))
            items[e.attrib.get("id")] = (path, e.attrib.get("media-type", ""), e.attrib.get("properties", ""))
    return package, items


def epub_evidence(source):
    try:
        with zipfile.ZipFile(source) as archive:
            package, items = epub_package(archive)
            lines = []
            roles = {e.attrib.get("refines", "").lstrip("#"): (e.text or "").strip()
                     for e in package.iter() if e.tag.endswith("meta") and e.attrib.get("property") == "role"}
            for e in package.iter():
                name = e.tag.rsplit("}", 1)[-1]
                value = " ".join("".join(e.itertext()).split())
                if name in ("title", "creator", "date", "identifier", "publisher", "language") and value:
                    if name == "creator":
                        role = e.attrib.get("{http://www.idpf.org/2007/opf}role", roles.get(e.attrib.get("id"), "aut"))
                        if role not in ("aut", "edt"):
                            continue
                        name = "Author" if role == "aut" else "Editor"
                    scheme = e.attrib.get("{http://www.idpf.org/2007/opf}scheme", "")
                    if name == "identifier" and (scheme.upper() == "ISBN" or "isbn" in value.lower() or isbn_valid(value)):
                        name, value = "ISBN (EPUB)", re.sub(r"(?i)^urn:isbn:", "", value)
                    elif name == "date":
                        name = "Publication date"
                    lines.append(f"{name}: {value}")
            out = "[EPUB_METADATA]\n" + "\n".join(lines) + "\n"
            ids = [e.attrib.get("idref") for e in package.iter() if e.tag.endswith("itemref")][:4]
            for i, item_id in enumerate(ids, 1):
                if item_id not in items:
                    continue
                path, media_type, _ = items[item_id]
                if media_type not in ("application/xhtml+xml", "text/html"):
                    continue
                raw = archive.read(path).decode("utf-8", errors="replace")
                raw = re.sub(r"(?is)<(?:script|style)\b.*?</(?:script|style)>", "", raw)
                raw = re.sub(r"(?i)</(?:p|div|h[1-6]|li|section)>|<br\s*/?>", "\n", raw)
                raw = html.unescape(re.sub(r"<[^>]+>", " ", raw))
                clean = "\n".join(" ".join(line.split()) for line in raw.splitlines() if line.strip())
                if clean:
                    out += f"[EPUB_FRONT{i}]\n" + clean[:4000] + "\n"
            return out
    except (OSError, ValueError, KeyError, StopIteration, ET.ParseError, zipfile.BadZipFile):
        return ""


def image_id(path):
    name = Path(path).stem
    m = re.fullmatch(r"page-(\d+)", name)
    return f"IMAGE_P{m[1]}" if m else "EPUB_IMAGE" + name.rsplit("-", 1)[-1]


def sources_in(packet):
    result = {}
    sid = None
    for line in packet.splitlines():
        m = re.fullmatch(r"\[([A-Z][A-Z_0-9]+)\]", line)
        if m:
            sid = m[1]
            result.setdefault(sid, [])
        elif line.startswith("==="):
            sid = None
        elif sid:
            result[sid].append(line)
    if not result and packet.strip():
        result["DOCUMENT"] = packet.splitlines()
    return {k: "\n".join(v) for k, v in result.items()}


def metadata_schema(ids):
    nullable = {"type": ["string", "null"]}
    props = {"status": {"type": "string", "enum": ["identified", "unidentified"]},
             "title": {**nullable, "description": "Publication title; preserve English/French/Spanish wording, translate other languages to English."},
             "original_title": {**nullable, "description": "Verbatim title from the evidence, including when identical to title; null only if unidentified."},
             "title_language": {"type": "string", "enum": ["en", "fr", "es", "other"]},
             "authors": {"type": "array", "items": {"type": "string"}},
             "contributor_role": {"type": "string", "enum": ["author", "editor"]},
             "edition": {**nullable, "description": "Complete edition designation, e.g. First Edition; null if absent."},
             "volume": {**nullable, "description": "Complete volume designation, e.g. Volume 1; null if absent."},
             "year": {**nullable, "description": "Four-digit publication year for the identified edition."},
             "isbn": {**nullable, "description": "ISBN digits (final X allowed for ISBN-10), or null if absent."},
             "sources": {"type": "object", "additionalProperties": False,
                         "properties": {field: {"type": "array", "items": {"type": "string", "enum": ids}} for field in FIELDS},
                         "required": list(FIELDS)}}
    return {"type": "object", "additionalProperties": False, "properties": props, "required": list(props)}


def payload(model, system, prompt, packet, images, mode="json_schema", temperature=0, max_tokens=1024, seed=None, reasoning=""):
    ids = sorted(set(sources_in(packet)) | {image_id(p) for p in images} | {"SOURCE_FILENAME"})
    schema = metadata_schema(ids)
    if mode != "text":
        prompt += "\nReturn JSON matching this schema. Null means missing; unidentified means title or contributors cannot be identified.\n" + json.dumps(schema)
    else:
        prompt += "\nReturn exactly Title - Author(s) (YYYY|NA) [ISBN|NA], or NA if title or contributors are unknown."
    content = [{"type": "text", "text": prompt}]
    for path in images:
        mime = mimetypes.guess_type(path)[0] or "image/jpeg"
        content.extend([{"type": "text", "text": f"Evidence source [{image_id(path)}]"},
                        {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{base64.b64encode(Path(path).read_bytes()).decode('ascii')}"}}])
    out = {"model": model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": content if images else prompt}],
           "temperature": temperature, "max_tokens": max_tokens}
    if mode == "json_schema":
        out["response_format"] = {"type": "json_schema", "json_schema": {"name": "publication_metadata", "strict": True, "schema": schema}}
    elif mode == "json_object":
        out["response_format"] = {"type": "json_object"}
    if seed is not None:
        out["seed"] = seed
    if reasoning:
        out["reasoning_effort"] = reasoning
    return out


def isbn_candidates(text, extension="", edition=None):
    values = []
    # Limit matches to one line, with a separate following-line number allowed.
    pattern = r"(?im)\bISBN(?:[- ]?1[03])?(?:\s*\([^\n)]*\))?[ \t]*:?[ \t]*(?:\n[ \t]*)?([\dXx][\dXx -]{8,}[\dXx])"
    for m in re.finditer(pattern, text):
        value = isbn_normalize(m[1])
        if not isbn_valid(value):
            continue
        line_start = text.rfind("\n", 0, m.start()) + 1
        line_end = text.find("\n", m.end())
        line = text[line_start:line_end if line_end >= 0 else len(text)].lower()
        digital = bool(re.search(r"epub|e-?book|electronic|digital|pdf", line))
        match_format = extension and extension in line
        score = (100 if match_format else 50 if digital and extension in ("pdf", "epub", "mobi", "chm") else 0) + (10 if len(value) == 13 else 0)
        if edition:
            nearby_editions = edition_numbers(text[max(0, line_start - 160):m.end() + 160])
            selected_edition = edition_numbers(edition)
            if nearby_editions and selected_edition:
                score += 200 if nearby_editions & selected_edition else -200
        values.append((score, value))
    return sorted(set(values), reverse=True)


def identity_evidence(packet):
    """Do not fill bibliographic fields from tail references or distant body pages."""
    if "=== FRONT MATTER ===" not in packet:
        return packet
    match = re.search(r"(?m)^Front-matter page limit: (\d+)$", packet)
    front_pages = int(match[1]) if match else 14
    relevant = sources_in(packet.split("=== END OF SAMPLED TEXT ===", 1)[0])
    return "\n".join(text for sid, text in relevant.items()
                     if sid.startswith("EPUB_") or sid.startswith("TEXT_P") and int(sid[6:]) <= front_pages)


def publication_years(text, edition=None):
    years = []
    edition_years = []
    release_years = []
    for line in text.splitlines():
        if re.search(r"(?i)copyright|©|\b(?:published|publication date|first release|edition)\b", line):
            found = re.findall(r"(?<!\d)((?:1[5-9]|20|21)\d{2})(?!\d)", line)
            years.extend(found)
            if edition and edition_numbers(line) & edition_numbers(edition):
                edition_years.extend(found)
            if re.search(r"(?i)\b(?:published|publication date|first release)\b", line):
                release_years.extend(found)
    return set(edition_years or release_years or years)


def name_supported(name, evidence):
    tokens = folded(re.sub(r"\s*\((?:Editor|Editors)\)\s*$", "", name, flags=re.I)).split()
    if not tokens:
        return False
    for line in evidence.splitlines():
        words = folded(line).split()
        if all(t in words for t in tokens):
            return True
    return folded(name) in folded(evidence)


def parse_metadata(data, packet, source_name, images, extension=""):
    required = set(metadata_schema(["DOCUMENT"])["required"])
    if not isinstance(data, dict) or set(data) != required:
        raise ValueError("JSON must contain exactly the required metadata fields")
    if data["status"] not in ("identified", "unidentified") or data["contributor_role"] not in ("author", "editor"):
        raise ValueError("invalid identification status or contributor role")
    if not isinstance(data["authors"], list) or any(not isinstance(n, str) for n in data["authors"]):
        raise ValueError("authors must be an array of names")
    if data["title_language"] not in ("en", "fr", "es", "other"):
        raise ValueError("invalid title_language")
    for field in ("title", "original_title", "edition", "volume", "year", "isbn"):
        if data[field] is not None and not isinstance(data[field], str):
            raise ValueError(f"{field} must be a string or null")
    if data["status"] == "unidentified":
        raise ValueError("publication or required contributors could not be identified; inspect other supplied pages")
    if not data["title"] or not data["authors"] or PLACEHOLDER.fullmatch(data["title"].strip()) or any(PLACEHOLDER.fullmatch(n.strip()) or not n.strip() for n in data["authors"]):
        raise ValueError("missing or placeholder title/contributors")
    sources = sources_in(packet)
    sources["SOURCE_FILENAME"] = source_name
    visual = {image_id(p) for p in images}
    refs = data["sources"]
    if not isinstance(refs, dict) or set(refs) != set(FIELDS):
        raise ValueError("sources must cite each bibliographic field")
    if data["volume"] and re.fullmatch(r"\d+|[ivxlcdm]+", data["volume"].strip(), re.I):
        data["volume"] = "Volume " + data["volume"].strip().upper()
    if data["edition"]:
        token = re.fullmatch(r"(?i)(\d{1,2}(?:st|nd|rd|th)?|" + "|".join(ORDINALS) + r")", data["edition"].strip())
        if token:
            value = token[1].lower()
            number = ORDINALS.index(value) + 1 if value in ORDINALS else int(re.match(r"\d+", value)[0])
            data["edition"] = (ORDINALS[number - 1].title() if 1 <= number <= len(ORDINALS) else value) + " Edition"
    # Identity markers embedded in a title must receive the same evidence checks
    # as separate fields; a null field must not conceal an invented volume/edition.
    for field, pattern in (("volume", VOLUME_RE), ("edition", EDITION_RE)):
        if not data[field]:
            marker = pattern.search(data["title"])
            if marker:
                data[field] = marker[0]
                refs[field] = list(refs["title"]) if isinstance(refs["title"], list) else refs["title"]
    for field in FIELDS:
        if not isinstance(refs[field], list) or any(not isinstance(ref, str) or ref not in sources and ref not in visual for ref in refs[field]):
            raise ValueError(f"{field} cites an unknown evidence source")
        present = bool(data[field])
        if present and not refs[field]:
            raise ValueError(f"{field} needs an evidence source")
        evidence = "\n".join(sources.get(ref, "") for ref in refs[field])
        has_visual = any(ref in visual for ref in refs[field])
        if field == "title":
            def base_title(value):
                return folded(VOLUME_RE.sub("", EDITION_RE.sub("", value)))
            # A redundant original_title may be omitted by a small model. Recover
            # it only when an unchanged English/French/Spanish title is in cited text.
            if data["original_title"] is None and data["title_language"] in ("en", "fr", "es") and base_title(data["title"]) in folded(evidence):
                data["original_title"] = data["title"]
            if not data["original_title"]:
                raise ValueError("original_title is missing; copy the verbatim publication title")
            original = base_title(data["original_title"])
            if not original or not has_visual and original not in folded(evidence):
                raise ValueError("original publication title is not present in cited evidence")
            if data["title_language"] in ("en", "fr", "es") and base_title(data["title"]) != original:
                raise ValueError("English/French/Spanish title must preserve the original wording")
        if field == "authors" and not has_visual and any(not name_supported(n, evidence) for n in data[field]):
            raise ValueError("contributor names are not present in cited text")
        if field == "year" and present:
            year = data[field]
            if not re.fullmatch(r"\d{4}", year):
                raise ValueError("year must be four digits or null")
            filename_year = re.search(r"\(" + re.escape(year) + r"\)\s*\[", source_name) or re.search(r"\s--\s.*\b" + re.escape(year) + r"\b", source_name)
            if not has_visual and year not in publication_years(evidence, data["edition"]) and not ("SOURCE_FILENAME" in refs[field] and filename_year):
                raise ValueError("year lacks explicit publication/copyright/edition evidence")
        if field == "isbn" and present:
            value = isbn_normalize(data[field])
            if not isbn_valid(value):
                raise ValueError("ISBN checksum or prefix is invalid; reread the number, never invent digits")
            if not has_visual and value not in isbn_normalize(evidence):
                raise ValueError("ISBN is not present in cited evidence")
            data[field] = value
        if field in ("edition", "volume") and present:
            markers = edition_numbers if field == "edition" else volume_numbers
            values = markers(data[field])
            if not values or not has_visual and not values.issubset(markers(evidence)):
                raise ValueError(f"{field} is unsupported by cited text")
    title = data["title"].strip()
    for field in ("volume", "edition"):
        markers = edition_numbers if field == "edition" else volume_numbers
        if data[field] and not markers(data[field]).issubset(markers(title)):
            title += ", " + data[field].strip()
    authors = ", ".join(n.strip() for n in data["authors"][:3])
    if len(data["authors"]) > 3:
        authors += ", et al."
    if data["contributor_role"] == "editor":
        authors += " (Editor)" if len(data["authors"]) == 1 else " (Editors)"
    # Prefer an explicitly labelled identifier for the source format, not a print ISBN.
    isbn_evidence = "\n".join(sources.get(ref, "") for ref in refs["isbn"])
    isbn_evidence += "\n" + sources.get("EPUB_METADATA", "")
    ranked = isbn_candidates(isbn_evidence, extension, data["edition"])
    isbn = data["isbn"] or "NA"
    if ranked and ranked[0][0] >= 50:
        best = [v for score, v in ranked if score == ranked[0][0]]
        if len(best) == 1:
            isbn = best[0]
    return f"{title} - {authors} ({data['year'] or 'NA'}) [{isbn}]"


def repair_candidate(candidate, evidence, extension=""):
    try:
        title, authors, year, isbn = filename_parts(candidate, partial=True)
    except ValueError:
        return candidate
    # Fill only missing fields. Consume existing terminal fields before rebuilding.
    evidence = identity_evidence(evidence)
    years = publication_years(evidence, title)
    ranked = [(score, value) for score, value in isbn_candidates(evidence, extension, title) if score >= 0]
    if year is None or year == "NA":
        year = next(iter(years)) if len(years) == 1 else "NA"
    if isbn is None or isbn == "NA":
        best = [v for score, v in ranked if score == ranked[0][0]] if ranked else []
        isbn = best[0] if len(best) == 1 else "NA"
    return f"{title} - {authors} ({year}) [{isbn}]"


def validate_evidence(candidate, packet, source_name, images):
    """Check normalized/text-mode candidates and deterministic filename fallbacks."""
    title, authors, year, isbn = validate_filename(candidate)
    text = packet + "\n" + source_name
    # Visual evidence is verified by extraction, rather than an independent OCR engine.
    if not images:
        names = re.sub(r"(?i)\s*\((?:editor|editors)\)\s*$", "", authors)
        names = re.sub(r"(?i),?\s*et al\.?$", "", names)
        if any(not name_supported(n, text) for n in re.split(r",\s*|;\s*", names)):
            raise ValueError("contributor is not supported by source text or filename")
    years = publication_years(identity_evidence(packet), title)
    filename_year = re.search(r"\(" + re.escape(year) + r"\)\s*\[", source_name)
    structured_year = " -- " in source_name and re.search(r"\b" + re.escape(year) + r"\b", source_name)
    if year != "NA" and not images and year not in years and (years or not (filename_year or structured_year)):
        raise ValueError("publication year is unsupported or conflicts with document evidence")
    if isbn != "NA" and not images and isbn not in isbn_normalize(text):
        raise ValueError("ISBN is not supported by document or source filename")


def pgm_nonwhite(path):
    raw = Path(path).read_bytes()
    pos = 0
    def token():
        nonlocal pos
        while pos < len(raw):
            if raw[pos:pos + 1] == b"#":
                end = raw.find(b"\n", pos)
                pos = len(raw) if end < 0 else end + 1
            elif raw[pos] in b" \t\r\n":
                pos += 1
            else:
                break
        start = pos
        while pos < len(raw) and raw[pos] not in b" \t\r\n#":
            pos += 1
        return raw[start:pos]
    if token() != b"P5":
        return 0
    width, height, maximum = int(token()), int(token()), int(token())
    # Consume the header separator only; a dark first pixel can itself be whitespace.
    if raw[pos:pos + 2] == b"\r\n":
        pos += 2
    else:
        pos += 1
    if maximum > 255 or maximum <= 0:
        return 0
    pixels = raw[pos:pos + width * height]
    return sum(v < maximum * 0.96 for v in pixels) / len(pixels) if pixels else 0


def rank_pages(directory, text_file, limit, minimum):
    text = Path(text_file).read_text(errors="replace") if Path(text_file).exists() else ""
    pages = text.split("\f")
    ranked = []
    for path in Path(directory).glob("scan-*.pgm"):
        number = int(path.stem.rsplit("-", 1)[-1])
        fraction = pgm_nonwhite(path)
        if fraction < minimum:
            continue
        page = pages[number - 1] if number <= len(pages) else ""
        score = (120 if re.search(r"(?i)\bisbn\b|copyright|©", page) else 0)
        score += 60 if re.search(r"(?i)\bedition\b|written by|edited by|\bauthor", page) else 0
        score += 40 if number <= 3 else 0
        # Image-only scans: spread selections to reach copyright pages, not just covers.
        ranked.append((score, number, fraction))
    if not any(score >= 60 for score, _, _ in ranked) and len(ranked) > limit and limit > 1:
        ordered = sorted(ranked, key=lambda v: v[1])
        positions = [round(i * (len(ordered) - 1) / (limit - 1)) for i in range(limit)]
        return [ordered[i][1] for i in positions]
    return sorted(number for _, number, _ in sorted(ranked, key=lambda v: (-v[0], v[1]))[:limit])


def record_metrics(path, source, candidate, outcome, elapsed, stats, images, model, mode):
    data = {"source": source, "candidate": candidate or None, "outcome": outcome,
            "total_seconds": elapsed, "image_count": images, "model": model, "response_format": mode,
            **stats}
    if candidate:
        try:
            title, authors, year, isbn = validate_filename(candidate)
            data.update(title=title, authors=authors, year=year, isbn=isbn,
                        missing_optional_fields=int(year == "NA") + int(isbn == "NA"))
        except ValueError:
            data["invalid_candidate"] = True
    with Path(path).open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(data, ensure_ascii=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("evidence", "epub", "payload", "parse", "validate", "repair", "validate-evidence", "rank-pages", "backoff", "metrics", "server-info"))
    parser.add_argument("args", nargs=argparse.REMAINDER)
    ns = parser.parse_args()
    a = ns.args
    if ns.command == "evidence":
        native = Path(a[1]).read_text(errors="replace") if a[1] and Path(a[1]).exists() else ""
        print(evidence_packet(Path(a[0]).read_text(errors="replace"), native, *map(int, a[2:])))
    elif ns.command == "epub":
        print(epub_evidence(a[0]), end="")
    elif ns.command == "validate":
        validate_filename(a[0])
    elif ns.command == "repair":
        print(repair_candidate(a[0], a[1], a[2] if len(a) > 2 else ""))
    elif ns.command == "validate-evidence":
        validate_evidence(a[0], a[1], a[2], a[3:])
    elif ns.command == "payload":
        output, model, system, prompt, packet, mode, temperature, tokens, seed, reasoning = a[:10]
        Path(output).write_text(json.dumps(payload(model, system, prompt, packet, a[10:], mode, float(temperature), int(tokens), int(seed) if seed else None, reasoning)))
    elif ns.command == "parse":
        response, packet, source, mode, extension = a[:5]
        d = json.loads(Path(response).read_text())
        choice = d.get("choices", [{}])[0]
        finish = choice.get("finish_reason")
        if finish not in ("stop", None):
            raise ValueError(f"finish_reason={finish}; output is incomplete or unavailable; increase LLM_MAX_TOKENS if length")
        content = choice.get("message", {}).get("content")
        if not isinstance(content, str) or not content.strip():
            raise ValueError("response contains no usable content")
        if mode == "text":
            if "\n" in content.strip() or "\r" in content.strip():
                raise ValueError("text mode requires exactly one filename line")
            print(content.strip())
        else:
            print(parse_metadata(json.loads(content), packet, source, a[5:], extension))
    elif ns.command == "rank-pages":
        print("\n".join(map(str, rank_pages(a[0], a[1], int(a[2]), float(a[3])))))
    elif ns.command == "backoff":
        attempt, base, cap, retry_after = a
        delay = min(float(cap), float(base) * 2 ** min(max(int(attempt) - 1, 0), 20))
        try:
            requested = float(retry_after) if retry_after.isdigit() else parsedate_to_datetime(retry_after).timestamp() - time.time()
            delay = max(delay, min(float(cap), requested))
        except (ValueError, TypeError, OverflowError):
            pass
        print(round(min(float(cap), delay + random.uniform(0, min(1.0, delay * .2))), 3))
    elif ns.command == "metrics":
        path, source, candidate, outcome, started, stats, images, model, mode = a
        record_metrics(path, source, candidate, outcome, time.time() - float(started), json.loads(stats), int(images), model, mode)
    elif ns.command == "server-info":
        # Explicit opt-in, metadata only. Never infer endpoint type from a port number.
        endpoint, model, key, output, timeout = a
        u = urllib.parse.urlsplit(endpoint)
        url = urllib.parse.urlunsplit((u.scheme, u.netloc, "/api/show", "", ""))
        request = urllib.request.Request(url, data=json.dumps({"model": model}).encode(),
                                         headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
        with urllib.request.urlopen(request, timeout=float(timeout)) as response:
            d = json.load(response)
        info = {"model": model, "details": d.get("details"), "parameters": d.get("parameters"),
                "capabilities": d.get("capabilities"), "context_limits": {k: v for k, v in d.get("model_info", {}).items() if "context_length" in k},
                "note": "Model limits are not the effective loaded context or GPU placement."}
        base = urllib.parse.urlunsplit((u.scheme, u.netloc, "", "", ""))
        for route in ("version", "tags", "ps"):
            try:
                req = urllib.request.Request(base + "/api/" + route, headers={"Authorization": "Bearer " + key})
                with urllib.request.urlopen(req, timeout=float(timeout)) as response:
                    details = json.load(response)
                if route == "version":
                    info["server_version"] = details.get("version")
                elif route == "tags":
                    info["digest"] = next((m.get("digest") for m in details.get("models", []) if m.get("name") == model or m.get("model") == model), None)
                else:
                    info["loaded_model"] = next(({k: m.get(k) for k in ("context_length", "size", "size_vram", "digest")}
                                                 for m in details.get("models", []) if m.get("name") == model or m.get("model") == model), None)
            except (OSError, ValueError):
                info[route + "_unavailable"] = True
        Path(output).write_text(json.dumps(info, indent=2) + "\n")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, IndexError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
