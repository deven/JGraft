# JGraft for Perl — Internal Design (from scratch)

## 0. Context

The Perl implementation of JGraft (`Exec.pm` and its helpers) is not on this
machine; `/home/deven/git/JGraft` holds only `SpecV1.md`, `README.md` and
`conformance/*.json`. This document is therefore a **clean-sheet design**
derived from the spec and the conformance suite, not a refactoring of existing
code. Module and method names are proposals; map them onto the real ones.

Goals, in the user's words: a clean public API, bookkeeping that happens
automatically instead of being repeated in every operation, as few function
calls as possible on hot paths, and no redundant work.

This file is the deliverable. Nothing is implemented. Sections 1–13 are the
design, 14 is the build order, 15 is verification, **16 lists flaws found in
the specification with recommendations**.

Assumptions (change these first if wrong):

- Perl ≥ 5.36 (`builtin::created_as_number`, `is_bool`, signatures). All
  version-sensitive code is confined to `JGraft::Util` (§4) so an older-perl
  shim is a one-file change.
- Pure Perl, core modules only.
- Fuzzy matching and "undo" grafts are out of scope; §13 names the hook points.

---

## 1. The five ideas that remove the bookkeeping

Everything else follows from these. An implementer who keeps them intact can
improvise the rest.

| # | Idea | Bookkeeping it eliminates |
|---|------|---------------------------|
| 1 | **Compile once to closures.** `JGraft->new` walks the graft one time, with the argument context (value / match / sequence / regex / path) known statically, and emits one Perl closure per node. | Per-evaluation op lookup, arity checks, context detection ("is this array an expression or an escaped literal?"), literal type classification, re-validation. |
| 2 | **Static context is compiled in, dynamic context is passed as arguments.** `exact`, `regex`, sequence mode and capture observability are compile-time facts, so they select *which closure is built*. The current node travels as closure arguments. | Runtime flag checks; save/restore of the current node (lexical scoping restores it, even when an error unwinds). |
| 3 | **Data is immutable; writes path-copy.** No container reachable from a namespace is ever mutated unless the run created it and holds the only reference (§7). | Deep clones in `COPY`, cloning the input up front, snapshots for `RAISE`, "is this safe to share" reasoning in every function, isolation of the input from a failed run. |
| 4 | **One declarative op table.** Each op is one table row: id, arity, per-argument context, defaults, flags, builder. A generic `compile_op` does everything common. | Hand-written arity/argument handling per op, implicit-current-node branches (a missing optional operand is replaced *at compile time* by the `NODE` reader). |
| 5 | **Errors are exceptions, trapped only where the compiler proves they can occur.** Soft errors (`INVALID_TARGET`/`INVALID_OPERAND`) thrown under a match are preallocated singletons. | `eval` around every match child, error-object construction during probing, manual error propagation. |

Resource accounting follows the same principle: nothing is counted per
expression node. Counters are touched only where work can grow without bound —
`EXPR` calls and loops whose trip count depends on data (§9).

---

## 2. Public API

```perl
use JGraft;

my $graft = JGraft->new($struct, %compile_opts);   # $struct: decoded JSON, root ["JGRAFT", {...}, ...]
my $out   = $graft->apply($input, %run_opts);      # returns output; dies with a JGraft::Error
my $res   = $graft->run($input, %run_opts);        # never dies for JGraft errors; returns JGraft::Result
```

`$graft` is immutable and reusable; each `apply`/`run` builds a fresh
`JGraft::Exec`. The input is never modified. The output shares unmodified
subtrees with the input (document this; callers who want isolation deep-clone
the result).

Compile options: `strict` (default 1: die with `INVALID_GRAFT` /
`UNSUPPORTED_GRAFT` if static validation recorded any fault; 0: faults fire
only if the faulty node is reached — see §5.6), `max_version` (default 1),
`forbid_proto` (reject `__proto__` property names with `UNSUPPORTED_GRAFT`).

Run options: `limits => { depth, ops, mem, new_obj, prop_per_obj }` (default
`depth => 512`, others unlimited), `on_raise => sub ($record) {...}`,
`temp => {...}` (extension data exposed at the TEMP root),
`date_export => sub ($date) {...}` (default: the `CASTSTR` form),
`allow_inf` (default 0).

`JGraft::Result`: `ok`, `output`, `error`, `logs` (arrayref of
`{level, message, data?}` with numeric level), `partial` (tree as it stood at
failure). `JGraft::Error`: `code` (one of the six spec names), `message`,
`where` (index path of the action inside the graft), `partial`, `logs`;
stringifies to `"CODE: message at /2/1 (COPY)"`.

`$graft->struct` returns the original structure for re-serialisation. There is
no public object model of actions/expressions: the JSON form *is* the model.

---

## 3. Modules

| Module | Responsibility |
|--------|----------------|
| `JGraft` | Facade: `new`, `apply`, `run`, `struct`. ~80 lines. |
| `JGraft::Compiler` | Context-directed compilation: `compile_action/value/match/seq/path`, generic `compile_op`, EXPR cells, constant folding, deferred faults. |
| `JGraft::Ops` (+ `::Action`, `::Ref`, `::Match`, `::Seq`, `::Fn`, `::Math`, `::Split`, `::Round`) | The op table. Each file only *adds rows*; no file calls another op's builder. |
| `JGraft::Exec` | Per-run state, the store (§7), error raising, `charge`. The only module that mutates trees. |
| `JGraft::Seq` | Sequence solver and capture resolution (§11). |
| `JGraft::Util` | Pure functions: `type_of`, `match_lit`, `compare`, `sizeof`, number parse/format, codepoint helpers. |
| `JGraft::Date`, `JGraft::Error`, `JGraft::Result` | Small value classes. |

Dependency direction: `JGraft` → `Compiler` → `Ops::*` → (`Exec`, `Seq`, `Util`).
`Exec` and `Util` depend on nothing else.

---

## 4. Value model (`JGraft::Util`)

| JGraft | Perl representation |
|--------|---------------------|
| null | `undef` |
| boolean | Produced: `$JGraft::TRUE` / `$JGraft::FALSE` (= `JSON::PP::true/false`). Accepted: any class in `%BOOL_CLASS` (`JSON::PP::Boolean`, which `Types::Serialiser` and `Cpanel::JSON::XS` alias) and native booleans (`is_bool`). |
| number | non-ref scalar with `created_as_number` |
| string | any other non-ref scalar; a *character* string (code points, lone surrogates permitted) |
| array / object | unblessed `ARRAY` / `HASH` |
| date, datetime, timestamp | `JGraft::Date`, an immutable blessed array `[kind, y, m, d, h, mi, s, tz]` where `kind` is the type code |
| nonexistent | `$JGraft::MISSING`, a blessed singleton. Internal only; never stored in an output tree. |

```perl
use constant { T_MISSING=>0, T_NULL=>1, T_BOOL=>2, T_NUM=>3, T_STR=>4,
               T_ARR=>5, T_OBJ=>6, T_DATE=>7, T_DATETIME=>8, T_TIMESTAMP=>9, T_OTHER=>10 };
sub type_of {                       # the only place that knows how Perl encodes JSON types
    my $r = ref $_[0];
    return !defined $_[0] ? T_NULL : created_as_number($_[0]) ? T_NUM
         : is_bool($_[0]) ? T_BOOL : T_STR                         if $r eq '';
    return $r eq 'HASH' ? T_OBJ : $r eq 'ARRAY' ? T_ARR
         : $r eq 'JGraft::Date' ? $_[0][0] : ($CLASS_TYPE{$r} // T_OTHER);
}
```

Rules that keep this cheap:

- **Literals in the graft are classified once, at compile time.** A literal
  matcher is a closure specialised for its type, e.g. for a string literal:
  `sub { !ref $_[1] && defined $_[1] && !created_as_number($_[1]) && !is_bool($_[1]) && $_[1] eq $lit }`.
  `type_of` is called at runtime only on *data*.
- `match_lit($value, $pattern, $exact)` is the single recursive routine that
  compares data against a plain value (no expressions inside). It serves three
  callers: fully-literal sub-specs, folded constants, and values returned by
  functions used inside a match. HAS on arrays: `@pattern <= @value` and
  element-wise match; IS: equal lengths. HAS on objects: every pattern key
  exists and matches; IS: additionally equal key counts. Scalars per spec
  "Matching" (numbers `==`, strings `eq`, timestamps by instant).
- `compare($a, $b)` implements LESS (returns -1/0/1 or throws soft error).
- `sizeof($v)` (shallow estimate): string `16 + length`, array `16 + 8n`,
  object `16 + 16n`.
- Use `refaddr`, never `0 + $ref`: boolean objects overload numification.
- `no warnings qw(recursion surrogate)` in every module.

---

## 5. Compilation (`JGraft::Compiler`)

### 5.1 Closure signatures (fixed; every builder returns one of these)

| Kind | Call | Returns |
|------|------|---------|
| value | `$code->($x, $node, $key, $parent)` | a value (§4) |
| match (one element) | `$code->($x, $node, $key, $parent)` | `1` or `0` |
| sequence | `$code->($x, $subj, $pos, $len)` | sorted, duplicate-free **list** of successor positions |
| resolve (capture pass) | `$code->($x, $subj, $start, $end, $len)` | nothing; records captures |
| action | `$code->($x)` | nothing |

`$x` is the `JGraft::Exec`. `$node` is the current node's value or `$MISSING`;
`$key` is its property name / index (or `undef`); `$parent` is its container
(or `undef`). `$subj` is an ARRAY ref, or in regex context a SCALAR ref to the
string. Closures read `$_[1]` directly instead of copying it into a lexical
when they only use it once — copying a large string node is real work.

Descending into a child is just a call with different arguments. Nothing is
saved and nothing needs restoring.

### 5.2 Compile-time context

An immutable hash, derived with `{ %$ctx, exact => 1 }`:

| Field | Meaning |
|-------|---------|
| `exact` | 0 = HAS, 1 = IS. Reset to 0 when a function starts a new match state. |
| `regex` | Subject is a virtual character array. |
| `cap` | Captures are observable (root wants them and no enclosing ANY / NONE / REP in this match state). |
| `scope` | Lexical `JGRAFT` scope: `{ exprs => { name => raw structure }, cells => {} }`. |

Whether a node is compiled as value, match or sequence is decided by *which
compile function is called*, not by a field. The cell-cache signature is
`"$kind,$exact,$regex,$cap"`.

### 5.3 Compile node

Each compile function returns a transient descriptor (discarded once the parent
has built its closure):

```
{ code,          # closure of the kind requested
  resolve,       # sequence kind only, and only if caps
  const, value,  # node is a compile-time constant with this value
  throws,        # may raise a soft error at runtime
  caps,          # may record captures
  depth }        # static nesting depth below this node
```

`throws`, `caps` and `depth` are computed bottom-up by `compile_op` (OR / max
of the children, plus the op's own flag). Builders never set them by hand.

### 5.4 The compile functions

`compile_value($ctx, $s)`:

- scalar, null, boolean → constant node.
- HASH → compile each member. All constant → constant node holding a fresh
  hash. Otherwise a closure that copies a prebuilt template of the constant
  members and fills in only the dynamic ones.
- ARRAY, empty → fault `INVALID_GRAFT`.
- ARRAY of exactly one ARRAY (escaped literal) → as HASH, element-wise.
- other ARRAY → `compile_op`; `$s->[0]` is an op name or numeric ID. A match op
  met here is compiled as a **match root** (§8) wrapped to return
  `$TRUE`/`$FALSE`, with `exact => 0, regex => 0, cap => 0`.

`compile_match($ctx, $s)` (one element):

- No expression anywhere inside `$s` → constant; the matcher is one call to
  `match_lit($_[1], $const, $exact)` (scalars get the specialised closure of §4).
- HASH → object matcher. Children are compiled with the same `exact`, and
  `regex => 0`. Literal scalar members are compared inline in the object
  matcher's loop (no call per leaf); other members are closures called with
  `($x, exists $n->{$k} ? $n->{$k} : $MISSING, $k, $n)`. In `exact` mode count
  the spec keys that exist in the data and compare with `keys %$n`.
- escaped ARRAY → array spec (§10).
- match op → its builder. Reference op other than EXPR, or function op →
  `compile_value`, then wrap: `match_lit($_[1], $value_code->(@_), $exact)`.
- EXPR → cell call (§5.5).

`compile_seq($ctx, $s)`: sequence-aware ops (SEQ, REP, ANY, ALL, NONE, START,
END, WITH, 2-argument HAS/IS, EXPR; SEQMAX/SEQMIN only as a top-level item)
use their sequence builders. Anything else is compiled with `compile_match` and
adapted — one element consumed:

```perl
# array subject                                    # regex subject (node = code point)
sub { $_[2] < $_[3] && $m->($_[0], $_[1][$_[2]], $_[2], $_[1]) ? $_[2]+1 : () }
sub { $_[2] < $_[3] && $m->($_[0], ord substr(${$_[1]}, $_[2], 1), $_[2], $_[1]) ? $_[2]+1 : () }
```

In regex context literals are specialised instead of adapted: a one-character
string → `substr(${$_[1]}, $_[2], 1) eq $c`; a non-negative integer → `ord(...)
== $n`; a string of any other length → `substr(${$_[1]}, $_[2], $L) eq $lit ?
$_[2]+$L : ()` (one closure for the whole run, the implicit SEQ); anything else
→ fault. Runtime values in regex context follow the same rules with a soft
`INVALID_OPERAND`.

`compile_path($ctx, $s, %allow)` → `{ ns, elems }`. A non-array `$s` is
`[NODE, $s]`. Literal elements are validated and classified now (string key /
index / negative alias / `false` / half-index where allowed); `null` or `true`
→ fault. If every element is literal the node carries a ready `keys` array and
readers of 1 or 2 keys get unrolled closures. Namespace rules (leading integer
coerced to string for CONST/EXPR/STASH/TEMP, TEMP needs ≥ 1 element, which
namespaces are writable) are checked here, once.

`compile_action($scope, $s)` → action closure via the action rows of the table.

### 5.5 The op table and `compile_op`

One row per op, for example:

```perl
CONCAT => { id => 58, kind => 'fn',    args => 'V+',     pure => 1, throws => 1, build => \&b_concat },
LENGTH => { id => 55, kind => 'fn',    args => 'V?',     pure => 1, throws => 1, build => \&b_length },
NUM    => { id => 9,  kind => 'match', args => 'V? V?',  throws => 1,           build => \&b_num },
CASE   => { id => 66, kind => 'fn',    args => '(M V)+ V?', throws => 1,        build => \&b_case },
```

Argument letters: `V` value, `M` match, `R` regex (sequence in regex context),
`P` path, `L` raw literal, `A` action, `X` handled by the builder itself (used
only by SPLIT/JOIN spec, CHARS, WITH/LOCAL names, ROUND options). Suffixes `?`
`*` `+`, and `( )` for repeating groups.

`compile_op($ctx, $kind_wanted, $s)` does, for every op:

1. Look up the row by name or ID (two hashes built at load). Unknown, or wrong
   kind for the position (action vs expression) → fault.
2. Check arity against `args` → fault.
3. Compile each argument with the function its letter names. A missing `V?`
   operand documented as "defaults to the current node" is replaced by the
   shared `NODE`-reader node, so builders have no arity branches.
4. Compute `throws`, `caps`, `depth`.
5. If the row is `pure` and all arguments are constant, **fold**: run the built
   closure once against a scratch `Exec` with a small budget (ops 10 000, mem
   64 KiB). Success → constant node. Any exception (including the budget) →
   keep the closure, so the error surfaces at runtime with normal semantics.
6. Otherwise call `build->($compiler, $ctx, @arg_nodes)` and wrap the result.

**EXPR cells.** `[EXPR, name]` with a literal name resolves at compile time to
a cell `{ scope, name, sig, code => undef }` cached in `scope.cells` under
`"$name\0$sig"`. Unknown literal name → fault. The cell body is compiled
**lazily on first call** (recursion and unused definitions are therefore
free), in the caller's context: if the definition's root is a match op it is
compiled with `compile_match`/`compile_seq` under the caller's
`exact/regex/cap`; otherwise with `compile_value`, wrapped as a literal matcher
when the caller is matching. The call site:

```perl
sub { my $x = $_[0];
      --$x->{ops} >= 0 or $x->limit('ops');
      local $x->{depth} = $x->{depth} + $site_depth + 1;
      $x->{depth} <= $x->{max_depth} or $x->limit('depth');
      ($cell->{code} //= $self->compile_cell($cell))->(@_) }
```

A computed name evaluates the name (string or integer, else soft
`INVALID_OPERAND`), looks the cell up in the captured `scope`, then proceeds
identically. Callers assume an EXPR node has `throws => 1`, `caps => $ctx->{cap}`.

`peek_op($scope, $s)` follows literal-name EXPR chains (with a visited set) and
returns the root op name without compiling. It is used wherever the spec says a
rule applies "after replacing common subexpression references" (§10).

### 5.6 Faults (`INVALID_GRAFT`, `UNSUPPORTED_GRAFT`)

Compile functions never die. `$self->fault($code, $s, $msg)` appends to
`$graft->{faults}` and returns a **poison node** whose closure throws that
(fatal) error when executed. `new` dies with the first fault when `strict`;
otherwise the fault fires only if reached. One mechanism therefore provides
both the eager validation the spec encourages and the lazy behaviour it
permits, and no builder needs exception plumbing. Faults inside lazily compiled
cells always fire at first use.

---

## 6. Runtime state (`JGraft::Exec`)

A hash. Fields: `root` (node-namespace root value), `at` (arrayref of keys from
`root` to the current node), `node`/`nkey`/`nparent` (cached current node for
actions), `const`, `stash`, `temp`, `cap` (namespace roots), `caps`/`capturing`/
`path` (capture pass, §11), `ops`/`mem`/`objs` (countdowns), `depth`,
`max_depth`, `quiet`, `moving`, `owned`, `side`, `dates`, `logs`, `where`,
`opts`.

Actions evaluate an expression as
`$code->($x, $x->{node}, $x->{nkey}, $x->{nparent})`.

Scoped changes that are rare use `local` on the field so they unwind
automatically: `const`/`stash` (JGRAFT), `cap` (MATCH/IF), `temp`
(WITH/LOCAL/REDUCE and per COPY/MOVE action), `root`/`at` (AT, ATSPLIT),
`depth` (EXPR), `quiet` (trap). None of these is on the per-element path.

TEMP overlays: `local $x->{temp} = { %{ $x->{temp} } }`, then assign each
binding into that private hash in order (later value expressions see earlier
bindings). REDUCE makes one overlay for the whole loop and overwrites the
accumulator slot each iteration.

---

## 7. The store: immutable trees with ownership

### 7.1 Rules

1. A container may be mutated in place only if it is **owned**:
   `$x->{owned}{ refaddr $c }` exists. The stored value is the container
   itself, which keeps it alive so its address cannot be reused.
2. Only `clone` creates owned containers. Input data, constants and values
   built by expressions are never owned.
3. `clone($c)`: shallow copy; **delete every child container's address from
   `owned`**; copy the split record and move the pending-MOVE record in
   `$x->{side}` (§7.3); register the copy as owned; `charge` its size.
4. `escape($v)`: `delete $x->{owned}{ refaddr $v } if ref $v`. Every reference
   expression read in value context calls it on its result. Since all operands
   arrive through compiled argument closures (including the implicit-node
   default), this is automatic; the one manual call is SLICE's config-object
   `path` form.

Invariant: *a container is uniquely referenced iff it and all of its ancestors
are owned.* Rule 4 un-owns a container the moment a second reference may be
created; rule 3 un-owns the children that the old and new copies now share.
Stale `owned` marks deeper down are harmless because a write reaches them only
through an un-owned ancestor, which rule 3 clears first.

Consequences: `COPY` stores a reference (O(1)); `RAISE` data is a snapshot for
free; repeated writes into the same array (the diff-hunk workload) mutate in
place after the first clone; the input is never touched.

### 7.2 Primitives

```perl
# Make the containers along keys[0..$n-1] owned, vivifying where allowed, and
# return the container that keys[$n] indexes.  $slot is \$x->{root}, \$x->{stash} or \$x->{temp}.
sub own_path ($x, $slot, $keys, $n) {
    my $c = $$slot = $x->own($$slot, $keys->[0]);           # type-check against key kind, clone unless owned
    for my $i (0 .. $n - 1) {
        my $k     = $x->index_for($c, $keys->[$i], 1);      # resolve -n / false, bounds; soft INVALID_TARGET
        my $child = ref $c eq 'HASH' ? (exists $c->{$k} ? $c->{$k} : $MISSING)
                                     : ($k < @$c ? $c->[$k] : $MISSING);
        $child = ref $child eq 'JGraft::Missing'
               ? $x->vivify($keys->[$i + 1])                # [] for index-like key, {} for string; registered owned
               : $x->own($child, $keys->[$i + 1]);
        ref $c eq 'HASH' ? ($c->{$k} = $child) : ($c->[$k] = $child);
        $c = $child;
    }
    return $c;
}
```

`own` fails with `INVALID_TARGET` if the value is not the container type the
next key requires (string key ⇒ HASH, index-like ⇒ ARRAY): the spec forbids
converting types. `index_for` on write accepts `0..len` (`len` = append),
`-n` ⇒ `len-n ≥ 0`, `false` ⇒ `len`; a slot holding `$MISSING` (a MOVE
tombstone) counts as nonexistent.

Everything that writes is built on it:

- `put($x, $slot, $keys, $v)` — COPY. Empty `$keys`: allowed only for the node
  namespace (`$x->{root} = $v`). Otherwise `own_path` to the parent, then
  assign.
- `take($x, $slot, $keys)` / `attach(...)` — MOVE (§12).
- `splice_at($x, $slot, $keys, $count, \@repl)` — SPLICE.

Node-relative paths use `$slot = \$x->{root}` and keys `[@{$x->{at}}, @rel]`.
After any node-namespace write, `refresh_node` re-walks `at` from `root` to
reset `node/nkey/nparent`; AT and ATSPLIT call it on exit. Values stored into
the node namespace pass through `export_dates` only when `$x->{dates}` (count
of `JGraft::Date` objects created this run) is non-zero.

Reads need no primitive: compiled path readers walk with plain dereferences,
check key kind against container type at each step (soft `INVALID_TARGET` on
mismatch, missing key, or `$MISSING` value), honour date virtual properties,
and finish with `escape`.

### 7.3 Side records

`$x->{side}{ refaddr $array } = { a => $array, split => {...}, pend => {...} }`
exists only for arrays carrying SPLIT metadata or pending MOVE operations.

- `split`: `{ origin, sep => [...], ltrim => [...], rtrim => [...] }`, arrays
  parallel to the data (absent arrays mean "not tracked"). `origin` is a token
  unique to one SPLIT evaluation.
- `pend`: `{ del => { idx => 1 }, ins => { "1.5" => [[value, meta], ...] } }`.

Every array-producing function checks `%{ $x->{side} }` once and skips all
metadata work when it is empty — the normal case.

---

## 8. Errors and trapping

`$x->fail_target($fmt, @args)` and `$x->fail_operand(...)` are the only ways
ops raise soft errors. If `$x->{quiet}` they `die` a preallocated singleton
(no allocation, no formatting); otherwise they build a full `JGraft::Error`
with `where`. `$x->fail_no_match`, `$x->limit($which)`, and poison nodes raise
fatal errors. Foreign exceptions propagate untouched and end the run.

Soft errors propagate to the nearest of: an ANY / NONE argument, or the root of
the current match state. Those are the only trap sites:

```perl
sub trap ($node) {                        # compile-time helper
    my $code = $node->{code};
    return $code unless $node->{throws};  # provably cannot fail: no eval at all
    sub { local $_[0]{quiet} = 1;
          my $r; return $r if eval { $r = $code->(@_); 1 };
          die $@ unless ref $@ && $@->{soft};
          0 } }
```

`trap_seq` is the same for sequence closures, returning `()` on a soft error.
Because `throws` is false for literals, type tests, CHARS and structures of
them, the common `[ANY, "a", "b"]` compiles without a single `eval`.

**Match roots** (new match state: `exact => 0`, not sequence, trapped): MATCH
and IF conditions (with `cap => 1`), CAPTURE's argument (`cap => 1`), CASE
conditions, FILTER's predicate, and any match op compiled by `compile_value`.
A root compiled with `cap => 1` whose node has `caps` true is wrapped to set
up `local $x->{caps} = {}; local $x->{capturing} = 1; local $x->{path} = []`
and return the captures hash or `undef`; when `caps` is false it returns a
shared empty hash on success and sets nothing up.

Ordering: evaluate arguments left to right and raise the first error, except
where the spec fixes an order (SPLIT/JOIN validate `split_spec` before the
input).

---

## 9. Resource accounting

Counters are countdowns initialised from the limits (`9**9**9` when
unlimited), so a check is one subtraction and one comparison.

- **depth** — static. `compile_op` records each node's nesting depth. Runtime
  touches it only at EXPR call sites (§5.5) and once per action:
  `$max_static_depth_of_my_args <= $x->{max_depth} or $x->limit('depth')`.
  Unbounded recursion is possible only through EXPR, so this is complete.
- **ops** — `--$x->{ops}` per EXPR call; `$x->charge($n_ops, $n_bytes)` once
  per data-proportional loop with its trip count (clone, CONCAT, SLICE, MAP,
  FILTER, REDUCE, SPLIT, JOIN, PROPS, MKOBJ, `match_lit` on containers, each
  sequence-engine frontier step). Never per expression node: work not covered
  by these is bounded by the size of the graft.
- **mem** — the same `charge` call, with `sizeof` of what was produced.
- **new_obj / prop_per_obj** — `$x->charge_obj($n_props)` wherever a container
  is created or an object gains a key.

---

## 10. Structural matching

Object specs: §5.4. Array specs (`[[...]]`, and ARRAY with match arguments)
have two modes, chosen at compile time by `peek_op` on each top-level item:

**Plain mode** (no top-level item is SEQ / SEQMAX / SEQMIN): item `i` is an
element matcher applied to element `ofs + i`; index `== length` is matched
against `$MISSING`; index `> length` fails. `exact` additionally requires
`length == ofs + items`. Literal scalar items are compared inline.

**Sequence mode** (any top-level item is SEQ-family): all top-level items are
compiled with `compile_seq` and handed to the solver (§11). `exact` becomes the
end condition "final position == length".

ARRAY: no arguments → type test; one → length test (`>=`, or `==` when
`exact`); more → an array spec starting at `offset` (negative counts from the
end; out of range is simply false) whose end condition is never exact.

Mode with computed EXPR names at top level: the static items decide. If none
is SEQ-family the array is plain mode, and a computed name that resolves to a
SEQ-rooted definition raises `INVALID_GRAFT` when its cell is compiled. (A
dual-mode array spec that decides per evaluation is possible later; verify
against `16-jgraft-namespaces.json` before investing.)

SEQ / SEQMAX / SEQMIN / REP reached by `compile_match` (element position) are
faults: `INVALID_GRAFT`, matching the conformance suite.

---

## 11. Sequence engine (`JGraft::Seq`)

### 11.1 Successor closures (boolean; the hot path)

Every sequence item is a closure `($x, $subj, $pos, $len) → positions`.
Combinators never look at `$subj`; only leaves do, so arrays and strings share
one engine.

| Item | Successors from `p` |
|------|--------------------|
| element matcher `M` | `p+1` if `p < len` and `M` accepts element `p` |
| SEQ(a, b, …) | frontier: `cur = {p}`; for each item `cur = ⋃ item(q), q ∈ cur`; stop early when empty |
| ANY(a, …) | union of `trap_seq(arg)(p)` |
| NONE(a, …) | `p` if every `trap_seq(arg)(p)` is empty |
| ALL(a, …) | `Sᵢ = argᵢ(p)`; none empty; `lo = max(min Sᵢ)`; result `{ q ∈ ⋃Sᵢ : q ≥ lo }` |
| REP(min, max, b) | frontier per count `k`; collect when `k ≥ min`; stop at `max`, on an empty frontier, or (unbounded) when a frontier adds no unseen position |
| START / END | `p` if `p == 0` / `p == len` |
| 2-argument HAS/IS | `p` if the element match on the given value succeeds |
| WITH | body's successors, evaluated under the TEMP overlay |

Sets are deduplicated with a small hash and returned sorted. Each frontier step
calls `charge(scalar @cur, 0)`. REP bounds are evaluated once per REP
invocation; `max == 0` means `min`, `-1` means unbounded.

### 11.2 The boundary solver

`solve($x, \@items, $subj, $len, \@starts, $end_exact, \@objectives)` returns
the boundary vector `b[0..m]` (item `i` spans `b[i-1] .. b[i]`) or nothing.

- `S[i]{p}` memoises `items[i]{code}->($x, $subj, $p, $len)` for this solve.
- `feasible(constraints)`: forward sets `F[0] = starts`,
  `F[i] = { q ∈ S[i](p) : p ∈ F[i-1] }`; `B[m] = { q ∈ F[m] : !$end_exact || q == len }`;
  backward `B[i-1] = { p ∈ F[i-1] : S[i](p) ∩ B[i] ≠ ∅ }`. Constraints
  (`b[j] == v`, `len(i) == L`) filter both passes.
- No objectives (boolean): forward pass only; succeed iff some `F[m]` member
  meets the end condition. An unanchored STR search is the same single pass
  with `starts = 0..len`.
- With objectives: for each in order, compute its candidate values from `B`,
  keep the best, add it as a constraint, recompute. Finally read off the
  boundaries left to right, taking the smallest feasible value for any left
  free.

Objectives for an array spec, in order (spec "Sequence Matching" priorities):

1. `MIN b[0]` for an unanchored STR; `MAX/MIN b[m]` if an overall preference was requested.
2. For each SEQMAX / SEQMIN item in order: `MAXLEN(i)` / `MINLEN(i)`.
3. For each of those in order: `MINSTART(i)`.
4. For each other item with `caps` in order: `MINSTART(i)`.

Longest-match users that need only an end position (SPLIT `sep`, `ltrim`,
`rtrim`, `element`) skip the solver: `max` of one successor call.

### 11.3 Captures: match first, extract afterwards

An array spec compiled with `cap => 1` and `caps` true has two code paths
selected by the runtime flag `$x->{capturing}`:

- **off** → boolean solve, no objectives, nothing recorded.
- **on** → solve with objectives, then for each item call
  `resolve($x, $subj, b[i-1], b[i], $len)` with `capturing` still on. While the
  solver itself runs, `local $x->{capturing} = 0`, so element matchers probed
  at many positions never record anything.

`resolve` per item kind:

| Item | Action |
|------|--------|
| SEQMAX / SEQMIN | evaluate the name (node = `$MISSING`; `null` → unnamed; integer coerced; else soft `INVALID_OPERAND`); record `{ path => [@{$x->{path}}], ofs, len, lim }` in `$x->{caps}`, duplicate name → soft `INVALID_OPERAND`; then resolve the body as SEQ |
| SEQ | `solve` the body between the fixed start and end with objectives `MINSTART(i)` for each `caps` item in order; resolve each item |
| ALL | for each argument `eᵢ = max { q ∈ Sᵢ(start) : q ≤ end }`; resolve it over `start..eᵢ` |
| element matcher with `caps` | `push @{$x->{path}}, $pos`; re-run the matcher on that element; `pop` |
| WITH | resolve the body under the overlay |
| ANY, NONE, REP, others | nothing (captures suppressed) |

Object and plain-mode array matchers with a `caps` child push/pop the key
around that child only when `$x->{capturing}`. A 2-argument HAS/IS rebases:
`local $x->{path} = []`.

Cost: an element matcher at nesting depth *d* runs at most *d* times boolean
plus once capturing. Specs compiled with `cap => 0`, or with no capture
producer, contain none of this code.

### 11.4 Regex specifics

STR with an argument and SPLIT patterns compile their argument with
`compile_seq` under `regex => 1`. The subject is `\$string`; positions are
character indices; `length($$subj)` is the length. Element matchers that are
not regex-specialised see the **code point as an integer** node with
`key = pos`, `parent = $subj` (this is what the conformance suite expects —
see §16 item 6). A 2-argument HAS/IS, or a function that rebinds the current node,
compiles its inner spec with `regex => 0`. LOCAL with a *computed* `prop` in
regex context compiles its body in both variants lazily and picks at runtime
according to whether a `null` prop was seen.

CHARS compiles to a sorted range list plus a prebuilt `qr/[...]/`; literal-name
EXPR members are merged at compile time (must `peek_op` to CHARS, else fault).

Optional later optimisation, isolated behind `compile_seq`: when a
**boolean** regex subtree consists only of characters, CHARS, strings, SEQ,
ANY, START, END and REP whose body is a single-character matcher, translate it
to a native `qr//` and charge `length × items` ops up front. Existence is
insensitive to leftmost-longest versus Perl's ordering, so this is exact; do
not extend it to longest-match or capturing contexts.

---

## 12. Actions

All action builders set `$x->{where}` first (one assignment; used only by
error reports), then:

- **JGRAFT** — compile time: check `v` (too new → `UNSUPPORTED_GRAFT`), create
  the child scope from `expr` pairs (raw structures, not compiled). Run time:
  if `const` is present, `local $x->{const} = { %{$x->{const}} }` and evaluate
  each pair in order into it (the stash is still the parent's here); then
  `local $x->{stash} = $EMPTY` (a shared unowned empty hash — the first write
  clones it); run sub-actions.
- **RAISE** — level validated at compile. Evaluate message (must be a string
  without surrogates, noncharacters or controls: soft `INVALID_TARGET`;
  literal → fault) and data; push the record; call `on_raise`; level 2 →
  `fail_no_match`.
- **AT** — resolve the path, verify it exists; `local $x->{at} = [@at, @keys]`;
  `refresh_node`; run sub-actions; `refresh_node` after the `local` unwinds.
- **ATSPLIT** — resolve path and `split_spec` once; SPLIT the target into a
  fresh array; `local $x->{root} = $array; local $x->{at} = []`; run
  sub-actions; JOIN `$x->{root}`; after unwinding, `put` the string at the
  saved keys.
- **MATCH** — `my $caps = $root->(...) or $x->fail_no_match;
  local $x->{cap} = $caps;` run sub-actions.
- **IF** — for each (condition, action): on captures returned,
  `local $x->{cap}` and run that action, then stop. A trailing single action
  is the else branch and sees the inherited `cap`.
- **COPY** — if any destination is TEMP (known statically),
  `local $x->{temp} = $x->{opts}{temp} // $EMPTY`. Per pair: evaluate, resolve
  destination keys, `put`.
- **SPLICE** — resolve keys; the last must address an element or the append
  position of an array; normalise `count` (negative: `(len - N) - ofs`; null:
  `len - ofs`; must lie in `0 .. len - ofs`); evaluate all replacements;
  `own_path`; `splice` in place; splice the split record in parallel.
- **MOVE** — `local $x->{temp}` as COPY; `$x->{moving}++`; run the pairs inside
  `eval`; **finalise**; `$x->{moving}--`; rethrow. Per pair:
  1. Resolve both key lists.
  2. `take`: `own_path` to the source's parent; object → `delete`; array →
     store `$MISSING` in the slot and note the index in `pend.del`, carrying
     the element's split metadata with the value. Source `null` → value is
     null, nothing detached. Source is the current node itself → store
     `$MISSING` in its slot and set a "vacant" flag.
  3. `attach`: destination `null` → drop. Object key → assign. Array index
     holding a live element → overwrite, keeping the destination's metadata.
     Slot holding `$MISSING` → assign and cancel the pending deletion (an
     insert, for metadata purposes). Index `== len` or `false` → `push`
     immediately. Half-index `h` (final key only): negative `h` other than
     `-0.5` becomes `len + h`; valid range `-0.5 .. len - 0.5`; queue in
     `pend.ins{h}`.
  4. If `attach` throws, put the value back at the source and rethrow, so a
     failed pair leaves no trace.

  Finalise: for each array with a `pend` record (found through `side`, wherever
  the array now lives — it is owned, so in-place rebuild is safe): emit
  `ins{-0.5}`, then for each index its live element followed by `ins{i+0.5}`;
  rebuild the split arrays identically, then give metadata-less arrivals
  "adjacent element metadata"; drop the record. Then fail with
  `INVALID_TARGET` if the current node is still vacant.

  While `$x->{moving}`, bulk array functions (SLICE, CONCAT, MAP, FILTER,
  REDUCE, JOIN) scan *their span* for `$MISSING` and raise soft
  `INVALID_TARGET`; path reads already reject it.

---

## 13. Function notes and extension points

The spec is the reference for each function's semantics; only the points where
this design changes how they are written are listed.

- Functions never test "was the operand given"; the default is compiled in.
- Functions never clone their results or inputs. Returning an element of an
  input array, or the input itself, is always legal.
- MAP / FILTER / REDUCE call their callback closure as
  `$cb->($x, $elem, $i, $array)` — the rebinding of the current node is the
  argument list. FILTER's predicate is a trapped match root.
- LOCAL with prop `null` evaluates its tail as `$tail->($x, $value, undef, undef)`.
- SPLIT resolves `sep` at compile time when it is a literal string (`index`
  loop, no metadata unless trimming is kept); a match-rooted `sep` is a regex
  successor closure driven by "longest end at each position". It creates a
  side record only when separators vary or trimmings are kept.
- CASTDATE increments `$x->{dates}`.
- POW with two integers: exact via `Math::BigInt`, returned as a native integer
  when it fits; otherwise floating point, with overflow/underflow →
  `UNSUPPORTED_GRAFT`. ROUND works on decimal digit strings throughout.
- Every arithmetic result passes through one `num_out` check (NaN → soft
  `INVALID_TARGET`; ±Inf → `UNSUPPORTED_GRAFT` unless `allow_inf`).

Hook points for features left out: **undo** — record inverse operations in
`put` / `take` / `attach` / `splice_at`, the only mutators. **Fuzzy matching**
— an `alter` field in side records consulted by `index_for`, set by a retry
loop in the MATCH/IF builders. **Source generation** instead of closures —
replace builders one row at a time; signatures stay the same.

---

## 14. Build order

Each step ends with the listed conformance files passing.

1. `Util` (types, `match_lit`, `sizeof`), `Error`, `Result`, `Exec` skeleton
   with `charge`/`fail_*`. Unit tests only.
2. `Compiler` core: `compile_value`, `compile_path`, `compile_op`, faults,
   folding; refs NODE/CONST/STASH/TEMP; actions JGRAFT, AT, COPY; store
   `own_path`/`put`. → `01-copy`, `16-jgraft-namespaces` (non-EXPR parts).
3. `compile_match`, object and plain array specs, HAS, IS, ANY, ALL, NONE,
   EXISTS, type tests, NUM, `trap`; MATCH, IF, RAISE. → `04`, `05`, `08`–`10`,
   `37`.
4. EXPR cells, depth/ops limits, WITH, LOCAL, CASE, FAIL, AND/OR/NOT, CURPROP.
   → rest of `16`, `22`–`25`, `29`, `33`.
5. Sequence closures and boolean solver; SEQ, REP, START, END, ARRAY.
   → `11`–`14`, `17`, `35`.
6. Regex context, STR, CHARS. → `26` and the regex groups of earlier files.
7. Capture pass, CAP, CAPTURE, SEQMAX/SEQMIN. → `36`, capture groups elsewhere.
8. LENGTH, SLICE, CONCAT, MAP, FILTER, REDUCE, PROPS, MKOBJ, casts, LESS, math,
   ROUND, dates. → `06`, `07`, `18`–`21`, `27`, `28`, `30`–`32`, `34`, `38`–`40`.
9. SPLICE, MOVE with pending operations. → `02`, `03`.
10. SPLIT, JOIN, ATSPLIT, side records. → `15`, metadata groups of `02`, `03`, `07`.

---

## 15. Verification

`t/conformance.t` runs every leaf case in `conformance/*.json`:

- **Decoding.** `JSON::PP` and `Cpanel::JSON::XS` both reject the lone
  surrogate escapes present in 23 of the 40 files (confirmed here). Before
  decoding, replace each *unpaired* `\uD8xx`–`\uDFxx` escape (respecting
  backslash parity) with a two-character marker `\uFDD0` + a private-use
  character encoding the surrogate; after decoding, walk all strings and hash
  keys and substitute `chr($surrogate)`.
- **Outcome.** A case passes if the run failed with a code listed in `errors`,
  or succeeded and `output` exists and is deeply equal (compare with
  `match_lit(..., 1)` in both directions, so number/string/boolean identity is
  checked). `logs`, when present, must equal `$res->logs` unless the run failed
  with `INVALID_GRAFT`.
- **Limits.** Pass `limits` through; cases without `limits` run with defaults
  and must never report `RESOURCE_LIMIT`.
- **Both validation modes.** Run the whole suite with `strict => 1` and
  `strict => 0`; both must pass. A case that passes lazily but fails strictly
  means static validation flagged something the spec allows.
- `needProto` cases run normally in Perl; run them again with
  `forbid_proto => 1` expecting `UNSUPPORTED_GRAFT`.

Design-specific unit tests:

- Input immutability: deep-snapshot the input, apply every conformance graft,
  compare afterwards.
- Ownership: `COPY [NODE,'a'] → 'b'`, then write under `a`, assert `b`
  unchanged; the same through SLICE, MAP, FILTER, STASH and RAISE data.
- In-place reuse: 1 000 SPLICEs on one 10 000-element array perform exactly one
  array clone (count `clone` calls).
- Trap elision: compiling `[ANY, "a", "b"]` yields a node with `throws` false.
- Folding: `[COPY, {x:[ADD,1,2]}, 'a']` compiles its value to a constant;
  `[ROUND, {as:"STR", at:1000000}, "1"]` does not fold and does not stall `new`.

---

## 16. Flaws found in the specification, with recommendations

Line numbers refer to `SpecV1.md` unless another file is named. "Suite" means
the behaviour the conformance tests currently assert.

### Incorrect or stale

1. **`README.md` 51–64, first example.** Uses `SPLIT` as an action (renamed
   `ATSPLIT`), omits the `path` argument, and ends with a trailing comma.
   → `["ATSPLIT", ["NODE"], "\n", ["MATCH", ["ARRAY", 9, ...], ["SPLICE", 10, 2, "New Line eleven"]]]`.
2. **`README.md` 81–84, second example.** `["MOVE",0,3]` *overwrites* element 3
   whenever the array has more than three elements (MOVE table, 1230–1245), and
   the example shows trailing `...` records. It is only correct for exactly
   three. → `["MOVE", 0, 2.5]`.
3. **1049–1063, ATSPLIT example.** `[ARRAY, 10, "Line ten", …]` and
   `[SPLICE, 11, 2, …]` are off by one against the README's (correct) 0-based
   9 / 10, and the example has a trailing comma.
4. **`conformance/README.md` 15–21.** The `errors` schema omits
   `UNSUPPORTED_GRAFT`, which 31 cases use. Lines 50–53 are garbled ("produce
   the `output` or if one is specified for the test").
5. Typos: "anaysis" (`conformance/README.md` 31), "can described" (2746),
   "caluclation" (2675), "precsion" (2769).

### Underspecified — the suite decides, the text does not

6. **Value of a virtual character (105–122, 592–601).** The text says how
   literals match characters but not what `[NODE]`, `CASTSTR` or `NUM` see.
   Suite (`26-chars`, "Computed names depend on current character"): an
   **integer code point**. → State it: the virtual array's elements are
   integers; one-character strings are literal sugar.
7. **Where a trapped error lands (810–823).** "Convert them to simple
   failed-to-match conditions" does not say *which* expression becomes false.
   Suite is consistent with: the error propagates to the nearest ANY / NONE
   argument, else fails the whole match state. → Say so. As written,
   `[REP, 0, -1, <erroring body>]` could mean "matches zero times" or "match
   fails". (Corrected after implementing: `14-rep` does cover this — a failing
   body ends the repetition and earlier counts stand, so REP's body is a third
   trap site. See §17.)
8. **ALL capture merging (1596–1598).** "Nearest" is ambiguous, and the spec's
   own example (successors 1, 3, 7; output 2) is a tie between 1 and 3. Suite:
   the **greatest successor not beyond** the output position. → Reword.
9. **Error class of context violations (506–516, 1837).** REP outside sequence
   context, SEQ initiating elsewhere than an array root, and SEQMAX/SEQMIN off
   the top level are called "illegal" / "may only" with no error named. Suite:
   `INVALID_GRAFT`. → Name it. Likewise an empty array `[]` in value or match
   context is never declared invalid.
10. **SPLIT `origin` (2284–2286).** Never defined. Suite (`02-move`, "Different
    SPLIT origins…"): two ATSPLITs with identical specs on different strings
    are different origins. → Define origin as one SPLIT evaluation, and say
    whether JOIN may use metadata from an origin other than its own spec's.
11. **Resource limits.** `depth`, `ops`, `mem`, `new_obj`, `prop_per_obj`
    appear only in `conformance/README.md` 22–28 with one-line glosses, yet
    cases require e.g. `ops: 500` to trip on a single CONCAT of ~1 000
    elements — i.e. per-element counting. → Add a short normative model: what
    one "op" minimally covers, and that `depth` is the number of `EXPR`
    calls in progress at once. (Revised after implementing. This entry first
    recommended counting all expression nesting, through EXPR expansion.
    Counting calls is the better rule: only EXPR can recurse, nesting written
    out in a graft is bounded by the graft, a count of calls does not change
    when an expression is moved into a definition, and it agrees with the
    suite's own gloss, "maximum recursion depth of any expression". Every
    case in the suite that sets `depth` is EXPR recursion, so the suite
    passes under either rule and the spec has to choose.)
    `new_obj` and `prop_per_obj` have no cases in the suite at all, and their
    glosses leave open what this implementation had to decide (§17): whether
    an implementation's internal copies are "new objects" (here: no, only
    arrays and objects made as values, so that the count does not depend on
    how an implementation shares data); whether "properties added to any one
    object" counts additions or the resulting size (here: the size, checked
    when an object is made or gains a property); and whether constants in
    the graft count (here: no). → Define both, and add cases.
12. **TEMP lifetime (212–216).** "For the duration of one action" does not say
    whether sub-actions of AT / MATCH / IF share it. Suite: each COPY / MOVE
    starts empty. → State that every action execution starts with an empty
    TEMP and nothing is inherited.

### Ambiguous and untested — a decision is needed

13. **STR under IS (1673–1677 versus 401–404, 1800–1805).** IS implies `[END]`
    for arrays; nothing says whether an IS-context STR regex is anchored. The
    suite always writes explicit `[START]…[END]`. → State that STR is never
    implicitly anchored. (This design assumes so.)
14. **Sequence mode changes the meaning of sibling items (405–410, 498–504).**
    Whether an array literal is matched positionally or as a sequence depends
    on whether *any* top-level item is SEQ-family, and NONE / ANY / ALL change
    meaning accordingly: `[[ [NONE,5], 2 ]]` matches `[1,2]`, but adding an
    unrelated `[SEQ]` item makes NONE zero-width and the match fails. No test
    covers a logical op beside a SEQ at top level. → Either confirm and
    document this prominently with an example, or make sequence mode explicit.
    **Answered by the spec's author: a `[SEQ]` does not alter the items
    beside it.** Only an item that is itself SEQ / SEQMAX / SEQMIN is in
    sequence context; the others are what they would be with no sequence in
    the array. The implementation now does this (§17), and the spec's
    sentence at 405–410, "if sequence context is involved with any element
    of the array, the array match is handled according to the rules
    described in sequence matching", should be rewritten to say it: as it
    stands it reads as putting the whole array in sequence context.
15. **Element matchers at position == length in sequence context (422–424).**
    Positional matching lets an item match the nonexistent element at
    `length`; sequence context says an item "consumes one element" without
    saying it cannot do so there. → State that nothing consumes at `length`.
    (Assumed here, and still so *inside* a sequence. But by the author's
    answer to item 14, an item beside a sequence is a positional item, and so
    can be matched against the nonexistent element at `length`, once, as it
    could with no sequence there. The suite relies on it:
    `[[ [SEQ, ...], [END] ]]` in `11-seq-any`. The spec should say what may
    follow such an item; here, only a sequence that takes no elements.)
16. **Capture `path` after rebasing (1398–1400).** The text warns that SLICE
    on a capture does not work for matches against a temporary current node
    but never says what `path` then contains. → Define it as relative to the
    rebased value, or omit `path` for such captures. (This design resets it;
    check `36-capture`.)
17. **Substructure tie-breaking in nested sequences (458–470).** Rule 4 is
    stated for "the sequence specification", but capture-producing
    substructures can sit inside nested SEQ / ALL, where their position depends
    on inner boundaries. A global lexicographic optimum over all of them is
    expensive and surely not intended. → Define it hierarchically: outer
    boundaries are fixed first, then each nested sequence resolves its own.
    (Implemented that way in §11.3.)

### Design observations

18. **LOCAL's `prop` is computed, WITH's `temp_prop` is literal (1725,
    1961–1964).** The LOCAL text only implies evaluation (by classifying bad
    values as `INVALID_OPERAND`); the suite confirms it, including a computed
    `null` that rebinds the current node. Consequently no static analysis can
    know whether LOCAL rebinds the node — which decides, for instance, whether
    regex context survives into its body. → State the evaluation explicitly,
    and consider requiring a *literal* `null` for rebinding.
19. **Forms distinguished only by runtime type.** `[MKOBJ, a, b]` is "one
    pair" or "names array, values array" depending on what `a` and `b` evaluate
    to; `[ADD, x]` / `[MUL, x]` likewise. This blocks static validation of
    arity and operand types. → Acceptable, but say explicitly that the form is
    chosen after evaluation and which error applies to mixed cases.
20. **Path context, 129–131:** "some actions can override the implied
    namespace" — no action does. → Delete, or name the actions.
21. **Unknown reserved metadata names (905–907).** Lower-camel names are
    "reserved for the protocol", with no rule for an unrecognised one (ignore,
    or `UNSUPPORTED_GRAFT`?). → Specify; ignoring is the forward-compatible
    choice given `v`.

---

## 17. Addendum: after implementing

The implementation is in `lib/` with tests in `t/`. It passes every
conformance case in both validation modes. This section records where it
departs from the plan above, and what the suite taught that the spec does not
say.

### Departures from the plan

Each of these made the code smaller; none changes behaviour the suite can see.

- **Constant folding goes further than §5.5 step 5**, which folded an
  operation marked `pure` when all its arguments were constant. There is no
  such mark now. While an expression is compiled, a note is kept of what it
  will read from the run: the current node, a named TEMP property, or
  something unknowable. An operation that supplies one of these to an
  expression inside it (MAP and FILTER the node, REDUCE and LOCAL a TEMP name
  as well, a two-value IS or HAS the node) cancels that name. Whatever is left
  reading nothing is a constant, at any depth, and is evaluated at compile
  time under a small budget. So `[MAP, [ADD, [NODE], 1], [[1,2,3]]]` folds,
  though its inner expression alone does not. A match expression that reads
  nothing, not even the node it is matched against (`[IS, 5, 5]`, or any
  combination of such by ANY, ALL, NONE and WITH), is decided the same way
  wherever it appears in a pattern.
  Operands that default to the current node are declared in the table
  (argument letter `N`), which is how `[POW, 2]` is known to read the node.
- **An expression that always fails is found by folding it**, and what
  happens depends on how it fails, following the spec's distinction ("Action
  Overview"). `INVALID_OPERAND` means it was given something it can never
  accept (`[SLICE, "abc", "x"]`): that is a fault, `INVALID_GRAFT`, even
  inside a match, where the spec allows this upgrade when the parameter is
  "intrinsically invalid". `INVALID_TARGET` (`[DIV, 1, 0]`) must not be
  upgraded: the expression may be guarded, be one alternative in a match, or
  be meant to fail. It is folded to a node that raises the same error again,
  so a run behaves as before but does not repeat the work, and the graft
  gets a warning (`$graft->warnings`) naming the innermost expression that
  fails. Enclosing expressions are told apart from it because, while
  folding, the node re-raises the very same error object. Failures the graft
  asks for (FAIL, a CASE with no default) are marked `meant` and give no
  warning.
- **Folding is governed by limits given to `new`**, not by a built-in budget.
  Evaluating constants is work done by `new`, so `new` takes the same
  `limits` as `run`, as one allowance for the whole graft; without them
  nothing is limited, as for `run`. What the allowance does not cover is left
  unfolded, for the runs that reach it, under their own limits; `new` itself
  never fails for this reason. A caller who does not trust a graft gives
  limits to both. (The plan had a fixed budget of 10 000 operations and
  64 KiB per expression.)
- **Named constants are constants.** A `const` definition whose value is
  known when the graft is compiled is recorded in its lexical scope, and
  `[CONST, name, ...]` then reads nothing from the run. A common expression
  referred to by a literal name is compiled at that point (unless it refers
  to itself), so that what it reads is known; one that is a constant value
  simply takes the place of each reference to it.
- **Constants are shared, and the output is documented as read-only.** A
  value known at compile time — written literally or folded — is handed to
  every evaluation as is, so a literal costs nothing however large it is.
  The price is that a caller who edits the output could alter the compiled
  graft. Where Perl can prevent that cleanly it does: arrays from the graft,
  their elements and the values of objects are marked read-only. An object's
  set of keys is not protected, because locking a Perl hash also makes it an
  error to read a key it lacks; that case is left to the documentation in
  `JGraft.pm`.
- **`depth` counts EXPR nesting only** (§9): the number of EXPR calls in
  progress at once. Static nesting is bounded by the graft, so there is no
  per-node depth and no per-action check. This is now the definition
  recommended for the spec (§16 item 11), not just a shortcut. A graft
  written more deeply than the limit, without EXPR, is therefore accepted.
- **`new_obj` and `prop_per_obj` are counted where §9 said, and tested.**
  The first implementation charged them in three places only, counted an
  array's elements as properties, and spent a `new_obj` for each property
  added by COPY; nothing caught this, because the suite has no case for
  either limit. Now `charge_obj` is called wherever an array or object is
  made as a value (literals with computed members, containers made along a
  new path, MAP, FILTER, CONCAT, SLICE, SPLIT, PROPS, MKOBJ, captures), and
  `charge_prop` wherever an object gains a property (COPY, MOVE, and a
  container made along a path). Copy-on-write clones are not counted: they
  are this implementation's business. `t/design.t` pins the count for each.
- **Dates are replaced where they leave the engine** (§7.2): when an action
  stores a value into the document, or puts one in the log. Instead of the
  planned count of dates made during the run, which says only that a date
  existed somewhere, the decision is made at compile time: every value
  expression is marked `dated` if it could give a date (it contains CASTDATE,
  reads the stash, TEMP or constants, or is the result of LOCAL, MAP, REDUCE
  or a common expression). Only such values are examined, and only in a graft
  that uses CASTDATE at all. Nothing ever walks the document.
- **Fewer modules** (§3): no `JGraft::Result` file (it is a handful of
  accessors in `JGraft.pm`); operations are in five files, `Ops::Action`,
  `Match`, `Fn`, `Math` and `Split`, where the plan listed eight. The layout
  was only ever this plan's: the spec says nothing about how an
  implementation is organised. One module has since been added,
  `JGraft::Undo`.
- **Options not built** (§2): `forbid_proto` and `allow_inf`. The spec makes
  both optional; the first matters only to grafts that must also run on old
  JavaScript engines, and the second needs every numeric operation to say
  what it does with an infinity.
- **`partial` and `where` are as §2 describes**, after a first version that
  cut both short (`output` doubled as the partial tree, and `where` was only
  the action's name). A failed run has no `output`; the tree as the failure
  left it is `partial`, on the result and, with `logs`, on the error, which
  is how a caller of `apply` reaches them. The error given to a run is a
  copy, because a fault is one object raised by every run. `where` is a JSON
  Pointer to the action in the structure that was compiled, with the
  action's name beside it as `action`. The compiler knows each action's
  index as it compiles it, so the pointer costs a run nothing but what the
  name did: each action sets one field, now with `local`, so that an action
  that fails after the actions inside it have run is the one reported.
  Faults and warnings are placed by the action being compiled. A node that
  MOVE takes away and nothing replaces is left as null, so that the partial
  tree never holds the engine's placeholder.
- **Undo is built, and not in the way §13 foresaw.** The plan would have
  recorded an inverse operation in each of the store's write primitives.
  Nothing is recorded. Immutable data with path-copying (§7) means that the
  output shares with the input every array and object the run left alone,
  so `JGraft::Undo` compares the two afterwards, stopping wherever they are
  the same one: the cost is in proportion to what changed, is paid only if
  `undo` is called, and no action needs to know about it. Objects are
  compared key by key. Arrays are compared for the least change (Myers's
  O(ND) algorithm, on a key for each element: its address if it is an array
  or object, so that what a run left alone can be mistaken for nothing
  else). That search costs the square of the change, so it is given a fixed
  multiple of the arrays' length in comparisons, and not tried when too few
  elements are common to both; past that, one pass pairs the arrays off by
  looking for each side's element further on in the other, taking the
  nearer, and never passing over an element that is on both sides for one
  that is on only one. A stretch that differs becomes a SPLICE, or, where
  there are as many elements as there were and they are arrays or objects
  still, changes within them. Stretches are undone last first, so that
  positions stay true. A string of several lines is compared as the array
  of its lines and undone by an ATSPLIT on the line breaks, chosen by the
  undo and not copied from the graft: an ATSPLIT's own split cannot be
  relied on to come out the same on the edited string. Values put back are
  written as graft literals (arrays escaped, dates as CASTDATE, as the spec
  asks). The conformance harness checks that every case, passing or
  failing, is restored by its undo graft; `t/design.t` checks the array
  comparison against a longest-common-subsequence table.
  Recording inverses was considered again for arrays and rejected: it
  would undo what was done, not what changed, so an array rewritten by an
  expression (`[COPY, [FILTER, ...], path]`) would be put back whole, where
  comparison finds the two elements that went. It would also need an option,
  and a record made by every writer, MOVE's deferred steps included.
- **A run-time error also says where the current node is** (`node`), which
  the spec recommends and the plan did not have. It is in the form of a
  capture: `{ path }` from the root of the partial document, and inside
  ATSPLIT, where the nodes are pieces of a string, `{ path, ofs, len, lim }`
  with the path leading to the string. The offsets are worked out only when
  an error is made (which outside a match is once in a run), by joining the
  pieces as they stand; nested ATSPLITs add theirs up through a chain of
  closures (`$x->{piece}`). So that the offsets refer to something, an
  ATSPLIT that fails puts its pieces back together into the partial document
  before passing the error on. All of this looking is done by `aside`, with
  limits off and failures ignored, so that it can never change which error a
  run reports.
- **Object patterns try their cheapest members first** (§5.4 gave no order).
  The first implementation tried them in the order Perl's hash gave, which
  changes from one process to the next: the same FILTER over 50,000 records
  took 155 ms or 285 ms depending on which of its two members came first.
  Plain values now go first, then patterns by how much is written in them,
  then by name, so the time is steady and usually the lower one. The spec
  leaves the order open.
- **A sequence does not alter the items beside it** (§10, and spec item 14,
  as its author has now settled it). §10 put every top-level item of an
  array pattern into sequence context as soon as one of them was SEQ-family,
  which is how the spec's text reads; so a NONE beside a `[SEQ]` took no
  element, an ANY took as many as its alternatives did, and a REP could
  stand at top level. Now only the items that begin a sequence (SEQ, SEQMAX,
  SEQMIN, or a WITH or a named expression that leads to one) are compiled in
  sequence context. Each other item is compiled exactly as in an array with
  no sequence, and `Compiler::single` makes it an item of the sequence
  engine that takes one place: an element, or once the place past the last
  element, where it meets the element that does not exist (as `[END]` and
  `[NONE, ...]` do in plain arrays). After that place nothing can follow
  but a sequence of no elements. Under IS a last, unwritten item accepts
  the end with or without that place used. Consequences: a REP at top level
  beside a sequence is now a fault, as it is anywhere outside one, and so is
  a SEQ inside a top-level ANY, ALL or NONE; write `[SEQ, [REP, ...]]`. One
  case in the suite depended on the difference and still passes.
- **What a comparison with the other Perl implementation showed** (it was in
  another repository, `JGraft-perl`, and the comparison is written up there,
  in `JGraft-implementation-comparison.md`). Taken from it so far:
  `new` and `run` refuse an option or a limit they do not know (a limit
  misspelt had been no limit); the limits given to `new` are those of every
  run, unless the run is given its own, so that an untrusted graft needs
  them in one place only; and `new` compiles a copy of the structure
  (`JGraft::snapshot`), since a definition reached only by a computed name is
  compiled when first used, and a caller who had changed the structure by
  then would have changed the graft. An error that names an expression
  still names the caller's own (`JGraft::theirs`). The defaults stay
  unlimited, as Perl's own are.
- **What a graft supplies is copied for each run** (the comparison's item
  3). §7 shared a literal, and a constant folded from literals, into every
  output: O(1), but an output was then wired to the graft, and adding a
  property to such an object changed every later run without a word (Perl
  can refuse changes to an array, not to a hash's keys without also
  refusing reads of keys it lacks). Now a constant node that is an array or
  object hands out a copy each time it is evaluated (`Compiler::konst`,
  `thawed`), charged to `ops` and `mem` at a weight worked out once. The
  copy keeps shared parts shared, since a folded constant can hold one array
  in 2^60 places. A constant declared in `const` is not copied on entry:
  the graft's own value is held (`$x->{held}`) and the CONST reader copies
  what is read out of it, so a table of 10,000 entries with one lookup a
  run costs 0.047 ms and not 63. `share => 1` to `new` gives the old
  behaviour. Measured: 0.046 to 0.054 ms a run for a small graft; a literal
  made 200,000 times in a MAP, 57 to 800 ms (they are now 200,000 objects).
  Not copied where it could be avoided but is not: a literal bound by WITH,
  LOCAL or REDUCE is copied at each binding.
  `clone => 1` to `run` goes the whole way: the output is copied as a
  tree when the run ends (`Exec::apart`), sharing nothing with the input or
  within itself, and charged to the run. So is what a failure left
  (uncharged: there is nothing more to stop). Log data is not copied, in
  any run: a log is for reading, the value logged is a snapshot for nothing
  as it stands, and a graft that logs the document at each step would
  otherwise copy the document at each step. Such a run shares what the graft supplies, as
  with `share`, since all it leaves is copied anyway; which of the two a
  constant does is therefore asked of the run (`$x->{share}`), not fixed
  when the graft is compiled. The copy is made at the end and not as the
  run goes: most of an output is what no operation wrote, and is there
  only because a shallow copy of an array still points at it, so there is
  no step at which to copy it; and a value that is written may be read
  back and written again. Undo compares by identity, so the result keeps
  what the run left as the run had it (`left`) and the undo is worked out
  from that. Considered and not done: one
  private copy per graft, shared by all outputs. That is what there was;
  the copy would be as exposed as the original, and it is the sharing
  between outputs that is the trap.
- **What is new is written as what is around it is** (`JSON::style`,
  `anew`). A new member or element already took the separators of its
  neighbours, but a new array or object was written compactly inside
  whatever it stood in, and a whole new document compactly. Now a new one
  is laid out as the array or object it stands in is: each element on its
  own line, a step further in, if that one's elements are (the step being
  how much further in they are than its closing bracket); or on one line
  with its spacing; with the colon the text uses. A whole new document is
  laid out as the old one was (`outermost`). Prompted by measuring how
  nearly an undo restores a text byte for byte: on the conformance suite's
  documents, pretty-printed, 35% of those a run changed came back the same
  to the byte, nearly all the rest differing in white space, because what a
  run destroys comes back from the undo graft as data without layout.
  With this, and moves undone by moves, it is 97% (2,367 of 2,437); the
  rest are strings whose escapes were lost with the value (58), a key put
  back at the end of its object (9), and a value moved to another depth
  that kept the indentation it had (3).
- **Undo takes back what was moved from where it went** (the comparison's
  item 5, where a renamed subtree of 2,000 items cost 23 KB of undo against
  129 bytes). The comparison of output with input notes, as it goes, what
  of the input is *wanted* back (it would have been written out) and what
  the output has to *spare* (it will be removed or written over). If
  anything is wanted, what is spare is looked through, breadth first and to
  a limit (2,000 places and 20 for each thing wanted), and indexed by
  identity; a wanted array or object that is found there, at any depth of
  what is being written out, becomes a reference to STASH, and the graft
  begins by copying each such thing aside from where it is. That one
  device serves a rename, a move between array and object, a wrapping put
  on or taken off, and several at once, with no ordering to work out: the
  copies aside are made while the document is still as the run left it.
  Where copying aside, removing and putting back is all there is to it
  (the thing wanted once, as the whole of what goes to its place; removed by
  an action of its own, or inside something that is; both places reached
  through objects alone, since an element's number may have changed by
  then), the three are made one MOVE (`Undo::straight`), which if it comes
  out of something that is removed is made before the removal. A plain
  value (a number, a short string) is not looked for among what is spare,
  since a reference to a copy is longer than the value; but one that is
  wanted at a property, and whose like is removed from another, is a MOVE
  too. So the undo of a move is a move whatever was moved, and in a text
  the value keeps the spelling it had. Paths of one step are written as the
  step (`brief`): `["MOVE","b","a"]`.
  A thing that was moved and then changed is not the same object: the
  engine now records, for each copy it makes (`Exec::clone`), what it is a
  copy of (`origin`, which the result keeps), so that the copy can be put
  back and then changed back inside (`mend`), by the same comparison at the
  place it will then be. Long strings are found by their text. Sizes now, on
  the document the comparison used: rename 35 bytes; rename and change
  inside, 78; an element sent to the end of its array, 139 (JGraft-perl:
  129, 204 and 192). Undo of ordinary edits takes as long as before.
- **`JGraft::JSON->parse` can be told how long and how deep a text may be**
  (`max_size`, `max_depth`; the comparison's item 7), and is not limited
  unless it is, as a run is not. Nothing breaks at any depth: a million
  arrays one inside another are read, written back, run on, copied and
  freed. What depth costs is memory while reading, some 4 KB a level (the
  reader calls itself, and Perl keeps a frame for each level), so that 2 MB
  of `[` takes 4 GB: that is the reason to limit it for a text that is not
  trusted. A reader that kept its own stack would not have the cost; not
  done. A flat array of a million numbers takes 250 MB, most of it the
  record of where each stood in the text.
- **Exact numbers** (`JGraft::Number`; the comparison's item 6). The way
  `JGraft::JSON->parse` reads a text unless given `exact => 0` (a layer
  whose point is to give the text back has no business rounding its
  numbers), and asked of a run on other data by `exact => 1`: arithmetic is
  done in decimal on a whole coefficient and a power of ten, by the rules of
  the General Decimal Arithmetic specification: so 0.1 + 0.2 is 0.3, and
  0.10 + 0.20 is 0.30, the places a number was written with being kept.
  `Math::BigFloat` would have given the first (it is decimal, not binary)
  but not the second, since it drops trailing zeros, as `Math::BigRat` does;
  and a rational has no decimal to write for 1/3 either. So the class is
  the engine's own, some two hundred lines, with `Math::BigInt` for a
  coefficient of more than eighteen digits and Perl's integers for the rest.
  Decisions:
  - *The result is Perl's own number if and only if Perl writes that number
    as the same digits* (`"$n"` scans to the same coefficient and exponent),
    and an object otherwise: 0.30; more than the fifteen digits Perl writes,
    or than an integer holds; out of range. The test is Perl's own
    stringification and not the shortest text that reads back, because that
    is what `JSON::PP` and `Cpanel::JSON::XS` write: a number of seventeen
    digits made native would have been written by them as fifteen. Nothing
    is lost by the replacement, since an exact run takes one of Perl's
    numbers for the decimal Perl writes it as: the object and its
    replacement have the same coefficient and exponent.
  - *A Perl number is what Perl writes, never what it holds*
    (`Number::parts` scans `"$n"`). The binary value must not reach a
    calculation that is to be exact, or its error is in the result. This
    holds on the short way that whole numbers take too (`Math::exactly`
    computes with `0 + "$a"`, and takes a result for whole only if it is,
    not merely if Perl writes it so: 1e15 / 3 prints as an integer). It
    follows that binary noise is dropped (0.30000000000000004 is 0.3), and
    that a number of more than fifteen digits is exact only if it arrives
    as an object.
  - *Comparison likewise.* In an exact run two of Perl's numbers that are
    not `==` are still equal if Perl writes them as the same number
    (`Number::equal`, `ordered`): in `match_lit`, the literal matchers,
    `compare` (LESS, LESSEQ), `NUM` and `CASTBOOL`. The test costs nothing
    until `==` has said no. Much of this code has no run to ask, so the
    run's flag is also `$JGraft::Number::EXACT`, set with `local` by `run`
    (and to 'fold' while a constant is evaluated, where a comparison that
    would come out differently dies and is left for the runs).
  - *And whole numbers likewise.* `Util::whole` gives the whole number that
    a value is, as one of Perl's own, or nothing; in an exact run a number
    that Perl writes as whole is that number. Every place that needs an
    index or a count takes the value from it, not only the yes or no
    (`is_int` is now `defined whole`): path elements and half-indices,
    SLICE, SPLICE, ARRAY length and offset, REP, ROUND's options, character
    codes. So an exact
    run of ordinary data gives ordinary data, and goes on exactly from it.
  - *A whole number has no places*: 1e2 is 100, and 150e28 is 15e29.
  - *The flag is the run's*, so one compiled graft serves both. It can be
    said to `run`, or to `new` for every run not told otherwise, and failing
    both it is how the document was read (the root's record says). For data
    that is Perl's own and nothing said, it is off: Perl's numbers are not
    decimals, exact arithmetic has to take one for the fifteen digits Perl
    writes, and a double that means all seventeen of its digits (a time to
    the microsecond) would be made coarser without a word. Only the caller
    knows which the numbers are.
    Folding does not know which run it is for, so while folding, arithmetic
    that would differ dies ("undecided") and is left unfolded: whole-number
    arithmetic still folds, and anything on a number that is already an
    object, which is exact in any run.
  - *Objects are numbers everywhere* (`Util::is_num`, `type_of`, `match_lit`,
    `compare`, the literal matchers, `NUM`, indices), and so are
    `Math::BigInt` and `Math::BigFloat`, though none is made.
  - *Equality is of value* (0.30 matches 0.3); only the JSON writer and undo
    ask whether two numbers are the same to the place (`Number::same`).
  - *Division is exact too.* A quotient that ends is the decimal. One that
    does not is a fraction: the object is then
    `[ numerator, denominator, places ]`, and arithmetic that meets one is
    done on fractions (`Number::frac`, `settle`), giving a decimal again as
    soon as one says the result. So
    (1/3) x 3 is 1, where forty digits of a third gave 0.999...; that had
    made exact arithmetic worse than Perl's own at the one thing, and broke
    indices worked out by division. Digits are given only when a fraction is
    written, 34 of them (`$DIGITS`: decimal128; the 40 it was at first were
    only `Math::BigFloat`'s default). The places ride along: 1.00/3 x 3 is
    1.00. Storing the digits that repeat, as on paper, was considered: it is
    the same information as the fraction, but a divisor of n digits can
    repeat every 10^n (1/65537: 65,536 digits), so it is offered only as a
    way of writing (`repeating`: `0.(3)`, `0.1(6)`). The fractions were
    first done with `Math::BigRat`, which cost 200 µs an operation (to make
    one is 80); they are now Perl's integers, as coefficients are, with
    `Math::BigInt` when those are too short, and ten times faster. `LOG` and
    fractional `POW` stay Perl's.
  - *Cost is charged*: a digit of a kept object, the zeros between two
    numbers added, the digits of a power, with a cap of a billion.
  The whole conformance suite gives the same results exact as not, except
  the fifteen cases whose point is that a number is beyond Perl's range;
  `t/conformance.t` now checks that. It is slow beside Perl's arithmetic
  (15 to 25 µs an operation here, against 1), which is why it is asked for.
  The spec might say that an implementation may offer this: "Math" defines
  ADD as "the host language's addition".
- **A review of the whole, by readers who had not written it**, found some
  forty defects, each reproduced before it was fixed and pinned by a test
  (`t/design.t`, "corners of moving, matching and counting" and "numbers and
  dates at their edges"). Those that bear on this design:
  - *Sequences of "anything".* A `[REP]` with no pattern returned every
    place up to the end, for every place it was tried from: quadratic in
    time and memory for `[SEQ, [REP], x, [REP]]`, and uncounted. Such an
    item is now marked `any`, and `JGraft::Seq::advance` (which `possible`
    and SEQ both step with) joins the runs of places it leads to. A STR
    that asks only whether there is a match tries its starting places in
    turn and stops at the first.
  - *Counting.* Comparing data with data (`match_lit` on a pattern that
    comes from the run), ordering arrays, and replacing dates on the way
    out are now charged. `[ARRAY, n, ...]` no longer copies the n elements
    it skips in order to ask whether a MOVE is in progress.
  - *Flags passed on by wrappers.* WITH passed on what was known of its
    pattern as a regex, though a value it cannot have makes it fail; so did
    the one-argument HAS and IS in a sequence. A reference by a computed
    name claimed no captures while its definition recorded them during the
    search. EXPR now takes `caps` and `pref` from the compiled definition,
    and resolves captures through a computed name as through a literal one.
  - *MOVE.* A node already moved away could be moved again, putting the
    engine's placeholder into the output; the document could not be moved
    into itself; an element arriving from another SPLIT replaced the
    array's own separators; and the putting back of a failed pair could
    itself fail under `prop_per_obj`.
  - *Constants.* Freezing walked a value as a tree, so a folded value
    holding one array in many places took exponential time.
  - *Numbers.* MOD through a float quotient, POW inexact past 2**53,
    overflow checked only at the end of ADD and MUL, and several faults in
    ROUND and in writing dates.
  Left as they are, knowingly:
  - A COPY or MOVE that fails after making containers on the way to its
    destination leaves them in `partial`; and a failed MOVE pair is put
    back by its path, which a container made on the way can have shifted.
    The spec has the destination verified before anything is detached
    (MOVE, step 2). Only `partial` shows the difference, and the undo graft
    is made from it correctly.
  - A right trim that is not a run tries every place it could begin.
  - A regex given to Perl with several runs side by side can cost more
    than the closures do (a power of the length equal to their number).
  - During a MOVE, a positional array pattern can see an element awaiting
    removal as absent, where the spec has any access to it fail.
  - Definitions reached only by a computed name are compiled during a run,
    and what they fold is counted against what `new` was allowed.
  - Side records for SPLIT results are kept until the run ends.
- **A pattern is charged for each place it is tried from** (§9), not for
  each place it matched from. As first written, `possible` charged after
  each step, by the number of positions that survived it, so an unanchored
  STR that failed at 100,000 starting places cost nothing and no `ops` limit
  could stop it.
- **Native regexes where they are certain to agree** (§11.4 proposed
  translating whole patterns, for existence only). A node in regex context
  now says what is certain about it as a Perl regex: `re`, a regex matching
  at a place just the strings the node matches (characters, strings, CHARS,
  SEQ, ANY, NONE, START, END, and REP with fixed limits over one character
  or any); and, where it is so, that the regex's first match at a place is
  the longest (`fixed`, `longest`, `least`). Each use takes what it can rely
  on. STR asking only whether there is a match needs just `re`. A separator
  needs the longest match, never empty: a choice of strings and single
  characters, written longest first, or a run of at least one. Trims are
  below. The only repetition ever written into a regex is of a single
  character, so Perl's backtracking stays polynomial where the closures'
  successor sets are; and STR does not ask Perl at all when operations are
  being counted, since Perl does not count. Elsewhere there are exact,
  general shortcuts: `index` for literal separators, and a run loop in REP
  when its body matches exactly one element. A trim pattern that is a run of characters from one known set
  (`[REP, lo, hi, c]` with fixed limits, where c is a character or a CHARS
  that refers to no other set) is handed to Perl: the set is worked out as
  ranges when the graft is compiled, the left trim is one anchored match, and
  the right trim is the same match on the piece reversed. Reversal was
  chosen over `s/[set]+$//` by measurement: the two tie on short lines, but
  the end-anchored form tries every run of the set inside the line, and was
  4x slower on 400-character lines and 60x slower with long runs inside.
  Other trim patterns keep the closures, where the right trim now steps back
  a character at a time and so is linear (it was quadratic in the length of
  what it trimmed, which the first version's "working back from the end"
  did not avoid).
- **LOCAL with a computed `null` name inside a regex** keeps regex context in
  its result expression (the two-variant scheme of §11.4 was not built).
- **`lit` instead of a `plain()` pre-scan** (§5.4): a matcher that compares
  with a constant says so, and a pattern made only of those collapses to one
  `match_lit` — decided bottom-up, so deep patterns compile in linear time.

### More that the suite decides and the spec does not say

22. **REP's body is trapped** (see item 7): `[SEQ, [REP,0,1,[NODE,"absent"]], 1]`
    matches `[1]`.
23. **One-argument HAS / IS in a sequence** (1491–1493) tests its spec *as a
    sequence from the current position*, however far that reaches, and then
    consumes exactly one element: `[SEQ, [IS, [SEQ,1,2]], 2]` matches `[1,2]`.
    The text only says the successor is the next position.
24. **SPLIT with a separator that can be empty** (2229–2236): an empty match
    does not count at the end of the string, and an empty string yields `[]`
    rather than `[""]`. Both follow from "every boundary between characters"
    but neither is stated, and the `/a*/` example suggests otherwise for the
    final element.
25. **ATSPLIT evaluates `split_spec` with the selected string as the current
    node** (1016–1033), not the node the action started at.
26. **MKOBJ with a wrong number of arguments is `INVALID_TARGET`** even though
    the count is static; the suite does not allow `INVALID_GRAFT` there. Other
    arity errors are `INVALID_GRAFT`.
27. **A missing name inside CHARS is a failed probe** (1907–1910 says
    `INVALID_OPERAND`), whereas elsewhere the suite allows a missing literal
    EXPR name to be `INVALID_GRAFT`. → Pick one.
28. **In a SLICE configuration object an explicit `null` position is an
    error**, though an absent one takes a default (2056–2065).
29. **ARRAY's skipped prefix must exist**: during a MOVE, an element pending
    deletion in the skipped range (or, under IS, after the matched items)
    makes the match fail (1641–1651 implies it via the REP equivalence).
30. **An array literal containing a direct reference keeps that element's
    SPLIT metadata** (`[[ [NODE] ]]` inside REDUCE over a split array). The
    spec's "construction of new arrays counts as an insert" covers it, but only
    just.
31. **`[IF]` and `[IF, action]` are valid** (a no-op, and an unconditional
    else); 1090–1091 shows only the longer forms.
32. **CASTNUM must not turn a nonzero string into 0** (`"1e-400"`); 2463–2464
    speaks only of numbers "outside the range".

33. **Nothing can place a property within an object.** An array has
    half-indices (1213–1222); an object has no counterpart, so a graft cannot
    say that a new property belongs after a given one. Where the order of
    properties is kept (as `JGraft::JSON` keeps it), a new property can only
    go last. → If order is ever to matter, give MOVE and COPY a way to name
    the neighbour.

### JSON kept as it was read (`JGraft::JSON`)

Not in the plan. The engine works on decoded data, and a decoder forgets
most of what a text says: the order of properties, how numbers and strings
were spelled, white space, bytes that are not UTF-8. `JGraft::JSON` reads a
text so that the result of a graft can be written back as that text,
changed only where the data changed.

- **Objects are ordered hashes** (`JGraft::Ordered`, a tie of some twenty
  lines; the suggestion and the measurement that settled it are the
  user's). Order is then a property of the data: setting, adding and
  deleting keep it with no help from the engine, and any encoder sees it.
  Reads cost 1.4 to 1.7 times a plain hash's, only for documents read this
  way. The engine chooses the kind of hash in the four places it makes one
  (the copy before a write, a container made along a path, an object written
  with computed members, MKOBJ), and `Ordered::place` lets a MOVE within one
  object leave the new name where the old one was.
- **Where each value came from is kept beside its container**
  (`JGraft::Source`): a "token" for each slot, `[ start, end, \$text ]`. The
  reader records them; the engine copies them when it copies a container,
  keeps an array's list in step through SPLICE and MOVE, and hands a token on
  with a value that is moved or copied from a path (the same road SPLIT
  metadata travels: `take`/`give`, the `tok` closure of a reference beside
  its `meta`, and the array functions through `$made`). A tie cannot do
  this: a tie belongs to a variable, and a value that moves is a copy. Nor
  can a dualvar, which Perl cannot tell from a string once used as a number.
- **A token is a hint, never trusted.** The writer uses one only if it
  still says what the value is (it reads the token again and compares), so
  a slip in keeping tokens in step can cost a spelling but cannot write a
  wrong value. That is also what lets a value written over with its equal
  keep its spelling, and a changed string be compared with the token that
  was there.
- **Writing is patching.** A container that was read and not changed is
  copied out whole. One that was copied and changed is written over the
  text of the one it came from: members that are still neighbours keep what
  was between them, a property keeps its key as written, and what is new is
  joined as the text joins things. A changed string is compared with what
  it was by the same line comparison that undo uses, then by common ends,
  then for the least change between what is left, and the unchanged runs
  are copied from the old token byte for byte. That last comparison is
  Myers's algorithm again, but on the two strings as they are
  (`JGraft::JSON::differences`): places are compared with `substr`, and a
  run that is alike is crossed in leaps (`agree`), so no character is ever
  a scalar of its own. The first version split the strings into arrays of
  characters and used the array comparison, which cost 480 bytes and 3.4
  microseconds a character and so had to be capped at 4,096 characters;
  on the strings themselves a line of 1.2 million characters with three
  changes takes 105 ms, and there is no cap.
- **Bytes that are not UTF-8 are characters past the end of Unicode**,
  0x110000 plus the byte, written back as the byte. Those 128 code points
  (the byte is 0x80 or more) are reserved, and the reader makes sure no
  text can mean one of them in any other way: UTF-8 is taken strictly, so
  the old five- and six-byte forms, Perl's own longer ones, surrogates,
  overlong forms and anything past 0x10FFFF are all "not UTF-8", read byte
  by byte. Every text therefore reads to something that writes back as
  itself. The writer refuses any other character past 0x10FFFF, which can
  only have been put in the data by hand. One thing follows: a graft can
  join strings so that a stray lead byte comes to stand before its stray
  continuations (the two halves of a character that something had cut in
  two), and the bytes then written are a good character. So that the run
  sees what a reader of its result will, the engine reads such bytes again
  where it joins strings (CONCAT, JOIN, and the rejoining of an ATSPLIT,
  through `Util::mended`): they become the character they spell. It costs
  one search of the joined string for two such bytes side by side, and
  only for documents read by `JGraft::JSON`. Upgrading the bytes to the
  code points of the same number was considered and rejected: it is a
  guess at Latin-1, it changes the bytes, and it is wrong in the likeliest
  case.
- **Checked by** every conformance case run again on a document read from
  text (same outcome, and what is written reads back as what the run left),
  20,000 random texts in random layouts written back identically, and some
  10,000 random edits of them.
- **Not done:** the spelling of a literal written in the graft is not
  carried into the output (the compiler is handed values, not where they
  were written); new values are written compactly, not indented to match;
  the document's own root has no token of its own, so a scalar moved to
  become the whole document is written plainly.

### For anyone running the suite from another JSON library

Two things in `conformance/*.json` trip decoders: lone surrogate escapes
(`JSON::PP` and `Cpanel::JSON::XS` both refuse them), and integers longer than
the machine word (`JSON::PP` returns them as strings). `t/conformance.t` works
around both; see `load`. `JGraft::JSON` reads both as they are.
