"""Unit tests of the coverage checks, the catalog validation and the table generator, on a tiny catalog."""

import copy

import check_coverage as cc
import common
import gen_table


def row(id, kind="instruction", section="9.7.1.1 Integer Arithmetic Instructions: add", status="in-scope", **kw):
    r = {"id": id, "kind": kind, "ptx_syntax": kw.pop("ptx_syntax", ""), "manual_section": section,
         "introduced_ptx": "1.0", "min_target": "all", "family": kw.pop("family", "base"), "tier": kw.pop("tier", 1),
         "status": status, "entry": kw.pop("entry", "")}
    if status == "in-scope":
        r.update(route="cuda", tolerance_class="exact")
    else:
        r["exclusion_reason"] = "out of scope"
    r.update(kw)
    return r


SECTIONS = [
    {"number": "5.1.4", "title": "Global State Space", "introduced_ptx": "", "min_target": "", "syntax_tokens": ""},
    {"number": "9.7.1.1", "title": "Integer Arithmetic Instructions: add", "introduced_ptx": "1.0",
     "min_target": "all", "syntax_tokens": ".s32 .sat .type .u16x2"},
    {"number": "9.7.9.6", "title": "Data Movement and Conversion Instructions: shfl.sync", "introduced_ptx": "6.0",
     "min_target": "sm_30", "syntax_tokens": ".b32 .bfly .down .idx .mode .sync .up"},
    {"number": "9.7.10.3", "title": "Texture Instructions: tex", "introduced_ptx": "1.0", "min_target": "all",
     "syntax_tokens": ""},
    {"number": "9.7.13.15.1", "title": "Size and alignment of mbarrier object", "introduced_ptx": "",
     "min_target": "", "syntax_tokens": ""},
    {"number": "10.3", "title": "Special Registers: %laneid", "introduced_ptx": "1.3", "min_target": "all",
     "syntax_tokens": ""},
    {"number": "11.4.1", "title": "Performance-Tuning Directives: .maxnreg", "introduced_ptx": "1.3",
     "min_target": "all", "syntax_tokens": ""},
]

ROWS = [
    row("add", opcodes=["add"], ptx_syntax="add.type d, a, b;"),
    row("dir.maxnreg", kind="directive", section="11.4.1 Performance-Tuning Directives: .maxnreg"),
    row("shfl.sync.bfly", kind="modifier", section="9.7.9.6 Data Movement and Conversion Instructions: shfl.sync",
        opcodes=["shfl.sync.bfly"], family="Xkmwarp"),
    row("space.global", kind="state-space", section="5.1.4 Global State Space"),
    row("sreg.laneid", kind="special-register", section="10.3 Special Registers: %laneid", family="Xkmsimt"),
    row("tex", section="9.7.10.3 Texture Instructions: tex", status="excluded", opcodes=["tex"]),
]


def test_covers_prefix_rule():
    assert common.covers("shfl.sync.bfly", "shfl.sync.bfly.b32")
    assert not common.covers("shfl.sync.bfly", "shfl.sync.idx.b32")
    assert common.covers("ld.shared", "ld.shared::cta.v4.u32")
    assert common.covers("rcp.approx.ftz.f64", "rcp.approx.ftz.f64")
    assert not common.covers("ld.global.nc", "ld.global.u32")
    assert not common.covers("add", "addc.cc.u32")


def test_covering_rows_most_specific_first():
    rows = [{"id": "a", "opcodes": ["atom"]}, {"id": "b", "opcodes": ["atom.global"]},
            {"id": "c", "opcodes": ["atom.global.add"]}]
    assert [r["id"] for r in common.covering_rows("atom.global.add.u32", rows)] == ["c", "b", "a"]


def test_check_a():
    assert cc.check_manual(ROWS, SECTIONS).ok()
    res = cc.check_manual([r for r in ROWS if r["id"] != "tex"], SECTIONS)
    assert any("9.7.10.3" in e for e in res.errors)
    bad = copy.deepcopy(ROWS)
    bad[0]["manual_section"] = "9.7.1.1 Integer Arithmetic Instructions: sub"
    assert any("title differs" in e for e in cc.check_manual(bad, SECTIONS).errors)


def test_check_b_exceptions():
    ops = [{"opcode": "add.s32"}, {"opcode": "shfl.sync.bfly.b32"}, {"opcode": "tex.1d.v4.f32"},
           {"opcode": "param"}]
    res = cc.check_llvm(ROWS, ops, [])
    assert res.errors == ["param: not covered by any catalog row (add a row or an exception)"]
    assert res.info["excluded_only"] == {"tex.1d.v4.f32": "tex"}
    exc = [{"check": "llvm", "mention": "param", "reason": "artifact"}]
    assert cc.check_llvm(ROWS, ops, exc).ok()
    stale = exc + [{"check": "llvm", "mention": "gone", "reason": "old"}]
    assert any("stale exception" in e for e in cc.check_llvm(ROWS, ops, stale).errors)
    noreason = [{"check": "llvm", "mention": "param", "reason": ""}]
    assert any("no reason" in e for e in cc.check_llvm(ROWS, ops, noreason).errors)


def test_check_c():
    def note(item, mention, kind, adds="0", version="8.0"):
        return {"version": version, "item": str(item), "adds": adds, "mention": mention, "kind": kind}

    notes = [note(1, "shfl.sync", "opcode", adds="1", version="6.0"), note(1, ".bfly", "dot"),
             note(2, "%laneid", "special-register"), note(3, ".maxnreg", "dot"), note(4, "sm_90", "target"),
             note(5, "add", "opcode"), note(5, ".u16x2", "dot"), note(6, "num_samples", "opcode")]
    res = cc.check_release_notes(ROWS, notes, SECTIONS, [])
    assert res.ok(), res.errors
    assert res.info["ignored_words"] == ["num_samples"]
    res = cc.check_release_notes(ROWS, notes + [note(5, ".relu", "dot"), note(7, "%nosuch", "special-register")],
                                 SECTIONS, [])
    assert sorted(res.errors) == sorted(["%nosuch: not covered by any catalog row (add a row or an exception)",
                                         ".relu: not covered by any catalog row (add a row or an exception)"])


def test_validate():
    assert cc.check_catalog(ROWS, root=None).errors == [f"family {f} has no in-scope row" for f in common.FAMILIES
                                                        if f not in ("base", "Xkmwarp", "Xkmsimt")] + [
        f"application row {a} is missing" for a in ("app.vecadd", "app.shfl_reduce", "app.barrier", "app.atomics")]
    bad = copy.deepcopy(ROWS)
    bad[0], bad[1] = bad[1], bad[0]
    bad[-1]["exclusion_reason"] = ""
    bad[2]["tolerance_class"] = "loose"
    bad[3]["entry"] = "pending"
    errs = cc.check_catalog(bad, root=None).errors
    assert "entries are not sorted by id" in errs
    assert "tex: excluded rows need an exclusion_reason" in errs
    assert any(e.startswith("shfl.sync.bfly: tolerance_class") for e in errs)
    assert "space.global: a pending entry needs the reason in notes" in errs
    req = cc.check_catalog(ROWS, require_entries=True, root=None).errors
    assert "add: in-scope row without a corpus entry" in req


def test_table_render_and_check(tmp_path):
    rows = ROWS + [row("app.vecadd", kind="application", section="")]
    text = gen_table.render(rows)
    assert "`shfl.sync.bfly`" in text and "| 9.7.9.6 |" in text
    assert "## Excluded PTX features" in text and "| `tex` | 9.7.10.3 | out of scope |" in text
    assert gen_table.cell("d[|p]") == "d[\\|p]"
    out = tmp_path / "t.md"
    import yaml
    cat = tmp_path / "c.yaml"
    cat.write_text(yaml.safe_dump({"features": rows}))
    assert gen_table.main(["--catalog", str(cat), "--output", str(out)]) == 0
    assert gen_table.main(["--catalog", str(cat), "--output", str(out), "--check"]) == 0
    out.write_text(out.read_text() + "edit\n")
    assert gen_table.main(["--catalog", str(cat), "--output", str(out), "--check"]) == 1
