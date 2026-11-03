import json

import litmus
import observed
import run_h100
import to_cuda

HAND = to_cuda.SUITE / "ptx" / "kamui" / "hand"
FAM = to_cuda.SUITE / "ptx" / "kamui" / "families"


def test_mbarrier_kernel():
    t = litmus.load(HAND / "MP+mbarrier-rel-acq.cta+same-cta.litmus")
    src, spec = to_cuda.generate(t, "ptx/kamui/hand/MP+mbarrier-rel-acq.cta+same-cta")
    assert "placement same-cta" in spec and "reg 0 P1:r0" in spec and "gloc 0 x" in spec
    assert "mbarrier.arrive.release.cta.shared::cta.b64 _, [%1];" in src
    assert "mbarrier.test_wait.parity.acquire.cta.shared::cta.b64 p, [%3], 0;" in src
    assert "mbarrier.init.shared::cta.b64" in src and "__syncthreads();" in src


def test_family_kernel_and_placement():
    t = litmus.load(FAM / "IRIW" / "IRIW+fence-sc.gpu+diff-cluster.litmus")
    src, spec = to_cuda.generate(t, "x")
    assert "placement diff-cluster" in spec and "roles 4" in spec and "nregs 4" in spec
    assert "fence.sc.gpu;" in src and "ld.relaxed.gpu.global.u32 %0, [%2];" in src
    t = litmus.load(FAM / "MP" / "MP+rel-acq.cluster+same-cluster.litmus")
    assert to_cuda.placement(t) == "same-cluster"
    _, spec = to_cuda.generate(litmus.load(HAND / "MP+barrier.cluster+same-cluster.litmus"), "y")
    assert "cluster_barrier 1" in spec


def test_bulk_copy_kernel():
    src, spec = to_cuda.generate(litmus.load(HAND / "CoWR+fence.proxy.async+async-bulk+same-cta.litmus"), "z")
    assert "cp.async.bulk.global.shared::cta.bulk_group [%2], [%1], 16;" in src
    assert "fence.proxy.async.shared::cta;" in src and "gloc 0 g" in spec


def test_evaluate():
    c = litmus.parse_condition("P1:r0 == 1 /\\ ~(1:r1 == 2) \\/ x != 0")
    assert litmus.evaluate(c, {"P1:r0": 1, "P1:r1": 0, "x": 0})
    assert not litmus.evaluate(c, {"P1:r0": 0, "P1:r1": 0, "x": 0})


def test_seed_is_stable():
    assert run_h100.seed_of("a", "plain") == run_h100.seed_of("a", "plain") != run_h100.seed_of("a", "stress")


def test_observed_build(tmp_path, monkeypatch):
    tid = "kamui/families/MP/MP+rel-acq.gpu+same-cluster"
    d = tmp_path / tid
    d.mkdir(parents=True)
    (d / "plain.json").write_text(json.dumps({"instances": 10, "histogram": [
        {"values": [1, 0], "class": "same-cluster", "count": 2},
        {"values": [1, 1], "class": "same-cluster", "count": 8}]}))
    monkeypatch.setattr(observed, "verdicts", lambda: {f"ptx/{tid}": "forbidden"})
    obs, summ = observed.build(tmp_path)
    assert "P1:r0=1 P1:r1=0,2,10,yes,forbidden" in obs
    bad = observed.forbidden_observed(summ)
    assert len(bad) == 1 and bad[0]["weak"] == "2" and bad[0]["rate"] == "0.2"


def test_complete(tmp_path):
    f = tmp_path / "r.json"
    assert not run_h100.complete(f, 10)
    f.write_text('{"instances": 12}')
    assert run_h100.complete(f, 10) and not run_h100.complete(f, 20)
    f.write_text('{"instances": 1')
    assert not run_h100.complete(f, 10)


DAT3M = to_cuda.SUITE / "ptx" / "imported" / "dat3m"


def test_imported_mixed_placement_and_register_store():
    t = litmus.load(DAT3M / "Memalloy" / "IRIW1.litmus")
    src, spec = to_cuda.generate87(t, "ptx/imported/dat3m/Memalloy/IRIW1")
    assert "placement mixed" in spec and "group 0 0" in spec and "group 1 1" in spec and "group 3 1" in spec
    assert "mov.u32 %0, 1;" in src and "st.weak.global.u32 [%1], t;" in src


def test_imported_barriers():
    try:
        to_cuda.generate87(litmus.load(DAT3M / "Barrier" / "quorum1-pass.litmus"), "q")
        assert False, "a quorum of 2 with 3 arriving threads cannot complete on the GPU"
    except to_cuda.Unsupported:
        pass
    src, spec = to_cuda.generate87(litmus.load(DAT3M / "Manual" / "SB+named-bar-reg-diff.litmus"), "r")
    assert "warp_barrier 1" in spec
    assert "mov.u32 qr2, 1;" in src and "barrier.sync bid, 32;" in src and "l.gb = 1 + (lslot >> 5) * 2;" in src


def test_aliases_are_not_run():
    t = litmus.load(next((DAT3M / "Nvidia" / "proxy").glob("*.litmus")))
    try:
        to_cuda.generate87(t, "a")
        assert False
    except to_cuda.Unsupported as e:
        assert "alias" in str(e)


def test_barrier_deadlock_is_not_run():
    try:
        to_cuda.generate87(litmus.load(DAT3M / "Manual" / "PC-bar-sync-sync-3.litmus"), "d")
        assert False
    except to_cuda.Unsupported as e:
        assert "deadlock" in str(e)


def test_distributed_shared_memory_kernel():
    tid = "ptx/kamui/ptx87/spaces/MP+rel-acq.cta+remote-shared"
    src, spec = to_cuda.generate87(litmus.load(to_cuda.SUITE / (tid + ".litmus")), tid)
    assert "dsmem 1" in spec and "placement same-cluster" in spec
    assert 'mapa.shared::cluster.u32 %0, %1, 1;' in src and "st.weak.shared::cluster.u32 [%2], t;" in src
    assert "ld.weak.shared::cta.u32 %1, [%2];" in src and src.count("barrier.cluster.arrive;") == 3


P87 = to_cuda.SUITE / "ptx" / "kamui" / "ptx87"


def test_granules_vectors_and_wide_cas():
    src, spec = to_cuda.generate87(litmus.load(P87 / "sizes" / "tearing+relaxed.litmus"), "t")
    assert "reg 0 P1:r0[0]" in spec and "reg 1 P1:r0[1]" in spec and "mov.u32 t, 65537;" in src
    assert "out[0] = r_r0 & 0xffffu;" in src and "out[1] = r_r0 >> 16;" in src
    src, _ = to_cuda.generate87(litmus.load(P87 / "sizes" / "mixed-size+flag.litmus"), "m")
    assert "ld.weak.global.u16 %1, [%2+2];" in src
    src, spec = to_cuda.generate87(litmus.load(P87 / "sizes" / "MP+vector-release.litmus"), "v")
    assert "l.y = l.x + 4;" in src and "gloc 0 x" in spec and "gloc 1" not in spec and ".v2.u32" in src
    src, _ = to_cuda.generate87(litmus.load(P87 / "rmw" / "cas.b128.litmus"), "c")
    assert "atom.relaxed.gpu.global.cas.b128 qd," in src


def test_mbarrier_token_and_init():
    src, _ = to_cuda.generate87(litmus.load(P87 / "mbarrier" / "MP+mbarrier-token.litmus"), "k")
    assert "mbarrier.arrive.release.cta.shared::cta.b64 sr0," in src
    assert "mbarrier.test_wait.acquire.cta.shared::cta.b64 p, [%3], sr0;" in src
    src, _ = to_cuda.generate87(litmus.load(P87 / "mbarrier-init" / "mbarrier-init+same-thread.litmus"), "i")
    assert "mbar[0 * 256 + lslot] = 0ull;" in src and "mbarrier.init.shared::cta.b64 [%1], 1;" in src
