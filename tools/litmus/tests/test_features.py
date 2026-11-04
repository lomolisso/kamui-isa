import features
import gen_features
import mutate
import scorecard


def test_matcher():
    f = {x.id: x for x in features.features(["ptx/kamui/features/rmw/LU+add.cluster+dsmem-remote-reader",
                                             "ptx/kamui/features/ldst/MP+rel-acq.gpu+global+diff-cluster"])}
    assert f["atom.scope.cluster"].tests == ["ptx/kamui/features/rmw/LU+add.cluster+dsmem-remote-reader"]
    assert "shared::cluster-remote" in f["atom.scope.cluster"].spaces
    assert f["ld.sem.acquire"].tests == ["ptx/kamui/features/ldst/MP+rel-acq.gpu+global+diff-cluster"]
    assert f["ld.sem.acquire"].placements == {"diff-cluster"}
    assert f["cvt.fp"].exempt  # a register operation: no litmus form


def test_bar():
    fs, rows, misses = scorecard.build()
    assert all(not m for m in misses.values()), {k: v for k, v in misses.items() if v}


def test_generators_and_mutants_are_current():
    files = gen_features.generate()
    assert all(p.exists() and p.read_text() == s for p, s in files.items())
    assert not mutate.check(mutate.load())
