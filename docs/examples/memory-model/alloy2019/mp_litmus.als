// Message passing (MP) as an Alloy query against the ASPLOS 2019 PTX model.
// Two threads in different CTAs of one GPU:
//   T0: st.weak [x], 1 ; st.release.<s0> [y], 1
//   T1: ld.acquire.<s1> r0, [y] ; ld.weak r1, [x]
// Question: can r0 == 1 (Ry reads Wy) and r1 == 0 (Rx reads the initial value)?
module mp_litmus
open ptx

one sig Sys, Gpu, Cta0, Cta1 extends Scope {}
one sig T0, T1 extends Thread {}
one sig X, Y extends Address {}
one sig Wx extends Write {}
one sig Wy extends Release {}
one sig Ry extends Acquire {}
one sig Rx extends Read {}

fact shape {
  // nothing else exists in the universe
  Event = Wx + Wy + Ry + Rx
  Scope = Sys + Gpu + Cta0 + Cta1 + T0 + T1
  Address = X + Y
  // scope tree: Sys > Gpu > {Cta0 > T0, Cta1 > T1}
  subscope = Sys->Gpu + Gpu->Cta0 + Gpu->Cta1 + Cta0->T0 + Cta1->T1
  start = T0->Wx + T1->Ry
  po = Wx->Wy + Ry->Rx
  address = Wx->X + Rx->X + Wy->Y + Ry->Y
  // weak accesses carry their own thread as scope
  Wx.scope = T0
  Rx.scope = T1
  no dep
  no rmw
}

// The outcome under test: Ry reads Wy, Rx reads the initial value of x.
pred outcome { Ry in Wy.rf and no rf.Rx }

// gpu-scope release/acquire: expected "no instance" (forbidden).
run MP_gpu { ptx_mm and outcome and Wy.scope = Gpu and Ry.scope = Gpu } for 6
// cta-scope release/acquire across CTAs: expected an instance (allowed).
run MP_cta { ptx_mm and outcome and Wy.scope = Cta0 and Ry.scope = Cta1 } for 6
