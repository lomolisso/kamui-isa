"""Unit tests of the three source parsers, on small hand-written inputs."""

from pathlib import Path

import llvm_opcodes
import release_notes
import toc

MANUAL = """
<section id="instructions">
<h2><span class="section-number">9.7. </span><a>Instructions</a><a class="headerlink"></a></h2>
<section id="shfl-sync">
<h4><span class="section-number">9.7.9.6. </span><a>Data Movement and Conversion Instructions: shfl.sync</a></h4>
<p><strong>Syntax</strong></p>
<pre>shfl.sync.mode.b32  d[|p], a, b, c, membermask;

.mode = { .up, .down, .bfly, .idx };</pre>
<p><strong>Description</strong></p>
<pre>not.syntax .ignored</pre>
<p><strong>PTX ISA Notes</strong></p>
<ul><li><p>Introduced in PTX ISA version 6.0.</p></li></ul>
<p><strong>Target ISA Notes</strong></p>
<ul><li><p>Requires <code>sm_30</code> or higher.</p></li></ul>
<p><strong>Examples</strong></p>
</section>
<section id="add">
<h4><span class="section-number">9.7.1.1. </span><a>Integer Arithmetic Instructions: add</a></h4>
<p><strong>PTX ISA Notes</strong></p>
<ul><li><p>Introduced in PTX ISA version 1.0.</p></li>
<li><p>add.u16x2 introduced in PTX ISA version 8.0.</p></li></ul>
<p><strong>Target ISA Notes</strong></p>
<ul><li><p>Supported on all target architectures.</p></li><li><p>add.u16x2 requires sm_90.</p></li></ul>
</section>
</section>
<section id="release-notes">
<h1><span class="section-number">12. </span><a>Release Notes</a></h1>
<section id="changes-in-ptx-isa-version-8-0">
<h2><span class="section-number">12.8. </span><a>Changes in PTX ISA Version 8.0</a></h2>
<ul>
<li><p>Adds support for <code><span class="pre">elect.sync</span></code> instruction.</p></li>
<li><p>Extends <code><span class="pre">cvt</span></code> with <code><span class="pre">{.e4m3x2,</span> <span class="pre">.e5m2x2}</span></code>
for <code><span class="pre">sm_89</span></code> and <code><span class="pre">%clusterid</span></code>, value
<code><span class="pre">0b0101</span></code> of operand <code><span class="pre">e</span></code>.</p></li>
</ul>
</section>
</section>
<section id="descriptions-of-pragma-strings"><ul><li><code><span class="pre">nounroll</span></code></li></ul></section>
"""


def test_toc_sections_and_notes():
    rows = {r["number"]: r for r in toc.parse(MANUAL)}
    assert rows["9.7"]["title"] == "Instructions"  # permalink icon stripped
    s = rows["9.7.9.6"]
    assert s["anchor"] == "shfl-sync"
    assert s["introduced_ptx"] == "6.0" and s["min_target"] == "sm_30"
    assert s["syntax_tokens"].split() == [".b32", ".bfly", ".down", ".idx", ".mode", ".sync", ".up"]
    assert toc.first_syntax_line(s) == "shfl.sync.mode.b32 d[|p], a, b, c, membermask;"
    a = rows["9.7.1.1"]
    assert a["introduced_ptx"] == "1.0" and a["min_target"] == "all"


def test_release_notes_mentions():
    rows = release_notes.parse(MANUAL)
    got = [(r["version"], r["item"], r["adds"], r["mention"], r["kind"]) for r in rows]
    assert ("8.0", 1, 1, "elect.sync", "opcode") in got
    kinds = {r["mention"]: r["kind"] for r in rows}
    assert kinds["cvt"] == "opcode"
    assert kinds[".e4m3x2"] == "dot" and kinds[".e5m2x2"] == "dot"
    assert kinds["sm_89"] == "target" and kinds["%clusterid"] == "special-register"
    assert kinds["0b0101"] == "other" and kinds["e"] == "other"
    assert "nounroll" not in kinds  # chapter 14 is not release notes


def test_statements():
    s = llvm_opcodes.statements
    assert s("shfl.sync.bfly.b32 \\t$dst, $src, $b, $c, $mask;") == ["shfl.sync.bfly.b32"]
    assert s("ld${sem:sem}${scope:scope}.${addsp:addsp}.u32 \\t$d, [$a];") == ["ld.u32"]
    assert s("{{ .reg .pred p; setp.ne.s32 p, $a, 0; @p bra.uni $L; }}") == ["setp.ne.s32", "bra.uni"]
    assert s("// comment") == []


def test_records_and_headers(tmp_path: Path):
    records = """
------------- Classes -----------------
class Instruction {
}
------------- Defs -----------------
def ADDi32rr {	// Instruction NVPTXInst
  string AsmString = "add.s32 \\t$dst, $a, $b;";
}
def ADDi32ri {	// Instruction NVPTXInst
  string AsmString = "add.s32 \\t$dst, $a, $b;";
}
def NotAnInstruction {	// SDNode
  string AsmString = "mul.lo.s32 $d;";
}
def PSEUDO {	// Instruction
  string AsmString = "";
}
"""
    found = llvm_opcodes.from_records(records)
    assert dict(found) == {"add.s32": ["ADDi32rr", "ADDi32ri"]}
    h = tmp_path / "__clang_cuda_test.h"
    h.write_text('__DEVICE__ void f() { __asm__ __volatile__("trap;"); }\n'
                 'int g(int a) { int r; asm("vadd2.u32.u32.u32 %0,%1,%2,%3;" : "=r"(r)); return r; }\n')
    hf = llvm_opcodes.from_headers([h])
    assert sorted(hf) == ["trap", "vadd2.u32.u32.u32"]
