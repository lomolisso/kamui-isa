// Enumerate the instances of an Alloy litmus query (a module that opens ptx87 or kamui) and print each one in the
// format of FORMAT.md (next to this file): the fields of the execution, then Alloy's own values of the model's
// predicates and derived relations in that instance. Written against the Alloy 6.2.0 API.
//
//   java -cp <alloy jar>:<classes> AlloyDump [--cmd NAME | --all] [--max N] [--solver S] [--out FILE] [--check]
//        [--pair] QUERY.als
//
//   --pair      the query is the lowering check models/kamui/compile_ptx87_kamui.als (or a module that opens it):
//               print the PTX execution (p/), the Kamui execution (k/) and the map between them (FORMAT.md)
//   --cmd NAME  enumerate the instances of that run command of the query (default: unconstrained)
//   --all       enumerate the instances of the facts alone: the scopes of `unconstrained`, with the facts as formula
//   --max N     stop after N instances; if there are more, print "truncated" on stderr and exit with 3
//   --solver S  the SAT solver (default glucose; it needs -Djava.library.path=<Alloy's native lib dir>)
//   --out FILE  write the instances to FILE instead of stdout (the native solvers print to stdout themselves)
//   --check     also evaluate everything with A4Solution.eval (slow) and fail if the answers differ (see Eval)
//
// The run uses noOverflow (like `alloy exec -n`). Exit status: 0 done, 2 error (message on stderr), 3 truncated.
// dump.sh, next to this file, compiles and runs this program in the build area.

import edu.mit.csail.sdg.alloy4.A4Reporter;
import edu.mit.csail.sdg.alloy4.Err;
import edu.mit.csail.sdg.alloy4.Pair;
import edu.mit.csail.sdg.ast.Command;
import edu.mit.csail.sdg.ast.Expr;
import edu.mit.csail.sdg.ast.ExprVar;
import edu.mit.csail.sdg.parser.CompModule;
import edu.mit.csail.sdg.parser.CompUtil;
import edu.mit.csail.sdg.translator.A4Options;
import edu.mit.csail.sdg.translator.A4Solution;
import edu.mit.csail.sdg.translator.A4Tuple;
import edu.mit.csail.sdg.translator.A4TupleSet;
import edu.mit.csail.sdg.translator.TranslateAlloyToKodkod;
import kodkod.ast.BinaryExpression;
import kodkod.ast.BinaryIntExpression;
import kodkod.ast.BinaryTempFormula;
import kodkod.ast.Comprehension;
import kodkod.ast.Decl;
import kodkod.ast.Decls;
import kodkod.ast.ExprToIntCast;
import kodkod.ast.Expression;
import kodkod.ast.Formula;
import kodkod.ast.IfExpression;
import kodkod.ast.IfIntExpression;
import kodkod.ast.IntComparisonFormula;
import kodkod.ast.IntConstant;
import kodkod.ast.IntExpression;
import kodkod.ast.IntToExprCast;
import kodkod.ast.NaryExpression;
import kodkod.ast.NaryIntExpression;
import kodkod.ast.Node;
import kodkod.ast.ProjectExpression;
import kodkod.ast.QuantifiedFormula;
import kodkod.ast.Relation;
import kodkod.ast.SumExpression;
import kodkod.ast.TempExpression;
import kodkod.ast.UnaryExpression;
import kodkod.ast.UnaryIntExpression;
import kodkod.ast.UnaryTempFormula;
import kodkod.ast.Variable;
import kodkod.ast.visitor.AbstractCollector;
import kodkod.ast.visitor.AbstractDetector;
import kodkod.ast.visitor.AbstractReplacer;
import kodkod.engine.Evaluator;
import kodkod.engine.satlab.SATFactory;
import kodkod.instance.Instance;
import kodkod.instance.TemporalInstance;
import kodkod.instance.TupleSet;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.nio.charset.StandardCharsets;
import java.util.AbstractSet;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Pattern;

public final class AlloyDump {

  /** A failure that ends the run with exit status 2. */
  static final class Fail extends RuntimeException {
    Fail(String msg) { super(msg); }
  }

  // The fields of the execution, in the order of the record Exec in Ptx87.v. Each is printed as one line per
  // tuple: atoms of the four carriers as their numbers, integers as decimals, proxies and spaces by name.
  static final String[] FIELDS = {
    "subscope", "start",
    "alias", "space", "owner", "init",
    "po", "scope", "issue", "done", "gdep",
    "address", "proxy", "val", "acc",
    "rmw", "dep", "rf", "co", "sc",
    "SyncRestrictCta", "SyncRestrictCluster", "OpRestrictInit",
    "ProxyFence", "dirs", "pspace", "paddr",
    "bid", "bcount", "bwait", "bgen", "synchronizes",
    "cwait", "cgen", "ClusterArriveRelaxed",
    "Mbar", "iph", "ipend", "iexp", "itx",
    "MbarEv", "ph", "pend", "expc", "tx", "MbarInit", "MbarWait", "wpar", "wtok",
    "TxAnchor", "txops",
  };

  static final String[] PREDS = {
    "coherence", "fence_sc", "atomicity", "no_thin_air", "sc_per_location", "causality", "ptx_mm",
    "mb_undefined", "undefined", "mixed_size_race", "outcome",
  };
  static final String[] PAIR_PREDS = Arrays.copyOf(PREDS, PREDS.length - 1);   // a pair run has no outcome

  // The signature that declares each field. In a pair run both models have a field of each name, so a field is
  // named through its signature there, as compile_ptx87_kamui.als does: `(p/Read <: rmw)`. The fields that are
  // signatures themselves (SyncRestrictCta, Mbar, ...) have no entry.
  static final Map<String, String> OWNER = new HashMap<>();
  static {
    String[][] owners = {
      {"Scope", "subscope"}, {"Thread", "start"}, {"Address", "alias", "space", "owner", "init"},
      {"Event", "po", "scope", "issue", "done", "gdep"}, {"MemoryEvent", "address", "proxy", "val", "acc"},
      {"Read", "rmw", "dep"}, {"Write", "rf", "co"}, {"FenceSC", "sc"}, {"ProxyFence", "dirs", "pspace", "paddr"},
      {"BarrierArrive", "bid", "bcount", "bwait", "bgen", "synchronizes"}, {"ClusterArrive", "cwait", "cgen"},
      {"Mbar", "iph", "ipend", "iexp", "itx"}, {"MbarEv", "ph", "pend", "expc", "tx"},
      {"MbarWait", "wpar", "wtok"}, {"TxAnchor", "txops"},
    };
    for (String[] o : owners) for (int i = 1; i < o.length; i++) OWNER.put(o[i], o[0]);
  }

  static final String[] RELS = {
    "thd", "aliases", "same_location_r", "fr", "com", "po_loc", "cta_of", "cluster_of", "scope_incl_r",
    "footprint", "ms_r", "obs", "rel_pattern", "acq_pattern", "sync_pattern", "cluster_sync", "sw", "rleft",
    "rright", "bco_plain", "sw_restricted", "cause_base", "pf_src", "pf_dst", "ppbco", "cause", "atomic_pair_r",
  };

  static final String[] SETS = { "System", "Weak", "FalseWaits", "AcqReads", "Atomics" };

  // Event kinds: the name printed and the set expression that holds exactly the events of that kind.
  static final String[][] KINDS = {
    {"Acquire", "Acquire"}, {"Read", "Read - Acquire"},
    {"Release", "Release"}, {"Write", "Write - Release"},
    {"FenceSC", "FenceSC"}, {"FenceAcqRel", "FenceAcqRel - FenceSC"},
    {"FenceAcq", "FenceAcq"}, {"FenceRel", "FenceRel"},
    {"AliasFence", "AliasFence"}, {"PlainProxyFence", "PlainProxyFence"},
    {"BarrierArrive", "BarrierArrive"}, {"BarrierWait", "BarrierWait"},
    {"ClusterArrive", "ClusterArrive"}, {"ClusterWait", "ClusterWait"},
    {"Marker", "Marker"},
  };

  static final String[][] SKINDS = {
    {"AsyncUnit", "AsyncUnit"}, {"Thread", "Thread - AsyncUnit"},
    {"Cta", "CtaScope"}, {"Cluster", "ClusterScope"},
    {"Node", "Scope - Thread - CtaScope - ClusterScope"},
  };

  // The atoms of Proxy and Space, printed by name, in the order of their declarations (the order of the lines).
  static final List<String> NAMED = List.of("Generic", "Async", "TensorMap", "Texture", "Surface", "Constant",
                                            "Global", "Shared", "Local", "Const", "Param");

  // The carriers, in the order of the `size` line.
  static final String[] CARRIERS = {"Event", "Scope", "Address", "Access"};

  final CompModule world;
  final String modelModule;              // ptx87 or kamui (compile_ptx87_kamui in a pair run): see expr
  final Map<String, Expr> parsed = new HashMap<>();

  AlloyDump(CompModule world, boolean pair) {
    this.world = world;
    Set<String> opened = new HashSet<>();
    for (CompModule m : world.getAllReachableModules()) opened.add(m.getModuleName());
    if (pair) {
      if (!opened.containsAll(List.of("ptx87", "kamui", "compile_ptx87_kamui")))
        throw new Fail("--pair needs a query that opens compile_ptx87_kamui (with ptx87 as p and kamui as k)");
      modelModule = "compile_ptx87_kamui";
    } else {
      boolean ptx = opened.contains("ptx87"), kamui = opened.contains("kamui");
      if (ptx && kamui) throw new Fail("the query opens both ptx87 and kamui (use --pair for the lowering check)");
      if (!ptx && !kamui) throw new Fail("the query opens neither ptx87 nor kamui");
      modelModule = opened.contains("ptx87") ? "ptx87" : "kamui";
    }
  }

  static final Pattern NAME = Pattern.compile("[A-Za-z_][A-Za-z_0-9]*");

  /** The expression with every name prefixed by a model's alias: `Read - Acquire` with p/ is `p/Read - p/Acquire`. */
  static String q(String pre, String text) {
    return pre.isEmpty() ? text : NAME.matcher(text).replaceAll(m -> pre + m.group());
  }

  /** A field of a model, named through its signature when a prefix is given. */
  static String field(String pre, String f) {
    String o = OWNER.get(f);
    return pre.isEmpty() || o == null ? q(pre, f) : "(" + pre + o + " <: " + f + ")";
  }

  /** Parse an expression in the query's world. A name of the model that the query's own names hide is tried
   *  again with the model's module name in front. */
  Expr expr(String s) {
    Expr e = parsed.get(s);
    if (e != null) return e;
    try {
      e = CompUtil.parseOneExpression_fromString(world, s);
    } catch (Err first) {
      if (!s.matches("[A-Za-z_][A-Za-z_0-9]*")) throw new Fail("cannot parse `" + s + "`: " + first.getMessage());
      try {
        e = CompUtil.parseOneExpression_fromString(world, modelModule + "/" + s);
      } catch (Err second) {
        throw new Fail("cannot parse `" + s + "`: " + first.getMessage());
      }
    }
    parsed.put(s, e);
    return e;
  }

  /**
   * Evaluates expressions in one instance. The answers are those of A4Solution.eval, which translates the
   * expression to Kodkod and evaluates it with Kodkod's evaluator. That evaluator does not reuse the value of a
   * subexpression that occurs several times, and the model's relations are built from each other many times over
   * (ppbco uses cause_base about thirty times), so A4Solution.eval takes seconds per predicate. Here the same
   * translation is evaluated by the same Kodkod evaluator, with the same options, but bottom up: each
   * subexpression that has no free variable and no integer operation is evaluated once, and replaced by a new
   * relation that holds its value. Such a subexpression means the same in every context, so the answer does not
   * change; integer operations are left in place because under noOverflow their meaning depends on the context.
   * With --check, every answer is compared with A4Solution.eval.
   */
  static final class Eval {
    final A4Solution sol;
    final boolean check;
    final Instance inst;              // state 0 of the solution, plus the relations added for subexpressions
    final Evaluator kk;
    final Map<Node, Node> memo = new HashMap<>();   // shared by all expressions of this instance
    int fresh = 0;

    // Every node is cached by the Kodkod visitors below (their caches are keyed by node identity). The visitors
    // only ask whether a node is in this set, and its size to size their cache.
    static final Set<Node> ALL = new AbstractSet<Node>() {
      @Override public boolean contains(Object o) { return true; }
      @Override public Iterator<Node> iterator() { throw new UnsupportedOperationException(); }
      @Override public int size() { return 1024; }
    };

    Eval(A4Solution sol, boolean check) {
      this.sol = sol;
      this.check = check;
      Evaluator base;
      try {
        Field f = A4Solution.class.getDeclaredField("eval");
        f.setAccessible(true);
        base = (Evaluator) f.get(sol);
      } catch (ReflectiveOperationException e) {
        throw new Fail("cannot reach the evaluator of the solution: " + e);
      }
      if (base == null) throw new Fail("the solution has no evaluator");
      Instance i = base.instance();
      if (i instanceof TemporalInstance) i = ((TemporalInstance) i).state(0);
      inst = i.clone();
      kk = new Evaluator(inst, base.options());
    }

    Object kodkod(Expr e, String what) {
      try {
        return TranslateAlloyToKodkod.alloy2kodkod(sol, e);
      } catch (Err err) {
        throw new Fail("cannot translate " + what + ": " + err.getMessage());
      }
    }

    A4TupleSet tuples(Expr e, String what) {
      Object k = kodkod(e, what);
      if (!(k instanceof Expression)) throw new Fail(what + " is not a relation");
      TupleSet ts = kk.evaluate((Expression) ((Expression) k).accept(new Memo()));
      A4TupleSet r = wrap(ts);
      if (check) {
        Object v = slow(e, what);
        if (!(v instanceof A4TupleSet) || !same((A4TupleSet) v, r))
          throw new Fail("the two evaluations of " + what + " differ: " + v + " and " + r);
      }
      return r;
    }

    boolean truth(Expr e, String what) {
      Object k = kodkod(e, what);
      if (!(k instanceof Formula)) throw new Fail(what + " is not a formula");
      boolean r = kk.evaluate((Formula) ((Formula) k).accept(new Memo()));
      if (check) {
        Object v = slow(e, what);
        if (!(v instanceof Boolean) || (Boolean) v != r)
          throw new Fail("the two evaluations of " + what + " differ: " + v + " and " + r);
      }
      return r;
    }

    /** The value of a skolem relation of the solution (it has no Alloy expression to translate). */
    A4TupleSet skolem(ExprVar v) {
      Object r = slow(v, "skolem " + v.label);
      if (!(r instanceof A4TupleSet)) throw new Fail("skolem " + v.label + " is not a relation");
      return (A4TupleSet) r;
    }

    Object slow(Expr e, String what) {
      try {
        return sol.eval(e);
      } catch (Err err) {
        throw new Fail("cannot evaluate " + what + ": " + err.getMessage());
      }
    }

    A4TupleSet wrap(TupleSet ts) {
      try {
        Constructor<A4TupleSet> c = A4TupleSet.class.getDeclaredConstructor(TupleSet.class, A4Solution.class);
        c.setAccessible(true);
        return c.newInstance(ts, sol);
      } catch (ReflectiveOperationException e) {
        throw new Fail("cannot build a tuple set: " + e);
      }
    }

    static boolean same(A4TupleSet a, A4TupleSet b) {
      Set<String> x = new HashSet<>(), y = new HashSet<>();
      for (A4Tuple t : a) x.add(t.toString());
      for (A4Tuple t : b) y.add(t.toString());
      return a.arity() == b.arity() && x.equals(y);
    }

    /** The free variables of a node, whatever its context. */
    static final class FreeVars extends AbstractCollector<Variable> {
      FreeVars() { super(ALL); }
      @Override protected Set<Variable> newSet() { return new HashSet<>(); }
      @Override public Set<Variable> visit(Variable v) { return Set.of(v); }
      @Override public Set<Variable> visit(Decl d) {
        Set<Variable> r = lookup(d);
        return r != null ? r : cache(d, d.expression().accept(this));
      }
      Set<Variable> bind(Node n, Decls ds, Node body) {
        Set<Variable> r = lookup(n);
        if (r != null) return r;
        r = newSet();
        r.addAll(ds.accept(this));
        if (body instanceof Formula) r.addAll(((Formula) body).accept(this));
        else if (body instanceof Expression) r.addAll(((Expression) body).accept(this));
        else r.addAll(((IntExpression) body).accept(this));
        for (Decl d : ds) r.remove(d.variable());
        return cache(n, r);
      }
      @Override public Set<Variable> visit(Comprehension c) { return bind(c, c.decls(), c.formula()); }
      @Override public Set<Variable> visit(QuantifiedFormula q) { return bind(q, q.decls(), q.formula()); }
      @Override public Set<Variable> visit(SumExpression x) { return bind(x, x.decls(), x.intExpr()); }
    }

    /** Whether a node holds an integer or temporal operation. */
    static final class Impure extends AbstractDetector {
      Impure() { super(ALL); }
      @Override public Boolean visit(IntConstant x) { return true; }
      @Override public Boolean visit(IfIntExpression x) { return true; }
      @Override public Boolean visit(ExprToIntCast x) { return true; }
      @Override public Boolean visit(NaryIntExpression x) { return true; }
      @Override public Boolean visit(BinaryIntExpression x) { return true; }
      @Override public Boolean visit(UnaryIntExpression x) { return true; }
      @Override public Boolean visit(SumExpression x) { return true; }
      @Override public Boolean visit(IntComparisonFormula x) { return true; }
      @Override public Boolean visit(IntToExprCast x) { return true; }
      @Override public Boolean visit(UnaryTempFormula x) { return true; }
      @Override public Boolean visit(BinaryTempFormula x) { return true; }
      @Override public Boolean visit(TempExpression x) { return true; }
    }

    final FreeVars freeVars = new FreeVars();
    final Impure impure = new Impure();

    /** Rebuilds an expression bottom up, with each closed relational subexpression replaced by its value. */
    final class Memo extends AbstractReplacer {
      Memo() { super(ALL, memo); }
      Expression value(Expression x, Expression rebuilt) {
        if (rebuilt instanceof Relation || !x.accept(freeVars).isEmpty() || x.accept(impure)) {
          return cache(x, rebuilt);
        }
        Relation r = Relation.nary("memo$" + fresh++, rebuilt.arity());
        inst.add(r, kk.evaluate(rebuilt));
        return cache(x, r);
      }
      @Override public Expression visit(BinaryExpression x) {
        Expression r = lookup(x);
        return r != null ? r : value(x, super.visit(x));
      }
      @Override public Expression visit(UnaryExpression x) {
        Expression r = lookup(x);
        return r != null ? r : value(x, super.visit(x));
      }
      @Override public Expression visit(NaryExpression x) {
        Expression r = lookup(x);
        return r != null ? r : value(x, super.visit(x));
      }
      @Override public Expression visit(Comprehension x) {
        Expression r = lookup(x);
        return r != null ? r : value(x, super.visit(x));
      }
      @Override public Expression visit(IfExpression x) {
        Expression r = lookup(x);
        return r != null ? r : value(x, super.visit(x));
      }
      @Override public Expression visit(ProjectExpression x) {
        Expression r = lookup(x);
        return r != null ? r : value(x, super.visit(x));
      }
    }
  }

  /** Compare atom names with runs of digits read as numbers: E2$0 before E10$0. */
  static int natural(String a, String b) {
    int i = 0, j = 0;
    while (i < a.length() && j < b.length()) {
      char x = a.charAt(i), y = b.charAt(j);
      if (Character.isDigit(x) && Character.isDigit(y)) {
        int i2 = i, j2 = j;
        while (i2 < a.length() && Character.isDigit(a.charAt(i2))) i2++;
        while (j2 < b.length() && Character.isDigit(b.charAt(j2))) j2++;
        String p = a.substring(i, i2).replaceFirst("^0+(?=.)", "");
        String q = b.substring(j, j2).replaceFirst("^0+(?=.)", "");
        if (p.length() != q.length()) return p.length() - q.length();
        int c = p.compareTo(q);
        if (c != 0) return c;
        i = i2;
        j = j2;
      } else {
        if (x != y) return x - y;
        i++;
        j++;
      }
    }
    if (a.length() - i != b.length() - j) return (a.length() - i) - (b.length() - j);
    return a.compareTo(b);
  }

  /** The atoms of a set, sorted by name with runs of digits compared as numbers. */
  List<String> atoms(Eval sol, String e) {
    List<String> atoms = new ArrayList<>();
    for (A4Tuple t : sol.tuples(expr(e), e)) atoms.add(t.atom(0));
    atoms.sort(AlloyDump::natural);
    return atoms;
  }

  static void number(List<String> atoms, Map<String, Integer> num) {
    for (int i = 0; i < atoms.size(); i++) {
      if (num.put(atoms.get(i), i) != null) throw new Fail("atom " + atoms.get(i) + " is in two carriers");
    }
  }

  /** One instance of a litmus query: the block from its `size` line to its `end` line. */
  String litmus(Eval sol) {
    Map<String, Integer> num = new HashMap<>();
    List<List<String>> carrier = new ArrayList<>();
    for (String c : CARRIERS) {
      List<String> a = atoms(sol, c);
      number(a, num);
      carrier.add(a);
    }
    return execution(sol, "", num, carrier.get(0), carrier.get(1), carrier.get(2).size(), carrier.get(3).size(),
                     PREDS, true);
  }

  /** The block of one execution, from its `size` line to its `end` line. `num` numbers its atoms; `events` and
   *  `scopes` list them in the order of their numbers. `pre` is the alias of the model in a pair run. */
  String execution(Eval sol, String pre, Map<String, Integer> num, List<String> events, List<String> scopes,
                   int addresses, int accesses, String[] preds, boolean derived) {
    StringWriter block = new StringWriter();
    PrintWriter out = new PrintWriter(block);
    out.println("size " + events.size() + " " + scopes.size() + " " + addresses + " " + accesses);

    // kinds of scopes and events: each atom must be in exactly one class
    classify(sol, pre, "skind", SKINDS, scopes, num, out);
    classify(sol, pre, "kind", KINDS, events, num, out);

    for (String f : FIELDS) lines(sol, field(pre, f), f, num, out);

    for (String p : preds) out.println("alloy " + p + " " + (sol.truth(expr(q(pre, p)), q(pre, p)) ? 1 : 0));
    if (derived) {
      for (String r : RELS) lines(sol, q(pre, r), "alloyrel " + r, num, out);
      for (String s : SETS) lines(sol, q(pre, s), "alloyset " + s, num, out);
    }
    out.println("end");
    out.flush();
    return block.toString();
  }

  /**
   * One instance of the lowering check: the PTX execution, the Kamui execution and the map. The PTX atoms are
   * numbered as in a litmus query. The Kamui scopes and addresses take the numbers of the PTX ones they are the
   * image of (Map.sm, Map.ad); the Kamui events are numbered on their own.
   */
  String[] pair(Eval sol) {
    for (String a : new String[]{"p/Access", "k/Access"}) {
      if (!atoms(sol, a).isEmpty()) throw new Fail("a pair run with " + a + " atoms");
    }
    Map<String, Integer> pn = new HashMap<>(), kn = new HashMap<>();
    List<String> pe = atoms(sol, "p/Event"), ps = atoms(sol, "p/Scope"), pa = atoms(sol, "p/Address");
    number(pe, pn);
    number(ps, pn);
    number(pa, pn);
    List<String> ke = atoms(sol, "k/Event");
    number(ke, kn);
    List<String> ks = image(sol, "Map.sm", "k/Scope", ps, pn, kn);
    image(sol, "Map.ad", "k/Address", pa, pn, kn);

    String p = execution(sol, "p/", pn, pe, ps, pa.size(), 0, PAIR_PREDS, false);
    String k = execution(sol, "k/", kn, ke, ks, pa.size(), 0, PAIR_PREDS, false);

    // the map: event numbers of both sides
    Map<String, Integer> en = new HashMap<>();
    for (String a : pe) en.put(a, pn.get(a));
    for (String a : ke) en.put(a, kn.get(a));
    StringWriter block = new StringWriter();
    PrintWriter out = new PrintWriter(block);
    lines(sol, "Map.ev", "ev", en, out);
    lines(sol, "Map.pre", "pre", en, out);
    lines(sol, "Map.widen", "widen", en, out);
    lines(sol, "Map.relax", "relax", en, out);
    // the witnesses of the run's top-level `some x: ...`: every skolem relation that holds PTX events
    List<String> witness = new ArrayList<>();
    for (ExprVar v : sol.sol.getAllSkolems()) {
      A4TupleSet ts = sol.skolem(v);
      if (ts.arity() != 1 || ts.size() == 0) continue;
      List<String> w = new ArrayList<>();
      for (A4Tuple t : ts) {
        if (!pe.contains(t.atom(0))) {
          w = null;
          break;
        }
        w.add("witness " + v.label + " " + pn.get(t.atom(0)));
      }
      if (w != null) witness.addAll(w);
    }
    witness.sort(null);
    for (String w : witness) out.println(w);
    out.println("end");
    out.flush();
    return new String[]{p, k, block.toString()};
  }

  /** Number the Kamui atoms of `sig` with the numbers of the PTX atoms they are the image of, through the map
   *  `rel` (PTX atom -> Kamui atom), which must be a bijection. Returns the Kamui atoms in number order. */
  List<String> image(Eval sol, String rel, String sig, List<String> from, Map<String, Integer> pn,
                     Map<String, Integer> kn) {
    String[] to = new String[from.size()];
    for (A4Tuple t : sol.tuples(expr(rel), rel)) {
      Integer n = pn.get(t.atom(0));
      if (n == null || !from.get(n).equals(t.atom(0))) throw new Fail(rel + " maps " + t.atom(0) + ", not of " + sig);
      if (to[n] != null) throw new Fail(rel + " maps " + t.atom(0) + " twice");
      to[n] = t.atom(1);
    }
    List<String> all = atoms(sol, sig);
    if (all.size() != from.size() || !new HashSet<>(Arrays.asList(to)).equals(new HashSet<>(all)))
      throw new Fail(rel + " is not a bijection onto " + sig);
    for (int i = 0; i < to.length; i++) {
      if (kn.put(to[i], i) != null) throw new Fail("atom " + to[i] + " is in two carriers");
    }
    return Arrays.asList(to);
  }

  void classify(Eval sol, String pre, String line, String[][] classes, List<String> atoms, Map<String, Integer> num,
                PrintWriter out) {
    Map<String, String> kind = new HashMap<>();
    for (String[] c : classes) {
      String e = q(pre, c[1]);
      for (A4Tuple t : sol.tuples(expr(e), e)) {
        String prev = kind.put(t.atom(0), c[0]);
        if (prev != null) throw new Fail("atom " + t.atom(0) + " is both " + prev + " and " + c[0]);
      }
    }
    for (String a : atoms) {
      String k = kind.get(a);
      if (k == null) throw new Fail("atom " + a + " has no known kind");
      out.println(line + " " + num.get(a) + " " + k);
    }
    if (kind.size() != atoms.size()) throw new Fail("a " + line + " class holds an atom outside its carrier");
  }

  /** Print the tuples of an expression, sorted, one line each, after the prefix. */
  void lines(Eval sol, String e, String prefix, Map<String, Integer> num, PrintWriter out) {
    List<String[]> rows = new ArrayList<>();
    List<long[]> keys = new ArrayList<>();
    for (A4Tuple t : sol.tuples(expr(e), e)) {
      String[] row = new String[t.arity()];
      long[] key = new long[t.arity()];
      for (int i = 0; i < t.arity(); i++) {
        String a = t.atom(i);
        Integer n = num.get(a);
        if (n != null) {
          row[i] = Integer.toString(n);
          key[i] = n;
        } else if (a.matches("-?[0-9]+")) {   // an Int atom (the other atoms' names hold a '$')
          int v = Integer.parseInt(a);
          row[i] = Integer.toString(v);
          key[i] = v;
        } else {
          String base = a.replaceFirst("\\$[0-9]+$", "").replaceFirst("^.*/", "");   // ptx87/Global$0: Global
          if (!NAMED.contains(base)) throw new Fail("unexpected atom " + a + " in " + e);
          row[i] = base;
          key[i] = NAMED.indexOf(base);
        }
      }
      rows.add(row);
      keys.add(key);
    }
    Integer[] order = new Integer[rows.size()];
    for (int i = 0; i < order.length; i++) order[i] = i;
    Arrays.sort(order, (x, y) -> {
      long[] p = keys.get(x), q = keys.get(y);
      for (int i = 0; i < p.length; i++) if (p[i] != q[i]) return Long.compare(p[i], q[i]);
      return 0;
    });
    for (int i : order) out.println(prefix + " " + String.join(" ", rows.get(i)));
  }

  static void usage() {
    throw new Fail("usage: AlloyDump [--cmd NAME | --all] [--max N] [--solver S] [--out FILE] [--check] [--pair] "
                   + "QUERY.als");
  }

  static int run(String[] args) throws Err, IOException {
    String cmdName = "unconstrained", solver = "glucose", file = null, outFile = null;
    boolean all = false, cmdGiven = false, check = false, pair = false;
    long max = -1;
    for (int i = 0; i < args.length; i++) {
      switch (args[i]) {
        case "--cmd": if (++i >= args.length) usage(); cmdName = args[i]; cmdGiven = true; break;
        case "--all": all = true; break;
        case "--check": check = true; break;
        case "--pair": pair = true; break;
        case "--max":
          if (++i >= args.length) usage();
          try {
            max = Long.parseLong(args[i]);
          } catch (NumberFormatException x) {
            usage();
          }
          if (max < 0) usage();
          break;
        case "--solver": if (++i >= args.length) usage(); solver = args[i]; break;
        case "--out": if (++i >= args.length) usage(); outFile = args[i]; break;
        default:
          if (args[i].startsWith("-") || file != null) usage();
          file = args[i];
      }
    }
    if (file == null || (all && cmdGiven) || (pair && !cmdGiven)) usage();

    CompModule world = CompUtil.parseEverything_fromFile(A4Reporter.NOP, null, file);
    AlloyDump d = new AlloyDump(world, pair);
    String want = all ? "unconstrained" : cmdName;
    Command cmd = null;
    for (Command c : world.getAllCommands()) {
      if (c.label.equals(want)) {
        if (cmd != null) throw new Fail("two commands named " + want);
        cmd = c;
      }
    }
    if (cmd == null) throw new Fail("no command named " + want + " in " + file);
    if (cmd.check) throw new Fail("command " + want + " is a check, not a run");
    // A command's formula already holds the facts (the parser adds them), so the facts alone are the formula of
    // --all; true would drop them.
    if (all) cmd = cmd.change(world.getAllReachableFacts());

    Optional<SATFactory> sf = SATFactory.find(solver);
    if (!sf.isPresent()) {
      StringBuilder ids = new StringBuilder();
      for (SATFactory f : SATFactory.getAllSolvers()) ids.append(' ').append(f.id());
      throw new Fail("unknown solver " + solver + "; known:" + ids);
    }
    A4Options opt = new A4Options();
    opt.solver = sf.get();
    opt.noOverflow = true;
    // A litmus run has no skolem relations: their values would make copies of one execution. A pair run keeps
    // them: the skolem of a broken run's `some x: ...` is the event that the broken lowering changes.
    if (!pair) opt.skolemDepth = -1;
    opt.tempDirectory = System.getProperty("java.io.tmpdir");
    opt.originalFilename = file;

    try (PrintWriter out = new PrintWriter(new BufferedWriter(new OutputStreamWriter(
             outFile == null ? new FileOutputStream(FileDescriptor.out) : new FileOutputStream(outFile),
             StandardCharsets.UTF_8), 1 << 16))) {
      return enumerate(world, d, cmd, want, opt, max, check, pair, file, out);
    }
  }

  static int enumerate(CompModule world, AlloyDump d, Command cmd, String want, A4Options opt, long max,
                       boolean check, boolean pair, String file, PrintWriter out) throws Err {
    String name = pair ? want : new File(file).getName().replaceFirst("\\.als$", "");
    String[] heads = pair ? new String[]{"instance " + want + "-p", "instance " + want + "-k", "map " + want}
                          : new String[]{"instance " + name};
    // Every instance must satisfy the facts and the command's formula in the evaluator too; if it does not, the
    // evaluator and the solver disagree (for example on integer overflow) and the dump cannot be trusted.
    Expr facts = world.getAllReachableFacts();
    Expr formula = cmd.formula;

    A4Solution sol = TranslateAlloyToKodkod.execute_command(A4Reporter.NOP, world.getAllReachableSigs(), cmd, opt);
    // Two solutions may differ only in relations the dump does not show; such a copy of a printed execution is
    // skipped (by a digest of its block).
    Set<String> seen = new HashSet<>();
    MessageDigest sha;
    try {
      sha = MessageDigest.getInstance("SHA-256");
    } catch (NoSuchAlgorithmException e) {
      throw new Fail("no SHA-256: " + e);
    }
    long k = 0, copies = 0;
    for (; sol.satisfiable(); sol = sol.next()) {
      Eval ev = new Eval(sol, check);
      if (!ev.truth(facts, "the facts")) {
        StringBuilder which = new StringBuilder();
        for (CompModule m : world.getAllReachableModules())
          for (Pair<String, Expr> f : m.getAllFacts())
            if (!ev.truth(f.b, "fact " + f.a)) which.append(' ').append(m.getModuleName()).append('/').append(f.a);
        throw new Fail("instance " + k + ": the evaluator says these facts are false:" + which);
      }
      if (!ev.truth(formula, "the command's formula"))
        throw new Fail("instance " + k + ": the evaluator says the formula of " + want + " is false");
      String[] bodies = pair ? d.pair(ev) : new String[]{d.litmus(ev)};
      String body = String.join("\u0000", bodies);
      if (!seen.add(Base64.getEncoder().encodeToString(sha.digest(body.getBytes(StandardCharsets.UTF_8))))) {
        copies++;
        continue;
      }
      if (max >= 0 && k >= max) {
        out.flush();
        System.err.println(name + ": " + k + " instances, " + copies + " copies skipped");
        System.err.println("truncated");
        return 3;
      }
      for (int i = 0; i < heads.length; i++) out.print(heads[i] + " " + k + "\n" + bodies[i]);
      k++;
    }
    out.flush();
    System.err.println(name + ": " + k + " instances, " + copies + " copies skipped");
    return 0;
  }

  public static void main(String[] args) {
    int status;
    try {
      status = run(args);
    } catch (Fail f) {
      System.err.println("AlloyDump: " + f.getMessage());
      status = 2;
    } catch (RuntimeException | IOException e) {
      System.err.println("AlloyDump: " + e);
      e.printStackTrace();
      status = 2;
    }
    System.exit(status);
  }
}
