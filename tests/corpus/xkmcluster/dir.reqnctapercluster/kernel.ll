; dir.reqnctapercluster: a kernel whose cluster size (2, 1, 1) is fixed at compile time.
target datalayout = "e-i64:64-i128:128-v16:16-v32:32-n16:32:64"
target triple = "nvptx64-nvidia-cuda"

define void @k_dir_reqnctapercluster(ptr addrspace(1) %d) {
entry:
  %tid = call i32 @llvm.nvvm.read.ptx.sreg.tid.x()
  %ctaid = call i32 @llvm.nvvm.read.ptx.sreg.ctaid.x()
  %base = mul i32 %ctaid, 128
  %i = add i32 %base, %tid
  %rank = call i32 @llvm.nvvm.read.ptx.sreg.cluster.ctarank()
  %nrank = call i32 @llvm.nvvm.read.ptx.sreg.cluster.nctarank()
  %ten = mul i32 %nrank, 10
  %v = add i32 %rank, %ten
  %idx = sext i32 %i to i64
  %q = getelementptr i32, ptr addrspace(1) %d, i64 %idx
  store i32 %v, ptr addrspace(1) %q
  ret void
}

declare i32 @llvm.nvvm.read.ptx.sreg.tid.x()
declare i32 @llvm.nvvm.read.ptx.sreg.ctaid.x()
declare i32 @llvm.nvvm.read.ptx.sreg.cluster.ctarank()
declare i32 @llvm.nvvm.read.ptx.sreg.cluster.nctarank()

!nvvm.annotations = !{!0, !1, !2, !3}
!0 = !{ptr @k_dir_reqnctapercluster, !"kernel", i32 1}
!1 = !{ptr @k_dir_reqnctapercluster, !"cluster_dim_x", i32 2}
!2 = !{ptr @k_dir_reqnctapercluster, !"cluster_dim_y", i32 1}
!3 = !{ptr @k_dir_reqnctapercluster, !"cluster_dim_z", i32 1}
