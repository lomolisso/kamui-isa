"""Checks on the committed catalog, snapshots and table. The snapshot test needs the downloaded sources
(tools/catalog/fetch_sources.sh) and is skipped without them, for example in CI."""

import pytest

import check_coverage as cc
import common
import gen_table
import llvm_opcodes
import stats
import release_notes
import toc


def test_committed_catalog_passes_every_check():
    rows = common.load_catalog()
    sections = common.read_tsv(common.SNAPSHOTS / "sections.tsv")
    exc = common.load_exceptions()
    results = [cc.check_catalog(rows), cc.check_manual(rows, sections),
               cc.check_llvm(rows, common.read_tsv(common.SNAPSHOTS / "llvm-opcodes.tsv"), exc),
               cc.check_release_notes(rows, common.read_tsv(common.SNAPSHOTS / "release-notes.tsv"), sections, exc)]
    for r in results:
        assert r.ok(), (r.name, r.errors)


def test_every_in_scope_row_has_an_entry():
    r = cc.check_catalog(common.load_catalog(), require_entries=True)
    assert r.ok(), r.errors


def test_stats_print(capsys):
    assert stats.main([]) == 0
    text = capsys.readouterr().out
    assert "### Rows per family and tier" in text and "| total | 208 |" in text


def test_table_is_up_to_date():
    assert common.TABLE.read_text(encoding="utf-8") == gen_table.render(common.load_catalog())


@pytest.mark.skipif(not common.manual_html().exists(), reason="sources not downloaded")
def test_snapshots_reproduce_from_sources(tmp_path):
    html = common.manual_html().read_text(encoding="utf-8")
    toc_out = tmp_path / "sections.tsv"
    common.write_tsv(toc_out, toc.parse(html), toc.FIELDS)
    assert toc_out.read_text() == (common.SNAPSHOTS / "sections.tsv").read_text()
    rn_out = tmp_path / "release-notes.tsv"
    common.write_tsv(rn_out, release_notes.parse(html), release_notes.FIELDS)
    assert rn_out.read_text() == (common.SNAPSHOTS / "release-notes.tsv").read_text()
    if common.llvm_dir().exists() and llvm_opcodes.HEADERS.exists():
        out = tmp_path / "llvm-opcodes.tsv"
        assert llvm_opcodes.main(["--records", str(tmp_path / "records.txt"), "-o", str(out)]) == 0
        assert out.read_text() == (common.SNAPSHOTS / "llvm-opcodes.tsv").read_text()
