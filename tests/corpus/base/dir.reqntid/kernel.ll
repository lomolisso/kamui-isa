; dir.reqntid: .reqntid 128 on a kernel; CUDA C++ has no spelling for it, the nvvm annotation does.
target datalayout = "e-i64:64-i128:128-v16:16-v32:32-n16:32:64"
target triple = "nvptx64-nvidia-cuda"

define void @k_dir_reqntid(ptr addrspace(1) %in, ptr addrspace(1) %d, i32 %n) {
entry:
  %tid = call i32 @llvm.nvvm.read.ptx.sreg.tid.x()
  %ctaid = call i32 @llvm.nvvm.read.ptx.sreg.ctaid.x()
  %base = mul i32 %ctaid, 128
  %i = add i32 %base, %tid
  %ok = icmp slt i32 %i, %n
  br i1 %ok, label %body, label %done
body:
  %idx = sext i32 %i to i64
  %p = getelementptr i32, ptr addrspace(1) %in, i64 %idx
  %v = load i32, ptr addrspace(1) %p
  %r = add i32 %v, 1
  %q = getelementptr i32, ptr addrspace(1) %d, i64 %idx
  store i32 %r, ptr addrspace(1) %q
  br label %done
done:
  ret void
}

declare i32 @llvm.nvvm.read.ptx.sreg.tid.x()
declare i32 @llvm.nvvm.read.ptx.sreg.ctaid.x()

!nvvm.annotations = !{!0, !1, !2, !3}
!0 = !{ptr @k_dir_reqntid, !"kernel", i32 1}
!1 = !{ptr @k_dir_reqntid, !"reqntidx", i32 128}
!2 = !{ptr @k_dir_reqntid, !"reqntidy", i32 1}
!3 = !{ptr @k_dir_reqntid, !"reqntidz", i32 1}
