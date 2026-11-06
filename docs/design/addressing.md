# Addressing: windows, generic pointers and space-specific accesses

Decided 2026-11-05.

## Question

PTX has state spaces (`.global`, `.shared::cta`, `.shared::cluster`, `.local`, `.const`, `.param`) and generic
pointers that can point into the first four. `cvta` converts between a space address and a generic one,
`isspacep` tests which space a generic address is in, and `mapa` gives the address of the same shared variable in
another CTA of the cluster. Where do the spaces sit in Kamui's address space, and does Kamui have loads and
stores for a specific space as well as generic ones?

## Decision

Kamui copies the H100: one flat 64-bit address space with **windows**, plus **space-specific instructions** for
every space, from tier 1 on.

**Address layout** (as measured on the H100, probe `addr-windows`, `evidence/probes/README.md`):

| Region | Layout |
|---|---|
| Shared window of a CTA | 16 MB, aligned to 16 MB; the first 1 KB is reserved (`%reserved_smem_offset_*`), static shared memory starts at offset `0x400` |
| Cluster window | 4 GB, aligned to 4 GB; holds the shared windows of all CTAs of the cluster; a CTA's rank in the cluster is the address field just above its 16 MB window (bits 24 and up) |
| Local window | 16 MB; every thread sees its own local data at the same generic address (the hardware adds the thread's slot), so stack addresses are the same in every lane |
| Global | every other address, including host memory mapped into the GPU's address space |

The window bases are chosen by the platform per process (they change with every process on the H100) and are
readable by the program.

**Instructions**, one Kamui form per H100 form (Kamui names provisional):

| Space | H100 | Kamui | Address operand |
|---|---|---|---|
| global | `LDG`, `STG`, `ATOMG`, `RED` | `kldg`, `kstg`, `katomg`, `kred` | 64-bit register pair plus offset |
| shared (CTA and cluster window offsets) | `LDS`, `STS`, `ATOMS` | `klds`, `ksts`, `katoms` | one 32-bit register plus offset |
| local | `LDL`, `STL` | `kldl`, `kstl` | one 32-bit register plus offset |
| generic | `LD`, `ST`, `ATOM` | `kld`, `kst`, `katom` | 64-bit register pair plus offset |

All of them carry the scope and ordering fields of [scope-encoding.md](scope-encoding.md) where PTX has them.

- `cvta` is an add or a subtract of the window base (one integer instruction).
- `isspacep` is one instruction (the H100 has `QSPC`), or a compare of the high address bits.
- `mapa` replaces the rank field of a shared address; `getctarank` extracts it.

## Why

- On the H100, `cvta` is an add and a mask, the CTA rank is an address field (`mapa` is integer arithmetic), and
  `isspacep.global` is true for every address outside the windows (probe `addr-windows`, `evidence/sass-observations.csv`
  rows `cvta`, `isspacep`, `mapa`, `getctarank`).
- Compilers use space-specific shared accesses almost everywhere: `LDS`/`STS`/`LDSM`/`ATOMS` reach 10.1% of
  executed instructions (flash-attn 2 backward), while generic accesses stay at or below 0.3% in all but one
  workload (job q231). A 32-bit shared offset fits one register and needs no window check in hardware.
- Copying the H100's layout and instructions makes every PTX address operation a single Kamui instruction or a
  short integer sequence, with the H100 as the reference for what each one returns.

## Consequences

- More memory instructions to specify and test in tier 1 (four spaces instead of one); the 64-bit encoding has
  room for them.
- Scopes wider than a space degrade as PTX says (a shared access never needs `.gpu` or `.sys`).
- Window bases and the CTA slot are the same in every lane of a warp, so they are uniform values
  ([uniform-datapath.md](uniform-datapath.md)).
