// multilane.cpp: step several sail-riscv hart models ("lanes") inside one process.
// Evidence that the Sail C++ backend keeps hart state per object, not in globals.
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <optional>
#include <vector>

#include "config_utils.h"
#include "elf_loader.h"
#include "riscv_model_impl.h"
#include "sail_config.h"

int main(int argc, char **argv)
{
  if (argc < 2) {
    fprintf(stderr, "usage: %s prog.elf [lanes]\n", argv[0]);
    return 1;
  }
  const int nlanes = argc > 2 ? atoi(argv[2]) : 4;

  // The configuration is process-global (sail_config.c), shared by all lanes.
  sail_config_set_string(get_default_config());

  std::vector<std::unique_ptr<ModelImpl>> lane;
  for (int i = 0; i < nlanes; ++i) {
    lane.push_back(std::make_unique<ModelImpl>());
    lane[i]->init_platform_constants();
    lane[i]->model_init();
  }

  // Physical memory is process-global (rts.c), so the ELF is loaded once and all lanes share it.
  ELF elf = ELF::open(argv[1]);
  elf.load([](uint64_t addr, const uint8_t *data, uint64_t len) {
    for (uint64_t i = 0; i < len; ++i)
      write_mem(addr + i, data[i]);
  });
  const auto syms = elf.symbols();

  for (int i = 0; i < nlanes; ++i) {
    lane[i]->init_sail(elf.entry(), "", std::nullopt);
    lane[i]->set_xreg(10, i); // a0 = lane id
  }

  // Round-robin: one instruction per lane per turn, like a SIMT scheduler would do.
  for (int64_t step = 0; step < 8; ++step)
    for (int i = 0; i < nlanes; ++i)
      lane[i]->try_step(step, false);

  for (int i = 0; i < nlanes; ++i)
    printf("lane %d: pc=0x%" PRIx64 " a0=%" PRIu64 " a1=%" PRIu64 "\n", i, lane[i]->pc(), lane[i]->xreg(10),
           lane[i]->xreg(11));

  const uint64_t base = syms.at("results");
  for (int i = 0; i < nlanes; ++i) {
    uint64_t v = 0;
    for (int b = 7; b >= 0; --b)
      v = (v << 8) | read_mem(base + 8 * i + b);
    printf("results[%d] = %" PRIu64 "\n", i, v);
  }

  // model_fini() also frees process-global state (the shared memory via cleanup_rts()/kill_mem(),
  // the GMP library temporaries, and the shared zghz* scratch values). Call it once, for the
  // last lane only, after every lane has stopped stepping.
  lane.back()->model_fini();
  return 0;
}
