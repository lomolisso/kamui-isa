#!/usr/bin/env python3
"""Check by bounded model finding that proxy fences and alias fences restore the behaviour of the generic proxy.

The mixed-proxy model's promise (Lustig, Cooksey and Giroux, ISCA 2022, and 8.6 of the manual): a program that
switches proxies only through the right proxy fences behaves like the same program with every operation in the
generic proxy, and a program that uses virtual aliases only with alias fences behaves like the same program with
one address. This tool writes a module that holds every `fun` and `pred` of ptx87.als again, once with every
memory operation read as generic (suffix _g) and once with every virtual address read as its physical location
(suffix _a), and checks on executions of the shape of a translated litmus test (`emitted`, from mutant_equiv.py):

- `proxies_N`: texture, surface and constant operations (no async units), every change of proxy in a thread
  crossed by proxy fences (from the first proxy to generic, then from generic to the second): every execution
  ptx87 accepts, the generic version accepts too. So the fenced program is never weaker than its generic version.
- `proxies_N` counts a fence or barrier as generic (D1): a surface store followed by fence.sc needs a proxy
  fence in between.
- `aliases_N`: generic operations; in each thread, an access to a location that has aliases and any other event
  using a different address (or none) are separated by an alias fence; the different virtual addresses of one
  location are used by one thread. The same, against the version with physical addresses.
  `aliases_any_thread_N` drops the last condition: it fails, because operations on different virtual addresses
  are never morally strong (8.6), so no fence restores coherence or RMW atomicity between threads that use
  different aliases.
- `sanity_*`: the fragments are not empty, and without the fences the property fails (so the fences matter).

    python3 tools/litmus/fence_props.py                 # bounds 4 and 5, in the dev container (image 0.4)
    python3 tools/litmus/fence_props.py --bounds 4

Writes build/ptx87-props/fences.als and prints one line per command (models/ptx87/equiv/check.sh: kissat,
counterexamples kept in build/ptx87-equiv/cex/fences/).
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mutant_equiv as me  # noqa: E402

OUT = me.ROOT / "build" / "ptx87-props"

FRAGMENTS = """\
// physical location of an address: its target if it is a virtual alias, itself otherwise
fun phys : Address->Address { alias + (Address - alias.Address) <: iden }

// texture, surface and constant operations of ordinary threads; plain proxy fences without state-space limits
pred frag_p {
  no AsyncUnit and no Marker and no MbarEv and no alias and no AliasFence
  ProxyFence in PlainProxyFence and no pspace and no paddr
  MemoryEvent.proxy in Generic + Texture + Surface + Constant
}
// where an event leaves its proxy (itself if generic, else a later proxy fence to generic), and where an event
// enters its proxy (itself if generic, else an earlier proxy fence from generic); fences and barriers are generic
fun leave[a: Event] : set Event {
  a.proxy_of = Generic => a else { f: PlainProxyFence | a->f in ^po and a.proxy_of->Generic in f.dirs }
}
fun enter[b: Event] : set Event {
  b.proxy_of = Generic => b else { f: PlainProxyFence | f->b in ^po and Generic->b.proxy_of in f.dirs }
}
pred fenced_p {
  all a, b: Event - ProxyFence | a->b in ^po and a.proxy_of != b.proxy_of =>
    some x: leave[a], y: enter[b] | x->y in *po
}

// generic operations and alias fences only
pred frag_a {
  no AsyncUnit and no Marker and no MbarEv and no ProxyFence
  MemoryEvent.proxy in Generic
}
// the addresses of locations that have aliases, and the address an event uses if it is one of them
fun Aliased : set Address { alias.Address + Address.alias }
fun view[e: Event] : set Address { e in MemoryEvent => e.address & Aliased else none }
pred fenced_a {
  all a, b: Event - AliasFence | a->b in ^po and view[a] != view[b] => some f: AliasFence | a->f in ^po and f->b in ^po
}
// the different virtual addresses of one location are used by one thread
pred one_thread_a {
  all a, b: MemoryEvent | a.address != b.address and a.address.phys = b.address.phys => a.thd = b.thd
}
"""


def module(bounds):
    text = me.MODEL.read_text()
    d = me.defs(text)
    names = {n for n, _ in d}
    pat = re.compile(r"\b(" + "|".join(sorted(names, key=len, reverse=True)) + r")\b")
    gen = [re.sub(r"\bproxy\b", "(proxy ++ MemoryEvent->Generic)", pat.sub(lambda x: x.group(1) + "_g", t))
           for _, t in d]
    phy = [re.sub(r"\baddress\b", "(address.phys)", pat.sub(lambda x: x.group(1) + "_a", t)) for _, t in d]
    scope5 = me.SCOPES[5]
    out = ["// ptx87.als with every memory operation read as generic (_g) and every address read as its physical",
           "// location (_a); fence_props.py checks that fences restore the generic behaviour.",
           "module fences", "open ptx87", "", me.SHAPE, FRAGMENTS] + gen + [""] + phy + ["",
           f"sanity_proxies: run {{ emitted and frag_p and fenced_p and ptx_mm and some proxy.Surface and "
           f"some PlainProxyFence and some rf & thd.~thd }} {scope5}",
           f"sanity_proxies_unfenced: run {{ emitted and frag_p and ptx_mm and not ptx_mm_g }} {scope5}",
           f"sanity_aliases: run {{ emitted and frag_a and fenced_a and ptx_mm and some alias and some AliasFence "
           f"and some rf & thd.~thd and one_thread_a }} {scope5}",
           f"sanity_aliases_unfenced: run {{ emitted and frag_a and ptx_mm and not ptx_mm_a }} {scope5}"]
    for b in bounds:
        out.append(f"proxies_{b}: check {{ (emitted and frag_p and fenced_p and ptx_mm) => ptx_mm_g }} "
                   f"{me.SCOPES[b]}")
        out.append(f"aliases_{b}: check {{ (emitted and frag_a and fenced_a and one_thread_a and ptx_mm) => "
                   f"ptx_mm_a }} {me.SCOPES[b]}")
        out.append(f"aliases_any_thread_{b}: check {{ (emitted and frag_a and fenced_a and ptx_mm) => ptx_mm_a }} "
                   f"{me.SCOPES[b]}")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--bounds", default="4,5")
    ap.add_argument("--limit", default="3600")
    ap.add_argument("--jobs", default="8")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "fences.als"
    path.write_text(module([int(b) for b in a.bounds.split(",")]))
    env = dict(os.environ, LIMIT=a.limit, JOBS=a.jobs)
    r = subprocess.run([str(me.EQUIV / "check.sh"), str(path)], capture_output=True, text=True, env=env)
    print(r.stdout, end="")
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
