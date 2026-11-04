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


def test_aliases():
    # a surface (or texture, constant) alias has no generic address: not run
    t = litmus.load(DAT3M / "Nvidia" / "proxy" / "Proxy-MP-sur-tex-fenceCorrectOrder.litmus")
    try:
        to_cuda.generate87(t, "a")
        assert False
    except to_cuda.Unsupported as e:
        assert "alias" in str(e)
    # a generic alias is the same memory mapped twice: the kernel adds the distance between the mappings
    t = litmus.load(DAT3M / "Manual" / "proxy" / "Proxy-Alias-AliasFence.litmus")
    src, spec = to_cuda.generate87(t, "b")
    assert "alias 1" in spec and "unsigned long long adelta" in src and "+ adelta;" in src
    assert "fence.proxy.alias;" in src


FEAT = to_cuda.SUITE / "ptx" / "kamui" / "features"


def test_uniform_roles_and_wgmma():
    t = litmus.load(FEAT / "wgmma" / "RAW+fence.proxy.async+wgmma.fence+wait0.litmus")
    src, spec = to_cuda.generate87(t, "w")
    assert "uniform 4" in spec and "wgmma.mma_async.sync.aligned.m64n8k16.f32.f16.f16" in src
    assert "wgB[0] = 0x3c00u;" in src and "cvt.rzi.u32.f32" in src and "if (lead) {" in src
    assert "@!lp bra" in src and "bar.sync 15, 128;" in src  # the leader's store, then the whole warpgroup
    t = litmus.load(FEAT / "wgmma" / "MP+stmatrix+ldmatrix+bar.sync.litmus")
    src, spec = to_cuda.generate87(t, "m")
    assert "uniform 1 1" in spec and "%%laneid" in src and "ldmatrix.sync.aligned.m8n8.x1.shared.b16" in src
    assert "barrier.sync bid, 64;" in src  # two one-warp roles


def test_tensor_maps_and_multicast():
    t = litmus.load(FEAT / "async" / "TMA-tensor-tile+map.cta.litmus")
    src, spec = to_cuda.generate87(t, "t")
    assert "tmap " in spec and "init " in spec and "tensormap.replace.tile.global_address.global.b1024.b64" in src
    assert "cp.async.bulk.tensor.1d.shared::cluster.global.tile.mbarrier::complete_tx::bytes" in src
    assert "ld.volatile.shared::cta.u32" in src  # the map value the copy used
    # a tensor copy needs a 128-byte aligned shared address: 128-byte slots, one per instance of the CTA's warps
    assert "__shared__ __align__(128) unsigned sbuf[1 * 8 * 32];" in src and "* 8 + lslot) * 32]" in src
    # the host encodes the map; the kernel and the host init lines must not overwrite it with the test's value
    t = litmus.load(FEAT / "misc" / "CoWR+bulk-prefetch-tensor.litmus")
    src, spec = to_cuda.generate87(t, "p")
    tm = next(ln.split()[1] for ln in spec.splitlines() if ln.startswith("tmap "))
    assert f"mem[lo[{tm}]]" not in src and not any(ln.startswith(f"init {tm} ") for ln in spec.splitlines())
    assert "uniform 1" in spec  # a tensor copy is issued by one lane of a warp that runs one instance
    t = litmus.load(FEAT / "async" / "multicast+reader1.cluster.litmus")
    src, spec = to_cuda.generate87(t, "c")
    assert "dsmem 1" in spec and ".multicast::cluster" in src and "mov.b16 cm, 3;" in src
    # both destinations (and both mbarriers) at one offset in each CTA
    for n, a in (("d0", "sbuf[(0 * 256 + lslot) * 4]"), ("d1", "sbuf[(0 * 256 + lslot) * 4]"),
                 ("b0", "mbar[0 * 256 + lslot]"), ("b1", "mbar[0 * 256 + lslot]")):
        assert f"l.{n} = to_shared(&{a});" in src


def test_grids():
    t = litmus.load(FEAT / "misc" / "MP+griddep.launch.wait.litmus")
    src, spec = to_cuda.generate87(t, "g")
    assert "grid 0 0" in spec and "grid 1 1" in spec
    assert "griddepcontrol.launch_dependents;" in src and "griddepcontrol.wait;" in src


def test_barriers_are_per_cta():
    # bar.sync 1, 2 in CTA 0 and bar.sync 1, 2 in CTA 1 are two barriers, each numbered from 0 in its CTA
    t = litmus.load(to_cuda.SUITE / "ptx" / "kamui" / "idioms" / "semaphore-st-release-cumulative.litmus")
    src, spec = to_cuda.generate87(t, "s")
    assert src.count("add.u32 bid, %") == 4 and "%1, 1;" not in src


def test_existing_kernels_unchanged():
    # the committed kernels of the tests run before must not change with new harness features
    for d in sorted((to_cuda.OUT / "kamui" / "ptx87").rglob("kernel.cu"))[:40]:
        tid = "ptx/" + d.parent.relative_to(to_cuda.OUT).as_posix()
        src, spec = to_cuda.generate87(litmus.load(to_cuda.SUITE / f"{tid}.litmus"), tid)
        assert src == d.read_text() and spec == (d.parent / "spec.txt").read_text()


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
    assert "l.y = l.x + 4;" in src and "gloc 0 x" in spec and "\ngloc 1 " not in spec and ".v2.u32" in src
    src, _ = to_cuda.generate87(litmus.load(P87 / "rmw" / "cas.b128.litmus"), "c")
    assert "atom.relaxed.gpu.global.cas.b128 qd," in src


def test_mbarrier_token_and_init():
    src, _ = to_cuda.generate87(litmus.load(P87 / "mbarrier" / "MP+mbarrier-token.litmus"), "k")
    assert "mbarrier.arrive.release.cta.shared::cta.b64 sr0," in src
    assert "mbarrier.test_wait.acquire.cta.shared::cta.b64 p, [%3], sr0;" in src
    src, _ = to_cuda.generate87(litmus.load(P87 / "mbarrier-init" / "mbarrier-init+same-thread.litmus"), "i")
    assert "mbar[0 * 256 + lslot] = 0ull;" in src and "mbarrier.init.shared::cta.b64 [%1], 1;" in src
