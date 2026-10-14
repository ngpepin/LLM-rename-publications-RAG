import importlib.util
import json
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("metadata", ROOT / "scripts/bibliographic_metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


def record(**overrides):
    data = dict(status="identified", title="Learn by Doing", original_title="Learn by Doing", title_language="en", authors=["Jane Smith"],
                contributor_role="author", edition=None, volume=None, year="2024",
                isbn="9780306406157", sources={field: [] for field in metadata.FIELDS})
    for field in ("title", "authors", "year", "isbn"):
        data["sources"][field] = ["TEXT_P1"]
    data.update(overrides)
    if "original_title" not in overrides:
        data["original_title"] = data["title"]
    return data


EVIDENCE = "[TEXT_P1]\nLearn by Doing\nJane Smith\nPublished 2024\nISBN: 9780306406157"


class MetadataTests(unittest.TestCase):
    def test_independent_budgets_preserve_late_metadata(self):
        text = "\n".join("Prose " + "x" * 120 for _ in range(240))
        text += "\nCopyright 2024\nISBN\n9780306406157\nJane Smith"
        packet = metadata.evidence_packet(text)
        self.assertLessEqual(len(packet), 18000)
        self.assertIn("Copyright 2024", packet)
        self.assertIn("9780306406157", packet)
        self.assertIn("Jane Smith", packet)

    def test_page_boundaries_and_front_matter_scope(self):
        text = "Book title\nFirst Edition\fCopyright 2024\nISBN: 9780306406157\fBody Third Edition"
        packet = metadata.evidence_packet(text, front_pages=2)
        self.assertIn("[TEXT_P2]", packet)
        front = packet.split("=== FRONT MATTER ===")[1].split("=== BIBLIOGRAPHIC CLUES ===")[0]
        self.assertNotIn("Third Edition", front)

    def test_volume_numbers_and_uppercase_title_words_survive_cleaning(self):
        pages = metadata.clean_pages("Civil\nLaw\nVolume\nII\nVolume\n1\n42")
        self.assertEqual(pages[0][1], ["Civil", "Law", "Volume", "II", "Volume", "1"])

    def test_isbn_checksums(self):
        for isbn in ("9780306406157", "0-306-40615-2", "080442957X", "9798341673991"):
            self.assertTrue(metadata.isbn_valid(isbn), isbn)
        for isbn in ("9780306406158", "1234567890128", "0804429571", "9788132262000"):
            self.assertFalse(metadata.isbn_valid(isbn), isbn)

    def test_pdf_isbn_formatting_and_per_identifier_labels(self):
        text = "ISBN: 978-\u200b1-\u200b032-\u200b96063-\u200b0 (hbk)\nISBN: 978-\u200b1-\u200b003-\u200b58778-\u200b1 (ebk)"
        self.assertEqual(metadata.isbn_candidates(text, "pdf")[0], (60, "9781003587781"))
        text = "ISBN 978-3-658-51115-9 ISBN 978-3-658-51116-6 (eBook)"
        self.assertEqual(metadata.isbn_candidates(text, "pdf"), [(60, "9783658511166"), (10, "9783658511159")])
        self.assertEqual(metadata.isbn_normalize("978-1-945188-55-8 (paperback)"), "9781945188558")

    def test_multiline_copyright_and_original_translation_year(self):
        text = ('Translation from the German language edition: original title\n'
                'Gerhard Speckbacher, © The editor(s) or author(s), exclusively licensed\n'
                'Wiesbaden GmbH. 2025. Published by Springer Gabler.\n'
                '© The Editor(s) and The Author(s), under exclusive license\n'
                'Wiesbaden GmbH, part of Springer Nature 2026\n')
        packet = metadata.evidence_packet(text)
        self.assertEqual(metadata.publication_years(metadata.identity_evidence(packet)), {"2026"})
        self.assertEqual(metadata.publication_years("First published 2027\nA global fellow at AI2030, Parth is a published author"), {"2027"})

    def test_copyright_and_editor_title_pages_survive_long_blurbs(self):
        text = ("Long introductory blurb " * 500 + "\f" + "More opening prose " * 100 +
                "\fThe Actual Title\nEdited by\nJane Smith\fFirst published 2027\nISBN: 9781003724889 (ebk)")
        packet = metadata.evidence_packet(text, max_chars=6000)
        opening = packet.split("=== FRONT MATTER ===")[1].split("=== BIBLIOGRAPHIC CLUES ===")[0]
        self.assertIn("The Actual Title", opening)
        self.assertIn("First published 2027", opening)

    def test_catalog_title_does_not_include_author_responsibility(self):
        packet = EVIDENCE + "\nTitle: Learn by Doing / Jane Smith."
        candidate = metadata.parse_metadata(record(original_title="Learn by Doing / Jane Smith."), packet, "source.pdf", [])
        self.assertTrue(candidate.startswith("Learn by Doing -"))

    def test_readable_image_text_discards_fabricated_edition(self):
        data = record(edition="First Edition")
        data["sources"]["edition"] = ["IMAGE_P1"]
        candidate = metadata.parse_metadata(data, EVIDENCE + "\n" + "Readable copyright page " * 10, "source.pdf", ["page-1.jpg"])
        self.assertNotIn("First Edition", candidate)
        self.assertIn("Jane Smith (2024)", candidate)

    def test_placeholder_authors_and_bad_isbn_rejected(self):
        for author in ("Author(s)", "(Author)", "Unknown"):
            with self.assertRaises(ValueError):
                metadata.validate_filename(f"Example - {author} (2024) [NA]")
        with self.assertRaises(ValueError):
            metadata.validate_filename("Example - Jane Smith (2024) [9780306406158]")
        self.assertEqual(metadata.validate_filename("Example - NA (NA) [NA]")[1:], ("NA", "NA", "NA"))
        metadata.validate_filename("NA - NA (NA) [NA]")

    def test_missing_contributors_are_accepted_without_retry(self):
        for authors in ([], ["Author(s)"], ["(Author)"], ["Unknown"], ["NA"]):
            candidate = metadata.parse_metadata(record(authors=authors), EVIDENCE, "source.pdf", [])
            self.assertEqual(candidate, "Learn by Doing - NA (2024) [9780306406157]")
            metadata.validate_evidence(candidate, EVIDENCE, "source.pdf", [])

    def test_missing_fields_recovered_from_filename(self):
        source = "Learn by Doing - A Practical Guide - Jane Smith (2024) [9780306406157].pdf"
        data = record(status="unidentified", title=None, authors=[], year=None, isbn=None,
                      sources={field: [] for field in metadata.FIELDS})
        candidate = metadata.parse_metadata(data, "", source, [])
        self.assertEqual(candidate, source[:-4])
        metadata.validate_evidence(candidate, "", source, [])

    def test_reported_legacy_author_placeholder(self):
        source = "Healing Joints and Nerves - (Author) (NA) [NA].pdf"
        data = record(status="unidentified", title=None, authors=[], year=None, isbn=None,
                      sources={field: [] for field in metadata.FIELDS})
        self.assertEqual(metadata.parse_metadata(data, "", source, []),
                         "Healing Joints and Nerves - NA (NA) [NA]")

    def test_document_fields_win_and_missing_fields_use_filename(self):
        source = "Old Title - Existing Author (2020) [080442957X].pdf"
        candidate = metadata.parse_metadata(record(authors=[], year=None, isbn=None), EVIDENCE, source, [])
        self.assertEqual(candidate, "Learn by Doing - Existing Author (2024) [9780306406157]")
        self.assertEqual(metadata.parse_metadata(record(), EVIDENCE, source, []),
                         "Learn by Doing - Jane Smith (2024) [9780306406157]")

    def test_plain_filename_separators_are_part_of_title(self):
        self.assertEqual(metadata.source_candidate("Learn by Doing - A Practical Guide.pdf"),
                         "Learn by Doing - A Practical Guide - NA (NA) [NA]")
        self.assertEqual(metadata.source_candidate("Example - Jane Smith (2024).pdf"),
                         "Example - Jane Smith (2024) [NA]")
        self.assertEqual(metadata.source_candidate("Example -- Jane Smith -- 2024 -- isbn13 9780306406157.pdf"),
                         "Example - Jane Smith (2024) [9780306406157]")

    def test_editor_recovery_and_ambiguous_document_fields(self):
        source = "Example - Jane Smith, John Doe (Editors) (2020) [080442957X].pdf"
        self.assertEqual(metadata.source_candidate(source, "Copyright 2022, 2024"),
                         "Example - Jane Smith, John Doe (Editors) (NA) [080442957X]")

    def test_supported_original_wording_replaces_rewritten_title(self):
        candidate = metadata.parse_metadata(record(title="Learning Through Practice", original_title="Learn by Doing"), EVIDENCE, "source.pdf", [])
        self.assertTrue(candidate.startswith("Learn by Doing -"))

    def test_partial_repair_consumes_existing_year(self):
        evidence = "Copyright 2025\nISBN: 9780306406157"
        self.assertEqual(metadata.repair_candidate("Example - Jane Smith (2024)", evidence),
                         "Example - Jane Smith (2024) [9780306406157]")
        with self.assertRaises(ValueError):
            metadata.validate_evidence("Example - Jane Smith (2024) [9780306406157]", evidence, "Example.pdf", [])

    def test_missing_optional_fields_filled_only_when_unambiguous(self):
        candidate = "Example - Jane Smith (NA) [NA]"
        self.assertEqual(metadata.repair_candidate(candidate, "Published 2024\nISBN: 9780306406157"),
                         "Example - Jane Smith (2024) [9780306406157]")
        self.assertIn("(NA)", metadata.repair_candidate(candidate, "Copyright 2022, 2024"))

    def test_current_edition_year_wins(self):
        text = "First Edition 2010\nCopyright 2010\nSecond Edition published 2024"
        self.assertEqual(metadata.publication_years(text, "Second Edition"), {"2024"})

    def test_structured_extraction_and_unknown_sources(self):
        candidate = metadata.parse_metadata(record(), EVIDENCE, "source.pdf", [], "pdf")
        self.assertEqual(candidate, "Learn by Doing - Jane Smith (2024) [9780306406157]")
        bad = record()
        bad["sources"]["authors"] = ["TEXT_P999"]
        with self.assertRaisesRegex(ValueError, "unknown evidence"):
            metadata.parse_metadata(bad, EVIDENCE, "source.pdf", [])

    def test_fabricated_contributors_years_and_editions_rejected(self):
        for changes in ({"authors": ["John Doe"]}, {"title": "A Fabricated Title"}):
            with self.assertRaises(ValueError):
                metadata.parse_metadata(record(**changes), EVIDENCE, "source.pdf", [])
        data = record(edition="Second Edition")
        data["sources"]["edition"] = ["TEXT_P1"]
        candidate = metadata.parse_metadata(data, EVIDENCE + "\nThird Edition", "source.pdf", [])
        self.assertNotIn("Second Edition", candidate)

    def test_invalid_model_isbn_uses_observed_number_or_na(self):
        self.assertIn("(2024)", metadata.parse_metadata(record(year="2019"), EVIDENCE, "source.pdf", []))
        self.assertTrue(metadata.parse_metadata(record(isbn="9780306406158"), EVIDENCE, "source.pdf", []).endswith("[9780306406157]"))
        packet = EVIDENCE.replace("ISBN: 9780306406157", "")
        self.assertTrue(metadata.parse_metadata(record(isbn="9780306406158"), packet, "source.pdf", []).endswith("[NA]"))
        packet = "[TEXT_P1]\nLearn by Doing\nJane Smith"
        candidate = metadata.parse_metadata(record(year="2026", isbn=None), packet, "source.pdf", [])
        self.assertTrue(candidate.endswith("(NA) [NA]"))

    def test_source_filename_credit_never_becomes_publication_title(self):
        source = "Learn by Doing - (Author(s)) (NA) [NA].pdf"
        data = record(original_title=source)
        data["sources"]["title"] = ["SOURCE_FILENAME"]
        candidate = metadata.parse_metadata(data, EVIDENCE, source, [])
        self.assertEqual(candidate, "Learn by Doing - Jane Smith (2024) [9780306406157]")

    def test_original_language_edition_is_not_translation_edition(self):
        packet = EVIDENCE + '\nTranslation from the German language edition: "Original, 2 Ed."\n© The Author(s) 2024'
        data = record(edition="2 Ed.")
        data["sources"]["edition"] = ["TEXT_P1"]
        self.assertNotIn("2 Ed", metadata.parse_metadata(data, packet, "source.pdf", []))

    def test_format_specific_isbn_beats_print_identifier(self):
        packet = EVIDENCE + "\nISBN (EPUB): 9780132350884"
        candidate = metadata.parse_metadata(record(), packet, "source.epub", [], "epub")
        self.assertTrue(candidate.endswith("[9780132350884]"))

    def test_equivalent_editions_do_not_duplicate(self):
        data = record(title="Learn by Doing, 1st Ed.", edition="First Edition")
        data["sources"]["edition"] = ["TEXT_P1"]
        candidate = metadata.parse_metadata(data, EVIDENCE + "\nFirst Edition", "source.pdf", [])
        self.assertNotIn("First Edition", candidate)

    def test_bare_volume_and_edition_are_normalized_and_grounded(self):
        data = record(volume="1", edition="first")
        for field in ("volume", "edition"):
            data["sources"][field] = ["TEXT_P1"]
        candidate = metadata.parse_metadata(data, EVIDENCE + "\nVolume 1\nFirst Edition", "source.pdf", [])
        self.assertIn(", Volume 1, First Edition -", candidate)

    def test_embedded_invented_volume_is_removed(self):
        data = record(title="Learn by Doing, Volume 99", original_title="Learn by Doing")
        candidate = metadata.parse_metadata(data, EVIDENCE, "source.pdf", [])
        self.assertNotIn("Volume 99", candidate)
        self.assertIn("Jane Smith (2024)", candidate)

    def test_original_title_recovery_requires_literal_text_support(self):
        candidate = metadata.parse_metadata(record(original_title=None), EVIDENCE, "source.pdf", [])
        self.assertTrue(candidate.startswith("Learn by Doing -"))
        with self.assertRaises(ValueError):
            metadata.parse_metadata(record(original_title=None, title="Unseen Title"), EVIDENCE, "source.pdf", [])

    def test_distant_body_isbn_does_not_fill_missing_identifier(self):
        packet = metadata.evidence_packet("Learn by Doing\nJane Smith\fBody\fISBN: 9780306406157", front_pages=2)
        result = metadata.repair_candidate("Learn by Doing - Jane Smith (NA) [NA]", packet)
        self.assertTrue(result.endswith("[NA]"))

    def test_schema_images_labelled_and_sampling_configurable(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "page-4.jpg"
            image.write_bytes(b"jpeg fixture")
            out = metadata.payload("test-model", "system", "prompt", EVIDENCE, [str(image)],
                                   temperature=.2, max_tokens=1200, seed=7, reasoning="none")
        self.assertEqual(out["response_format"]["type"], "json_schema")
        self.assertEqual(out["temperature"], .2)
        self.assertEqual(out["seed"], 7)
        self.assertEqual(out["reasoning_effort"], "none")
        self.assertIn("IMAGE_P4", json.dumps(out))
        self.assertEqual(out["messages"][1]["content"][1]["text"], "Evidence source [IMAGE_P4]")

    def test_native_epub_metadata_spine_and_contributor_roles(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "book.epub"
            with zipfile.ZipFile(path, "w") as z:
                z.writestr("META-INF/container.xml", '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
                z.writestr("OPS/book.opf", '''<package xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf"><metadata><dc:title>Learn by Doing</dc:title><dc:creator opf:role="aut">Jane Smith</dc:creator><dc:creator opf:role="trl">Translator Person</dc:creator><dc:date>2024-01-01</dc:date><dc:identifier opf:scheme="ISBN">9780306406157</dc:identifier></metadata><manifest><item id="title" href="title.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="title"/></spine></package>''')
                z.writestr("OPS/title.xhtml", '<html><body><h1>Learn by Doing</h1><p>First Edition</p><script>ignore me</script></body></html>')
            text = metadata.epub_evidence(path)
        self.assertIn("Author: Jane Smith", text)
        self.assertNotIn("Translator Person", text)
        self.assertIn("ISBN (EPUB): 9780306406157", text)
        self.assertIn("[EPUB_FRONT1]", text)
        self.assertNotIn("ignore me", text)

    def test_page_ranking_and_image_only_spread(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for page in range(1, 9):
                (root / f"scan-{page:02}.pgm").write_bytes(b"P5\n2 2\n255\n" + bytes([30] * 4))
            text = root / "text.txt"
            text.write_text("Cover\fTitle page\fContents\fContents\fCopyright 2024 ISBN 9780306406157\fBody\fBody\fBody")
            selected = metadata.rank_pages(root, text, 3, .001)
            self.assertIn(5, selected)
            text.write_text("")
            self.assertEqual(metadata.rank_pages(root, text, 3, .001), [1, 5, 8])


class BashNormalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = (ROOT / "rename-using-llm.sh").read_text()
        # Extract complete shell functions without mistaking Python dictionary braces
        # inside heredocs for the end of the function.
        starts = list(__import__("re").finditer(r"(?m)^([a-z_]+)\(\) \{", script))
        cls.functions = {}
        for i, start in enumerate(starts):
            end = starts[i + 1].start() if i + 1 < len(starts) else len(script)
            region = script[start.start():end]
            close = region.rfind("\n}\n")
            if close >= 0:
                cls.functions[start[1]] = region[:close + 3]

    def run_functions(self, names, expression, *args):
        import shlex
        prelude = f"SCRIPT_DIR={shlex.quote(str(ROOT))}\nMETADATA_HELPER={shlex.quote(str(ROOT / 'scripts/bibliographic_metadata.py'))}\nCANONICAL_TITLE_TERMS_FILE={shlex.quote(str(ROOT / 'canonical-title-terms.txt'))}\n"
        code = prelude + "\n".join(self.functions[n] for n in names) + "\n" + expression
        return subprocess.run(["bash", "-c", code, "test", *args], text=True, capture_output=True)

    def test_terminal_by_and_legitimate_title_by(self):
        credit = "Skills for AI Agents, Volume 1 - First Edition (...) by Lucas B. Nicolosi Soares (2027) [9798341673991]"
        out = self.run_functions(["clean_file_name"], 'clean_file_name "$1"', credit)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), credit.replace(" by Lucas", " - Lucas"))
        title = "Learn by Doing - Jane Smith (2024) [NA]"
        self.assertEqual(self.run_functions(["clean_file_name"], 'clean_file_name "$1"', title).stdout.strip(), title)

    def test_strict_by_rejected_final_separator_preserved(self):
        invalid = "Skills - First Edition by Jane Smith (2024) [NA]"
        self.assertNotEqual(self.run_functions(["strict_response_format"], 'strict_response_format "$1"', invalid).returncode, 0)
        valid = "Learn by Doing - A Practical Guide - Jane Smith (2024) [NA]"
        self.assertEqual(self.run_functions(["strict_response_format"], 'strict_response_format "$1"', valid).returncode, 0)
        out = self.run_functions(["ensure_source_volume"], 'ensure_source_volume "$1" "$2"', valid, "Learn by Doing Volume 2.pdf")
        self.assertIn("A Practical Guide, Volume 2 - Jane Smith", out.stdout)

    def test_subtitle_title_case_and_na_author(self):
        candidate = "Deep Learning : a Visual Approach - NA (NA) [NA]"
        out = self.run_functions(["enforce_title_case_candidate"], 'enforce_title_case_candidate "$1"', candidate)
        self.assertEqual(out.stdout.strip(), "Deep Learning: A Visual Approach - NA (NA) [NA]")

    def test_generated_filename_is_limited_to_200_characters(self):
        title = "A Comprehensive and Extremely Detailed Guide to " + ("Distributed Systems Engineering " * 8)
        filename = f"{title} - Jane Smith and John Example (2024) [9780306406157].pdf"
        out = self.run_functions(["limit_generated_filename"], 'limit_generated_filename "$1" 200', filename)
        self.assertEqual(out.returncode, 0, out.stderr)
        limited = out.stdout.strip()
        self.assertLessEqual(len(limited), 200)
        self.assertTrue(limited.endswith(" - Jane Smith and John Example (2024) [9780306406157].pdf"))

        collision = filename[:-4] + "_123.pdf"
        out = self.run_functions(["limit_generated_filename"], 'limit_generated_filename "$1" 200', collision)
        self.assertEqual(out.returncode, 0, out.stderr)
        limited_collision = out.stdout.strip()
        self.assertLessEqual(len(limited_collision), 200)
        self.assertTrue(limited_collision.endswith(" (2024) [9780306406157]_123.pdf"))

    def test_edition_not_duplicated_or_overridden_by_body(self):
        candidate = "A Book - A Guide, First Edition - Jane Smith (2024) [NA]"
        evidence = "=== FRONT MATTER ===\n[TEXT_P1]\nFirst Edition\n=== BIBLIOGRAPHIC CLUES ===\n[TEXT_P40]\nThird Edition"
        out = self.run_functions(["ensure_edition"], 'ensure_edition "$1" "$2" "$3"', candidate, "A Book First Edition.pdf", evidence)
        self.assertEqual(out.stdout.strip(), candidate)
        duplicate = "A Book, First Edition - First Edition - Jane Smith (2024) [NA]"
        out = self.run_functions(["ensure_edition"], 'ensure_edition "$1" "$2" "$3"', duplicate, "First Edition.pdf", "First Edition")
        self.assertEqual(out.stdout.count("First Edition"), 1)


if __name__ == "__main__":
    unittest.main()
