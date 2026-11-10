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
    one "op" minimally covers, and that depth counts expression nesting
    including EXPR expansion.
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
15. **Element matchers at position == length in sequence context (422–424).**
    Positional matching lets an item match the nonexistent element at
    `length`; sequence context says an item "consumes one element" without
    saying it cannot do so there. → State that nothing consumes at `length`.
    (Assumed here.)
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

- **Constant folding is narrower than §5.5 step 5.** A function marked `pure`
  in the table is evaluated at compile time when all its arguments are
  constant, under a small budget, and only if the result is a scalar or a
  date. Anything that fails or exceeds the budget is left to raise its error
  in the run that reaches it. Operands that default to the current node are
  declared in the table (argument letter `N`), which is how the compiler knows
  that `[POW, 2]` is not constant.
- **Arrays and objects are never folded or shared**: literal containers are
  rebuilt per evaluation. Sharing them would let a caller who edits one run's
  output corrupt the compiled graft.
- **`depth` counts EXPR nesting only** (§9). Static nesting is bounded by the
  graft, so there is no per-node depth and no per-action check.
- **Dates are exported once, when the output is produced** (§7.2), not at each
  store into the node namespace.
- **Fewer modules** (§3): no `JGraft::Result` file (it is three accessors in
  `JGraft.pm`); operations are in `Ops::Action`, `Match`, `Fn`, `Math`,
  `Split`.
- **Options not built** (§2): `forbid_proto`, `allow_inf`, and a `partial`
  field (after a failure, `output` is the tree as it stood). `where` is the
  name of the action, not an index path.
- **No native-regex translation** (§11.4). Instead three exact, general
  shortcuts: `index` for literal separators, a run loop in REP when its body
  matches exactly one element, and working back from the end for a right-trim
  that is such a run.
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

### For anyone running the suite from another JSON library

Two things in `conformance/*.json` trip decoders: lone surrogate escapes
(`JSON::PP` and `Cpanel::JSON::XS` both refuse them), and integers longer than
the machine word (`JSON::PP` returns them as strings). `t/conformance.t` works
around both; see `load`.
