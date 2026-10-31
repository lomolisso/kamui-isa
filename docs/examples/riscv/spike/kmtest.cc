// Toy Spike extension "kmtest" (enabled with --isa=..._xkmtest).
// kmt.add1 rd, rs1, rs2 : rd = rs1 + rs2 + 1        (custom-0, funct3 0, funct7 0)
// kmt.mix  rd, rs1, rs2 : rd = rs1 ^ (rs2 << 1)     (custom-0, funct3 0, funct7 1)
#include "extension.h"
#include "processor.h"
#include "disasm.h"
// Note: Spike's decode_macros.h (RS1, WRITE_RD, ...) is NOT installed under /opt/riscv/include,
// so an out-of-tree extension uses the processor state API directly.

#define MATCH_KMT_ADD1 0x0000000b
#define MATCH_KMT_MIX  0x0200000b
#define MASK_KMT_R     0xfe00707f

struct : public arg_t {
  std::string to_string(insn_t insn) const override { return xpr_name[insn.rd()]; }
} k_rd;
struct : public arg_t {
  std::string to_string(insn_t insn) const override { return xpr_name[insn.rs1()]; }
} k_rs1;
struct : public arg_t {
  std::string to_string(insn_t insn) const override { return xpr_name[insn.rs2()]; }
} k_rs2;

// Write rd and, in the "logged" variant, record the write for --log-commits.
template <bool logged>
static void write_rd(processor_t *p, insn_t insn, reg_t v)
{
  if (logged)
    p->get_state()->log_reg_write[insn.rd() << 4] = {v, 0};
  p->get_state()->XPR.write(insn.rd(), v);
}

template <bool logged>
static reg_t kmt_add1(processor_t *p, insn_t insn, reg_t pc)
{
  auto &x = p->get_state()->XPR;
  write_rd<logged>(p, insn, x[insn.rs1()] + x[insn.rs2()] + 1);
  return pc + 4;
}

template <bool logged>
static reg_t kmt_mix(processor_t *p, insn_t insn, reg_t pc)
{
  auto &x = p->get_state()->XPR;
  write_rd<logged>(p, insn, x[insn.rs1()] ^ (x[insn.rs2()] << 1));
  return pc + 4;
}

class kmtest_t : public extension_t
{
 public:
  const char *name() const override { return "kmtest"; }

  std::vector<insn_desc_t> get_instructions(const processor_t &) override
  {
    // Function pointers: fast rv32i, rv64i, rv32e, rv64e, then logged rv32i, rv64i, rv32e, rv64e.
    // (This toy is RV64-only; the rv32 slots reuse the same code.)
    auto a = kmt_add1<false>, al = kmt_add1<true>;
    auto m = kmt_mix<false>, ml = kmt_mix<true>;
    return {
      {MATCH_KMT_ADD1, MASK_KMT_R, a, a, a, a, al, al, al, al},
      {MATCH_KMT_MIX,  MASK_KMT_R, m, m, m, m, ml, ml, ml, ml},
    };
  }

  std::vector<disasm_insn_t *> get_disasms(const processor_t *) override
  {
    return {
      new disasm_insn_t("kmt.add1", MATCH_KMT_ADD1, MASK_KMT_R, {&k_rd, &k_rs1, &k_rs2}),
      new disasm_insn_t("kmt.mix",  MATCH_KMT_MIX,  MASK_KMT_R, {&k_rd, &k_rs1, &k_rs2}),
    };
  }
};

REGISTER_EXTENSION(kmtest, []() { static kmtest_t ext; return &ext; })
