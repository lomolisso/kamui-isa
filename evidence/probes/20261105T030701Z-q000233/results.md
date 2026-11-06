# Probe results: 20261105T030701Z-q000233

## its-lock-in-warp

Runner result: `ok`, 5 runs.

| run | lanes that got the lock | max tries | max cycles | first lanes in order |
|---|---|---|---|---|
| 0 | 32/32 | 33 | 59289 | 0 1 2 3 4 5 6 7 ... |
| 1 | 32/32 | 33 | 59289 | 0 1 2 3 4 5 6 7 ... |
| 2 | 32/32 | 33 | 59300 | 0 1 2 3 4 5 6 7 ... |
| 3 | 32/32 | 33 | 59288 | 0 1 2 3 4 5 6 7 ... |
| 4 | 32/32 | 33 | 59204 | 0 1 2 3 4 5 6 7 ... |

## its-lock-in-loop

Runner result: `ok`, 5 runs.

| run | lanes that got the lock | max tries | max cycles | first lanes in order |
|---|---|---|---|---|
| 0 | 32/32 | 32 | 59459 | 0 1 2 3 4 5 6 7 ... |
| 1 | 32/32 | 32 | 59487 | 0 1 2 3 4 5 6 7 ... |
| 2 | 32/32 | 32 | 59445 | 0 1 2 3 4 5 6 7 ... |
| 3 | 32/32 | 32 | 59703 | 0 1 2 3 4 5 6 7 ... |
| 4 | 32/32 | 32 | 59438 | 0 1 2 3 4 5 6 7 ... |

## its-cross-branch-wait

Runner result: `ok`, 5 runs.

| run | if side (even lanes) finished | else side (odd lanes) finished | max reads waited, even | max reads waited, odd |
|---|---|---|---|---|
| 0 | 16/16 | 16/16 | 2 | 1 |
| 1 | 16/16 | 16/16 | 2 | 1 |
| 2 | 16/16 | 16/16 | 2 | 1 |
| 3 | 16/16 | 16/16 | 2 | 1 |
| 4 | 16/16 | 16/16 | 2 | 1 |

## its-producer-consumer

Runner result: `ok`, 5 runs.

| run | consumers that got their value | max reads waited |
|---|---|---|
| 0 | 31/31 | 0 |
| 1 | 31/31 | 0 |
| 2 | 31/31 | 0 |
| 3 | 31/31 | 0 |
| 4 | 31/31 | 0 |

## reconv-points

Runner result: `ok`, 5 runs.

| point | where | distinct active masks (run 0) | cycles |
|---|---|---|---|
| 0 | if side | aaaaaaaa | 137..137 |
| 1 | else side | 55555555 | 13547..13547 |
| 2 | after if/else | ffffffff | 28950..28950 |
| 3 | after loop (lane % 8 trips) | ffffffff | 31386..31386 |
| 4 | after break loop | ffffffff | 33877..33877 |
| 5 | nested if | 0000cccc | 33922..33922 |
| 6 | after nested if | ffffffff | 34293..34293 |
| 7 | after loop + __syncwarp | ffffffff | 44589..44589 |
| 8 | after early return (lanes < 24) | 00ffffff | 44927..44927 |

The two sides of the first branch ran: if side first. Masks identical in all runs: True; whole output identical: False.

## syncwarp-divergent

Runner result: `ok`, 5 runs.

| run | lanes that read the partner's value | active masks after the barrier |
|---|---|---|
| 0 | 32/32 | 0000ffff ffff0000 |
| 1 | 32/32 | 0000ffff ffff0000 |
| 2 | 32/32 | 0000ffff ffff0000 |
| 3 | 32/32 | 0000ffff ffff0000 |
| 4 | 32/32 | 0000ffff ffff0000 |

## addr-windows

Runner result: `ok`, 5 runs.

| field | CTA 0 | CTA 1 | CTA 2 | CTA 3 |
|---|---|---|---|---|
| gen_static | 0x7e5100000400 | 0x7e5101000400 | 0x7e5100000400 | 0x7e5101000400 |
| gen_dynamic | 0x7e5100000800 | 0x7e5101000800 | 0x7e5100000800 | 0x7e5101000800 |
| sh_static | 0x400 | 0x1000400 | 0x400 | 0x1000400 |
| sh_dynamic | 0x800 | 0x1000800 | 0x800 | 0x1000800 |
| rank | 0x0 | 0x1 | 0x0 | 0x1 |
| clusterid | 0x0 | 0x0 | 0x1 | 0x1 |
| smid | 0x7c | 0x7d | 0x7e | 0x7f |
| nctarank | 0x2 | 0x2 | 0x2 | 0x2 |
| mapa_gen0 | 0x7e5100000400 | 0x7e5100000400 | 0x7e5100000400 | 0x7e5100000400 |
| mapa_gen1 | 0x7e5101000400 | 0x7e5101000400 | 0x7e5101000400 | 0x7e5101000400 |
| mapa_sh0 | 0x400 | 0x400 | 0x400 | 0x400 |
| mapa_sh1 | 0x1000400 | 0x1000400 | 0x1000400 | 0x1000400 |
| res_begin | 0x0 | 0x0 | 0x0 | 0x0 |
| res_end | 0x120 | 0x120 | 0x120 | 0x120 |
| res_cap | 0x400 | 0x400 | 0x400 | 0x400 |
| total_smem | 0x1400 | 0x1400 | 0x1400 | 0x1400 |
| dyn_smem | 0x1000 | 0x1000 | 0x1000 | 0x1000 |
| aggr_smem | 0x1800 | 0x1800 | 0x1800 | 0x1800 |
| p_sh | 0x1 | 0x1 | 0x1 | 0x1 |
| p_shc | 0x1 | 0x1 | 0x1 | 0x1 |
| p_global | 0x0 | 0x0 | 0x0 | 0x0 |
| p_local | 0x0 | 0x0 | 0x0 | 0x0 |
| p_remote_sh | 0x0 | 0x0 | 0x0 | 0x0 |
| p_remote_shc | 0x1 | 0x1 | 0x1 | 0x1 |
| sh_lo | 0x7e5100000000 | 0x7e5101000000 | 0x7e5100000000 | 0x7e5101000000 |
| sh_hi | 0x7e5100ffffff | 0x7e5101ffffff | 0x7e5100ffffff | 0x7e5101ffffff |
| shc_lo | 0x7e5100000000 | 0x7e5100000000 | 0x7e5100000000 | 0x7e5100000000 |
| shc_hi | 0x7e51ffffffff | 0x7e51ffffffff | 0x7e51ffffffff | 0x7e51ffffffff |
| local_lo | 0x7e506d000000 | 0x7e506d000000 | 0x7e506d000000 | 0x7e506d000000 |
| local_hi | 0x7e506dffffff | 0x7e506dffffff | 0x7e506dffffff | 0x7e506dffffff |
| gen_local | 0x7e506dfffcc0 | 0x7e506dfffcc0 | 0x7e506dfffcc0 | 0x7e506dfffcc0 |
| local_off | 0xfffcc0 | 0xfffcc0 | 0xfffcc0 | 0xfffcc0 |
| p_local_local | 0x1 | 0x1 | 0x1 | 0x1 |
| gen_global | 0x7e505be00c00 | 0x7e505be00c00 | 0x7e505be00c00 | 0x7e505be00c00 |
| p_global_global | 0x1 | 0x1 | 0x1 | 0x1 |
| p_sh_past_dyn | 0x1 | 0x1 | 0x1 | 0x1 |
| sh_to_remote_gen | 0x7e5101000400 | 0x7e5101000400 | 0x7e5101000400 | 0x7e5101000400 |
| p_global_0x1000 | 0x1 | 0x1 | 0x1 | 0x1 |

Local addresses of lanes 0 and 1 in CTA 0: 0x7e506dfffcc0, 0x7e506dfffcc0; lane-to-lane strides: 0x0.

## lat-scopes-1

Runner result: `ok`, 5 runs.

| operation | cycles per op |
|---|---|
| ld_weak | 67.7 |
| ld_volatile | 308.4 |
| ld_relaxed_cta | 58.7 |
| ld_relaxed_cluster | 308.7 |
| ld_relaxed_gpu | 308.7 |
| ld_relaxed_sys | 308.6 |
| ld_acquire_cta | 59.8 |
| ld_acquire_cluster | 309.8 |
| ld_acquire_gpu | 312.9 |
| ld_acquire_sys | 309.7 |
| st_weak | 0.1 |
| st_relaxed_cta | 0.1 |
| st_relaxed_cluster | 0.1 |
| st_relaxed_gpu | 0.1 |
| st_relaxed_sys | 0.1 |
| st_release_cta | 15.0 |
| st_release_cluster | 554.0 |
| st_release_gpu | 553.9 |
| st_release_sys | 1174.6 |
| atom_relaxed_cta | 481.3 |
| atom_relaxed_cluster | 481.3 |
| atom_relaxed_gpu | 481.4 |
| atom_relaxed_sys | 481.3 |
| atom_acq_rel_cta | 485.4 |
| atom_acq_rel_cluster | 1026.8 |
| atom_acq_rel_gpu | 1024.3 |
| atom_acq_rel_sys | 1616.2 |
| red_relaxed_gpu | 4.6 |
| red_release_gpu | 554.8 |
| fence_acq_rel_cta | 9.8 |
| fence_acq_rel_cluster | 282.1 |
| fence_acq_rel_gpu | 274.8 |
| fence_acq_rel_sys | 1141.6 |
| fence_sc_cta | 8.2 |
| fence_sc_cluster | 274.8 |
| fence_sc_gpu | 278.1 |
| fence_sc_sys | 1138.1 |
| fence_proxy_async | 156.8 |
| fence_proxy_async_global | 4.3 |
| fence_proxy_async_shared_cta | 12.2 |
| fence_proxy_alias | 187.1 |
| mbarrier_arrive | 5.8 |
| mbarrier_arrive_try_wait | 39.3 |

Median over 5 runs; 32 back-to-back operations per sample.

## lat-scopes-warp-same

Runner result: `ok`, 5 runs.

| operation | cycles per op (median lane) | slowest lane |
|---|---|---|
| ld_weak | 62.6 | 62.6 |
| ld_volatile | 308.5 | 308.5 |
| ld_relaxed_cta | 58.7 | 58.7 |
| ld_relaxed_cluster | 308.5 | 308.5 |
| ld_relaxed_gpu | 308.7 | 308.7 |
| ld_relaxed_sys | 308.7 | 308.7 |
| ld_acquire_cta | 59.8 | 59.8 |
| ld_acquire_cluster | 309.7 | 309.7 |
| ld_acquire_gpu | 313.0 | 313.0 |
| ld_acquire_sys | 309.6 | 309.6 |
| st_weak | 0.1 | 0.1 |
| st_relaxed_cta | 0.1 | 0.1 |
| st_relaxed_cluster | 0.1 | 0.1 |
| st_relaxed_gpu | 0.1 | 0.1 |
| st_relaxed_sys | 0.1 | 0.1 |
| st_release_cta | 15.0 | 15.0 |
| st_release_cluster | 554.0 | 554.0 |
| st_release_gpu | 553.8 | 553.8 |
| st_release_sys | 1174.5 | 1174.5 |
| atom_relaxed_cta | 554.4 | 554.4 |
| atom_relaxed_cluster | 554.7 | 554.7 |
| atom_relaxed_gpu | 555.2 | 555.2 |
| atom_relaxed_sys | 554.5 | 554.5 |
| atom_acq_rel_cta | 558.6 | 558.6 |
| atom_acq_rel_cluster | 1101.7 | 1101.7 |
| atom_acq_rel_gpu | 1097.6 | 1097.6 |
| atom_acq_rel_sys | 1689.9 | 1689.9 |
| red_relaxed_gpu | 4.6 | 4.6 |
| red_release_gpu | 596.8 | 596.8 |
| fence_acq_rel_cta | 9.8 | 9.8 |
| fence_acq_rel_cluster | 278.9 | 278.9 |
| fence_acq_rel_gpu | 276.6 | 276.6 |
| fence_acq_rel_sys | 1141.1 | 1141.1 |
| fence_sc_cta | 8.2 | 8.2 |
| fence_sc_cluster | 274.0 | 274.0 |
| fence_sc_gpu | 277.3 | 277.3 |
| fence_sc_sys | 1137.8 | 1137.8 |
| fence_proxy_async | 156.7 | 156.7 |
| fence_proxy_async_global | 4.3 | 4.3 |
| fence_proxy_async_shared_cta | 12.2 | 12.2 |
| fence_proxy_alias | 187.1 | 187.1 |
| mbarrier_arrive | 5.8 | 5.8 |
| mbarrier_arrive_try_wait | 39.4 | 39.4 |

Median over 5 runs; 32 back-to-back operations per sample.

## lat-scopes-warp-distinct

Runner result: `ok`, 5 runs.

| operation | cycles per op (median lane) | slowest lane |
|---|---|---|
| ld_weak | 132.1 | 132.1 |
| ld_volatile | 365.8 | 365.8 |
| ld_relaxed_cta | 127.4 | 127.4 |
| ld_relaxed_cluster | 365.0 | 365.0 |
| ld_relaxed_gpu | 365.2 | 365.2 |
| ld_relaxed_sys | 366.1 | 366.1 |
| ld_acquire_cta | 128.4 | 128.4 |
| ld_acquire_cluster | 365.9 | 365.9 |
| ld_acquire_gpu | 369.3 | 369.3 |
| ld_acquire_sys | 367.2 | 367.2 |
| st_weak | 0.1 | 0.1 |
| st_relaxed_cta | 0.1 | 0.1 |
| st_relaxed_cluster | 0.1 | 0.1 |
| st_relaxed_gpu | 0.1 | 0.1 |
| st_relaxed_sys | 0.1 | 0.1 |
| st_release_cta | 44.8 | 44.8 |
| st_release_cluster | 695.0 | 695.0 |
| st_release_gpu | 673.6 | 673.6 |
| st_release_sys | 1261.1 | 1261.1 |
| atom_relaxed_cta | 581.7 | 581.7 |
| atom_relaxed_cluster | 578.5 | 578.5 |
| atom_relaxed_gpu | 578.4 | 578.4 |
| atom_relaxed_sys | 578.7 | 578.7 |
| atom_acq_rel_cta | 582.5 | 582.5 |
| atom_acq_rel_cluster | 1155.2 | 1155.2 |
| atom_acq_rel_gpu | 1151.3 | 1151.3 |
| atom_acq_rel_sys | 1713.1 | 1713.1 |
| red_relaxed_gpu | 4.6 | 4.6 |
| red_release_gpu | 610.9 | 610.9 |
| fence_acq_rel_cta | 9.8 | 9.8 |
| fence_acq_rel_cluster | 279.9 | 279.9 |
| fence_acq_rel_gpu | 276.6 | 276.6 |
| fence_acq_rel_sys | 1141.3 | 1141.3 |
| fence_sc_cta | 8.2 | 8.2 |
| fence_sc_cluster | 274.0 | 274.0 |
| fence_sc_gpu | 277.3 | 277.3 |
| fence_sc_sys | 1137.6 | 1137.6 |
| fence_proxy_async | 156.7 | 156.7 |
| fence_proxy_async_global | 4.3 | 4.3 |
| fence_proxy_async_shared_cta | 12.2 | 12.2 |
| fence_proxy_alias | 187.1 | 187.1 |
| mbarrier_arrive | 5.8 | 5.8 |
| mbarrier_arrive_try_wait | 39.4 | 39.4 |

Median over 5 runs; 32 back-to-back operations per sample.

## lat-warp

Runner result: `ok`, 5 runs.

| operation | cycles per op (median lane) | slowest lane |
|---|---|---|
| redux_sync_add | 46.5 | 46.5 |
| shfl_tree_add | 145.1 | 145.1 |
| vote_ballot | 22.6 | 22.6 |
| match_any | 39.3 | 39.3 |
| activemask | 2.5 | 2.5 |
| bar_warp_sync | 1.1 | 1.1 |
| elect_sync | 2.6 | 2.6 |
| read_ctaid | 3.2 | 3.2 |

Median over 5 runs; 32 back-to-back operations per sample.

## setmaxnreg-nodelay

Runner result: `ok`, 5 runs.

| CTA runs | decrease issued at (median cycle) | median decrease time | median increase wait | max increase wait |
|---|---|---|---|---|
| 660 | 260.0 | 61.0 | 260.0 | 386 |

Cycles (clock64, relative to the CTA's start). Warpgroups 1 and 2 issue the increase at once; warpgroup 0 issues the decrease after the delay. An increase wait close to the cycle the decrease is issued at means the increase waited for the registers the decrease gave back.

## setmaxnreg-delay

Runner result: `ok`, 5 runs.

| CTA runs | decrease issued at (median cycle) | median decrease time | median increase wait | max increase wait |
|---|---|---|---|---|
| 660 | 200144.0 | 60.0 | 200135.0 | 200181 |

Cycles (clock64, relative to the CTA's start). Warpgroups 1 and 2 issue the increase at once; warpgroup 0 issues the decrease after the delay. An increase wait close to the cycle the decrease is issued at means the increase waited for the registers the decrease gave back.

## bmov-break

Runner result: `ok`, 5 runs.

| run | nested right | call right | multi right | masks after nested | after call | after multi |
|---|---|---|---|---|---|---|
| 0 | 32/32 | 32/32 | 32/32 | ffffffff | 49249249 b6db6db6 | 00049249 001b6db6 00200000 00400000 00800000 01000000 02000000 04000000 08000000 10000000 20000000 40000000 80000000 |
| 1 | 32/32 | 32/32 | 32/32 | ffffffff | 49249249 b6db6db6 | 00049249 001b6db6 00200000 00400000 00800000 01000000 02000000 04000000 08000000 10000000 20000000 40000000 80000000 |
| 2 | 32/32 | 32/32 | 32/32 | ffffffff | 49249249 b6db6db6 | 00049249 001b6db6 00200000 00400000 00800000 01000000 02000000 04000000 08000000 10000000 20000000 40000000 80000000 |
| 3 | 32/32 | 32/32 | 32/32 | ffffffff | 49249249 b6db6db6 | 00049249 001b6db6 00200000 00400000 00800000 01000000 02000000 04000000 08000000 10000000 20000000 40000000 80000000 |
| 4 | 32/32 | 32/32 | 32/32 | ffffffff | 49249249 b6db6db6 | 00049249 001b6db6 00200000 00400000 00800000 01000000 02000000 04000000 08000000 10000000 20000000 40000000 80000000 |
