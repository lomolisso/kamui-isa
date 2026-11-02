// From the PTX memory model of Lustig, Sahasrabuddhe and Giroux (ASPLOS 2019, NVlabs/PTXMemoryModel,
// BSD 3-Clause licence, see LICENSE). Changed: the variable e' is renamed e2, because Alloy 6 reads a prime as
// the temporal "next state" operator.

module util

fun symmetric[r: univ->univ] : univ->univ { r & ~r }
fun optional[f: univ->univ] : univ->univ  { iden + f }
pred irreflexive[rel: univ->univ]         { no iden & rel }
pred acyclic[rel: univ->univ]             { irreflexive[^rel] }
pred total[rel: univ->univ, bag: univ] {
  all disj e, e2: bag | e->e2 + e2->e in ^rel + ^~rel
  acyclic[rel]
}

fun ident[e: univ] : univ->univ       { iden & e->e }
fun imm[rel: univ->univ] : univ->univ { rel - rel.rel }
pred transitive[rel: univ->univ]      { rel = ^rel }
pred strict_partial[rel: univ->univ] {
  irreflexive[rel]
  transitive[rel]
}
