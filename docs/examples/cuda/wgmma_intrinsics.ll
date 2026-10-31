; wgmma_intrinsics.ll: LLVM IR calling the NVVM intrinsics that LLVM 20 knows for Hopper.
target triple = "nvptx64-nvidia-cuda"

declare void @llvm.nvvm.wgmma.fence.sync.aligned()
declare void @llvm.nvvm.wgmma.commit_group.sync.aligned()
declare void @llvm.nvvm.wgmma.wait_group.sync.aligned(i64)
declare void @llvm.nvvm.setmaxnreg.inc.sync.aligned.u32(i32)
declare {i32, i1} @llvm.nvvm.elect.sync(i32)

define void @wgmma_sync_only(ptr addrspace(1) %out) {
  call void @llvm.nvvm.setmaxnreg.inc.sync.aligned.u32(i32 232)
  call void @llvm.nvvm.wgmma.fence.sync.aligned()
  call void @llvm.nvvm.wgmma.commit_group.sync.aligned()
  call void @llvm.nvvm.wgmma.wait_group.sync.aligned(i64 0)
  %r = call {i32, i1} @llvm.nvvm.elect.sync(i32 -1)
  %e = extractvalue {i32, i1} %r, 0
  store i32 %e, ptr addrspace(1) %out
  ret void
}

!nvvm.annotations = !{!0}
!0 = !{ptr @wgmma_sync_only, !"kernel", i32 1}
