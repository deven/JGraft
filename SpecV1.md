# JGraft

## Introduction

JGraft is a data structure that describes how to edit a tree of data.  It can
describe edits where portions of the source and destination are fully defined
and thus reversible, edits applicable to any compatible data structure, or
conditional edits where the change depends on the state of the target data.
It is a data structure rather than a parsed language to make it easier to
programmatically generate, combine fragments, extract fragments, and inspect.

JGraft is constructed of basic JSON-compatible data types:
`null`, booleans, numbers, JSON-compatible strings, arrays, and objects.
Implementations may include other native host-language data types if the
application doesn't need to interoperate with different host languages.
(Implementations allowing other host language types are responsible for
defining equality, ordering, cloning, and serialization behavior for them,
which is outside the scope of portable JGraft.)
While performing edits, JGraft additionally defines types for
[dates and date-times](#dates), though these export back to JSON-compatible or
application-configured data types before committing the edit.

The JGraft data structure describes "actions" and "expressions" in addition
to literal data.  Actions have the potential to mutate the tree or exhibit
other side effects, but they are restricted to ensure the input tree remains
a tree.  Expressions include match patterns and functions, and have no side
effects.  JGraft is designed so that untrusted data and grafts can be
processed safely when implementations enforce appropriate resource limits,
such as memory usage limits, node creation limits, and stack depth limits.

## Representation

The JGraft tree contains actions and expressions, but JSON has no mechanism to
tag data with a type.  So, when serialized to JSON they take the form of
arrays in the style of the Lisp programming language, where the first element
indicates the operation and remaining elements become an argument list for it.
The operation (first element) may be specified using either a name or numeric
ID; the ID is useful for compact encoding in production, and the name is
useful for development and debugging.
In [contexts](#argument-contexts) allowing a mixture of data and expressions,
array literal values get "escaped" by wrapping them with another array.
In other words, in the JSON representation of JGraft in a context that allows
data and expressions, an array containing exactly one element which is also an
array means a literal array having the elements of the inner array.
The elements may then recursively contain expressions or array literals by this
convention.  An unescaped array with no elements represents a directive
lacking an operation, and is illegal.

Implementations may choose to use host-language objects of some sort to
represent actions and expressions at runtime, then perform the array encoding
during serialization and reconstruct the objects during deserialization.
Implementations could also choose to leave the JGraft data
structure in its JSON-compatible form and interpret it on the fly.  However,
JGraft allows actions and expressions to be passed around as opaque macro
objects, so implementations do still require some way to distinguish those from
data. They should make it clear to the developer whether the data structure the
application code interacts with is using objects and literal arrays, or the
direct "arrays-are-special" representation of JGraft.
Since the object model of a host language is left unspecified, the remainder of
this specification uses the JSON representation of actions and expressions,
but using JavaScript-like notation for readability.

### Argument Contexts

Every action and expression declares the context of each of its arguments.
Argument Contexts help reduce the verbosity of the encoding by giving more
complex meaning to simpler JSON structures.

#### Action Context

Actions live in a distinct namespace from expressions; expressions may not be
used where an action is expected, and actions may not appear within an
expression (with the exception of the `ACT` function which returns an action
in the form of a macro object).  Action context does not use any short-hand
notations.

#### Value Context

This constructs a new value or tree of values from a specification which is
a mixture of structure and expressions.

  * Non-objects/non-arrays are literal values to appear in the constructed
    result.
  * Objects in the specification construct an object with the same properties
    where each property value is evaluated recursively.
  * Escaped arrays (an array within an array of one element) likewise
    construct an array where each element of the specification is recursively
    evaluated to generate the value for that element of the result.
  * Other arrays represent expressions, which will be evaluated to generate the
    corresponding value for the result.

Reference expressions used in value context fail if the node described by a
path does not exist.

The constructed value is logically a new tree; however, implementations may
re-use existing tree fragments so long as they can ensure that the result is
not used in a way that could degrade the target data tree to a graph.

#### Match Context

This determines whether the current node has a shape compatible with the
specification structure.

  * Non-objects/non-arrays describe literal values to be compared for equality
    with the target.
  * Objects and escaped arrays are considered structure to be matched.
  * Other arrays represent expressions, which are handled specially depending
    on their type.  Match expressions become part of the matching algorithm,
    while functions evaluate to a plain value and then use the value as
    structure to match against.  Reference expressions other than `EX` are also
    treated as values to match against.  `EX` expands an expression macro
    inline, allowing referenced [match pattern macros](#ex-pat) to participate
    in a match.  Regex pattern macros (despite also being match expressions)
    are not legal to expand here.

The section [Matching](#matching) describes the process in detail.

#### Regex Context

Regular expressions are implemented using mostly the same specification
structure as general matching, but operating on a virtual array of characters.

  * One-character strings describe characters
  * Strings of other lengths implicitly become [`SEQ`](#ex-seq) expressions,
    matching a sequence of characters.  They are invalid where the containing
    match expression forbids sequence expressions.
  * Non-negative integers describe Unicode codepoints
  * Arrays represent expressions.  Literal match expressions become part of the
    matching algorithm.  Match expression macros created with `REG` may be
    inserted with `EX` and participate in the match.  Literal values, value
    expressions, and expansion of value expression macros evaluate to a plain
    value which then gets interpreted according to these rules.
    Structural pattern macros (despite also being match expressions) are not
    legal to expand here.
  * Any other type of data (non-integer number, object, escaped-array, or date)
    is invalid.

The section [Matching String Characters](#matching-string-characters) describes
the process in detail.

#### Path Context

Paths are used to refer to data within one of the [namespaces](#namespaces),
and may be used for reading or writing.

  * Non-objects/non-arrays are interpreted as a single argument to a default
    namespace; the [current node](#ex-node) is the default unless specified
    otherwise.
  * Arrays represent expressions, with the root expression restricted to
    a Reference Expression.  Actions may further restrict the root expression
    to specific namespaces.  The arguments to the expression are defined
    in typical value context.
  * Objects and escaped arrays count as `INVALID_GRAFT` in this context, though
    arrays may be returned by functions within a reference expression and
    get expanded into the path.

These rules are described in more detail in the [Paths section](#paths).

#### Other Contexts

Other argument contexts may be defined by individual actions or expressions,
usually in terms of providing arguments to an implied expression.

### Dates

Dates are a problematic domain to make a specification for.  JGraft tries to
keep the implementation burden low, like not requiring timezone tables, but
applications almost certainly want some integration with the date objects of
the host language.  Meanwhile, JSON doesn't even define a notation for dates.

JGraft takes an approach where dates and date-time values are represented by
temporary objects that logically exist only within the JGraft implementation.
They are created by the [`CASTDATE` function](#ex-castdate), and any operation
that would write them into the target tree of data automatically exports them
to a format of the application's choosing.  In the simplest case, the
application provides host-language date objects in the target tree of data,
the JGraft implementation uses those same objects, and no export steps are
required when writing them back to the data tree.  In other cases, the
application might be parsing ISO 8601 date strings from the tree of data and
returning them to that format as they re-enter the target data, losing any
metadata that would differentiate them from plain strings.  JGraft dates and
date-times may be saved into the const, stash, and temporary namespaces
without losing their metadata.  When exported as an "undo" JGraft, dates are
represented by a `CASTDATE` expression.

JGraft defines three distinct types: date, datetime, and timestamp.  They are
considered immutable values, but expose virtual properties which may be
referenced in [paths](#paths).  `date` lacks a time component, and has virtual
properties of "year", "month" and "day", according to the rules of the
Gregorian calendar and represented in their natural 1-based format.
`datetime` additionally has "hour", "minute" and "second" virtual properties,
where `second` may be fractional to any numeric precision allowed by JSON and
may also be a leap-second value (0 <= second < 61).  Implementations don't
need to check whether a leap second was historically valid; just preserve the
field and compare it last during less-than tests.  Implementations may need to
hold the `second` value in an extra data field if the host date objects
don't support leap seconds or arbitrary precision.  JGraft instances should
generally avoid *creating* datetimes with leap seconds, as they can't be
exported in some host language environments.
`timestamp` additionally has a `tz_offset` virtual property, which is a number
of minutes offset from UTC.  `timestamp` references a specific point in time,
and can be compared with timestamps from differing timezone offsets.

Since each of these is a different type, the usual rules apply when testing
them: dissimilar types cannot "match" in a match expression, and the `LESS`
and `LESSEQ` expressions will fail.  You can use the `CASTDATE` function to
cast values to the same precision for comparison.

### Macros

JGraft allows actions and expressions to be passed around as opaque macro
objects.  Macro objects can only exist in the various internal namespaces of
JGraft; attempts to copy or move them to the input data tree must fail.

There is one macro-creation function for each of the contexts where actions or
expressions are allowed; this lets an implementation perform the same logic it
would use during argument parsing to construct the object.  It also helps
disambiguate whether a plain JSON structure is a match pattern or a value
construction notation.

Macros are expanded in-line using the [`CALL` action](#act-call) or
[`EX` expression](#ex-ex).  They do not receive parameters directly, but may
receive them by way of namespaces like `TEMP` or `STASH`.

Macros may only be expanded in a compatible context; action macros can only be
expanded by `CALL`, regex pattern macros may only be expanded in regex context,
and structural pattern macros may only be expanded outside of regex context.
Value macros may be expanded both in and outside of regex context.

## Namespaces

Actions and expressions can make references to data in five namespaces:

  * Input Data     - initial tree of data supplied as input, only accessible
                     via the [current node](#ex-node).
  * Constants      - a read-only tree of values declared in the
                     [`JGRAFT` action](#act-jgraft) and referenced by the
                     [`CONST` expression](#ex-const).
  * Match Captures - a read-only tree of data captured by the named sequences
                     in an enclosing `MATCH` or `IF` action, referenced by the
                     [`CAP` expression](#ex-cap).
  * Stash          - a read/write tree of temporaries shared between actions in
                     the scope of the same `JGRAFT` action, referenced by the
                     [`STASH` expression](#ex-stash).
  * Temporaries    - a read/write tree of temporaries created fresh for each
                     action, referenced by the [`TEMP` expression](#ex-temp)
                     and which may be localized during expressions using
                     [`WITH`](#ex-with) or [`LOCAL`](#ex-local).

Each tree logically owns its own data and is strictly a tree for all purposes
of JGraft actions and expressions.  However, so long as a tree can only be read
from (the read-only namespaces, and the effectively read-only environment while
evaluating expressions, which are not permitted to have side effects)
implementations are permitted to share subtrees within and
across namespaces, making the namespaces technically acyclic graphs.
The expression language has no means to observe that two read-only objects or
arrays are the same entity, so authors of JGraft can still consider
the namespaces to always be trees.  Application code interacting with the
JGraft state may be able to tell the difference, though.

No namespace other than the input data may have its root node overwritten.
All namespaces except the `TEMP` namespace permit references to the root node,
for copying or enumerating properties.  `TEMP` is excluded so that extensions
may expose unofficial data into the `TEMP` namespace without it becoming
discoverable by JGrafts that don't expect it to be there.  A JGraft can still
test for the existence of `TEMP` properties using match expressions, but they
have to know specifically what they are looking for.

While the Current Node starts as a reference to the root of the input data,
as `AT` actions move the current node deeper into the tree the ancestor
elements become inaccessible.  This is by design; it ensures that independent
JGrafts can be composed without breaking their assumptions about the shape of
the tree, and ensures that there is at most one path expression which can refer
to a node of the input data as actions perform mutations to it.

## Paths

Several actions and expressions use the concept of a "path".  A path is a
list of object properties, array indices, or aliases that descend into the tree
of a namespace.

In general, strings may only refer to object properties and integers may only
refer to array elements.  This is particularly important when auto-vivifying a
path; integers will create arrays and strings will create objects.
However, paths for the `CONST`, `STASH`, `TEMP`, and `CAP` namespaces permit a
leading integer as a property name (coerced to a string) even though the
namespaces aren't arrays, for the improved serialization size.  Paths for the
`TEMP` namespace must always contain at least one element, since the root of
that namespace cannot be read or written.

Negative numbers are available as aliases for array elements.  Specifically,
a value of `-n` (where `n > 0`) means `[SUB, [LENGTH, [...path_to_array]], n]`,
or in other words, the array element at `[array.length - n]`.  The value
`false` is an alias for `[LENGTH, [...path_to_array]]` of the current array.
This position immediately after the final element may not be read, because no
element exists there, but it may be written to append to the array.
(`-0` would be the ideal alias, but too many languages drop that distinction
when decoding JSON)  The values `null` and `true` may not appear in paths.
Certain actions may extend path syntax for particular arguments; e.g. MOVE
permits a half-integer as the final destination selector.

Paths always navigate deeper into the tree and have no concept of "up a level"
like a filesystem's `..` convention.  A path element *may* be a value-context
expression which gets evaluated to determine the path.  If it evaluates to an
array, the elements of the array will be spliced into the path at the location
of the expression.  After a single level of array expansion, the values must
conform to the same rules as literal path elements.  An unspecified or illegal
type of value found in a path causes `RUNTIME_ERROR` if computed, or
`INVALID_GRAFT` if literal or statically incompatible with the permitted types,
according to the [validation rules](#validation).

## Action Overview

Actions describe the overall algorithm of the JGraft.  Each action dictates
the meaning of its arguments; they may include other sub-actions, match
expressions, objects of configuration properties, and so on.  Consequently,
validation or inflation of host language objects needs to be handled
recursively per-action.  Actions occupy a namespace apart from expressions,
and are not interchangeable.

The root of a JGraft is the `JGRAFT` action.  The `JGRAFT` action may contain
metadata and scope-based configuration.  It establishes a scope for common data
and expressions and stash variables available to all sub-actions.  The common
data and expressions help reduce redundancy within that tree, and the stash
facilitates transfer of values between actions.

The primary intended workflow for JGraft is to use a `MATCH` or `IF` action to
verify that the input data tree matches expectations or locate matching
sequences using [array matching](#matching-arrays), then use `COPY`, `MOVE`,
and `SPLICE` to alter the tree.  Named captures provide the paths and bounds
needed to edit sequences found at adjusted positions.

The list of actions is fairly concise:

Name                    | ID | Description
------------------------|----|----------------------------------------------
[JGRAFT](#act-jgraft)   | -1 | Declare metadata; top-level element
[RAISE](#act-raise)     |  0 | Emit diagnostics, or reject input
[AT](#act-at)           |  1 | Navigate to sub-node and execute sub-actions
[ATSPLIT](#act-atsplit) |  2 | Navigate into SPLIT, apply actions, re-JOIN
[MATCH](#act-match)     |  3 | Assert current node matches pattern
[IF](#act-if)           |  4 | Choose action based on which pattern matches
[COPY](#act-copy)       |  5 | Assign-by-value to properties
[MOVE](#act-move)       |  6 | Move existing values between properties
[SPLICE](#act-splice)   |  7 | Perform standard splice() on an array
[WHILE](#act-while)     |  8 | General-purpose looping construct
[CALL](#act-call)       |  9 | Invoke an action reference, localize STASH

The `RAISE` action can be used to provide improved diagnostics to a user
applying a JGraft, or within `IF` to detect unhandled inputs that should be
rejected.

The `ATSPLIT` action is a tool for tokenizing strings in order to make changes
within them, then reassembling the modified string.  It can also be used to
access specific substrings and copy them into stash variables for use in other
actions.

Most grafts should not require the `WHILE` loop, but it helps with things like
applying an action to every element of an array or iterating properties of
objects.

Finally, the `CALL` action allows trees of actions to be re-used and
parameterized.

## Expression Overview

Expressions are essentially "functions without visible side effects", though
there are two special categories:

  * "Reference Expressions" reference a [path](#paths) within the input data
    or one of the special namespaces JGraft offers, and in some cases may be
    written as well as read.
  * "Match Expressions" compare the current node to a structural pattern and
    return a boolean of whether it matched.  Match expressions have special
    behavior when calling other match expressions.

Everything else is just a "Function".  Functions don't need to be pure in the
mathematical sense, but the "no visible side effects" rule is important
because they may be evaluated any number of times during sequence search, and
because JGraft does not define an order for enumerating object properties
during the matching process.  They *may* have a side effect of incrementing
a resource counter that aborts the graft operation due to resource usage, but
that is not visible *to the expressions*.

### Matching

The matching system compares the current node with a specification structure
composed of literal data and/or subexpressions.  In the table of expressions,
some are classified as "match expressions".  These give direction to the match
algorithm rather than behaving like recursive function calls.
For all contiguous portions of the match specification composed of plain
structures or match expressions, the matching algorithm continues building on
the same match state.  If the match algorithm encounters a
[macro expansion](#ex-ex) and the macro object originated from [`PAT`](#ex-pat)
or [`REG`](#ex-reg) (requiring whichever is appropriate for the current
context; expanding these in the opposing context fails with `INVALID_GRAFT`) it
likewise becomes part of the surrounding match expression and builds on the
same match state as if it has been written there.
If the matching algorithm encounters any other type of expression, it evaluates
it as a function and uses the resulting value as a literal structure to match
against.

If a function expression includes an inner match expression, the inner match
expression begins a new match state independent of any ancestor match state.
It retains the current node, but begins with default HAS semantics and without
awareness of neighboring array elements.  This is covered in more detail
under [expression interaction](#expression-interaction).

The baseline for a match is that nothing can compare equal unless it is the
same type.  Plain objects can only match plain objects, arrays can only match
arrays, and each type of scalar can only match that same type of scalar.
For non-object non-array elements of the specification, matching checks for
equality as follows:

  * `null`, `true`, and `false` are equal only to themselves.
  * Numbers compare using the implementation's native representation of JSON
    numbers after decoding.  JGraft does not specify behavior related to
    floating point roundoff; see the [`NUM` expression](#ex-num) for a quick
    way of checking whether a value is within a range or the
    [`ROUND` function](#ex-round) for more control over rounding.
  * Strings compare codepoint-to-codepoint, though implementations may be
    configurable in determining how an array of codepoints is generated.
  * `date` can only match `date`, and all fields must be identical.
  * `datetime` can only match `datetime`, and all fields must be identical.
  * `timestamp` can only match `timestamp`, and both must refer to the same
    instant after adjusting for time zone offset.

The match expressions have a further classification into "node tests" which
match individual nodes, and "sequence tests" which match against sequences of
array elements.  A "node test" behaves identically when matching object
properties or array elements; a "sequence test" may only be used when matching
elements of an array, or characters of a string in regex context.

#### Matching Objects

When the match specification contains an object, it can only match against an
object in the data.  There are two modes of operation for comparing the
properties: "is" mode and "has" mode.  This mode is inherited lexically from
the nearest parent `IS` or `HAS` expression or `GROUP` with an explicit
`exact` setting, and the initial value is "has".
In "is" mode, any object property in the data object which was not specified
in the specification object causes an automatic match failure; in "has" mode
they do not.

For an object `spec_obj` in the specification being compared to current node
`data_obj`, the matching algorithm first checks whether "is" mode is in effect
and whether `data_obj` contains any properties which were not present in the
`spec_obj`.  If so, the match immediately fails.  Then it proceeds to test each
property of `spec_obj`.  For each, it temporarily sets the current node to the
corresponding property of `data_obj`, even if no such property exists in
`data_obj`.  It then recursively tests the specification for that property.
This may succeed even on a nonexistent current node if the specification uses
the [`NONE` expression](#ex-none), which is an assertion that returns true when
a pattern *doesn't* match.
For example, in "has" mode `{ a: [NONE, [EXISTS]] }` asserts that an object
does not have a property named "a".  In "is" mode a test like this is not
needed since simply omitting property "a" from the specification would assert
the same thing.

Match expressions in this context may not apply sequence-test match expressions
to the property being tested.

#### Matching Arrays

When the match specification contains an (escaped) array, it can only match
against an array in the data.  The "is"/"has" mode from object matching serves
a parallel purpose here, determining whether all elements of the array must
match, but the process for matching elements of an array is much different from
the process of matching object properties.  Match expressions classified as
sequence-test expressions may be used here, and consume a variable number of
array elements based on a regular language automata theme.
These expressions have behavior defined in terms of "initial state" and
"generated successor states"; the initial state has a position within
[0,length] where a match needs to begin, and the successor states are all the
ways that the match can resolve successfully from that starting position.
The match algorithm never attempts matches on a nonexistent array element;
these cases should be handled with variable width sequence-test expressions or
the `END` assertion.

Among the non-sequence match expressions, the `ANY`, `ALL`, and `WITH`
expressions adapt to the width of their arguments, and all others (classified
as node-test expressions) test a node in isolation.  The successor state
produced by a successful node-test expression is the position following the
current element; i.e. they consume one element.
Implementations are likely to need to iterate the successor states as they look
for an overall match for the array specification, but no specific order is
required for this iteration and implementations are free to apply optimizations
that eliminate impossible states, cache failure positions, or collapse
redundant successor states.  This also gives implementations the option to
optimize things with a DFA compilation when the specification is composed
purely of regular language constructs.

When attempting to resolve which successor state to use, each sequence can be
configured to resolve by preferred position, preferred length, or both.
The [`GROUP` expression](#ex-group) and its various aliases provide the means
to declare these preferences, as well as the ability to declare a name under
which the bounds of the match will be recorded.  The preferences and captures
are ignored for sequences in the same match state which occur inside of `ANY`,
`REP`, `CAN`, `CANT`, and `NONE` expressions.  The preferences are
resolved with respect to the entire match of the array, selecting among
successful matches; they do not restrict which spans can match.

Before each array match invocation, the algorithm must prepare by expanding all
pattern macros (or regex macros, in regex context) which can participate in
sequence matching, and evaluating the configuration of every participating
configured sequence.  These computed values must remain constant for the entire
match attempt; the choice of which macro to expand and how to resolve each
capture group may never have a dependency on the match position being tested
*during* the array match.
Preparation starts with the lexical environment in effect when the array-match
invocation begins.  It follows expressions operating on that array’s sequence
up to boundaries of node-match expressions, sub-structure matches, or function
calls.  This traversal must occur even for "lazy" evaluation mode on pattern
branches that are otherwise unused.
The current node is set to the array being matched, rather than the node that
would normally be implied by the position of the expressions.
This may involve evaluating `WITH` expressions (local to this preparation step)
along the path to the relevant sequences.
`WITH` normally gets to assume that `NODE` is an array element;
since it will instead be an array during preparation, errors need to be deferred.
If evaluating a `WITH` binding during preparation raises `RUNTIME_ERROR`,
retain the error as the value of that binding without raising it immediately.
The binding still shadows any previous value.  Accessing it during preparation
raises the retained error.  Except for errors retained in `WITH` bindings, any
error escaping configuration or macro-reference evaluation aborts the
preparation step.  A `RUNTIME_ERROR` is handled as failure of the array match;
other errors propagate according to the normal error rules.

Implementations may omit preference resolution wherever doing so cannot affect
the captures or overall match bounds returned by the enclosing match; however,
the preparation step must still be performed to ensure that any macro expansion
and group flags like `exact` get calculated correctly.
When only a boolean result is required, the algorithm may stop after finding
any match that satisfies the complete enclosing specification, but this does
not permit discarding successor positions needed to satisfy surrounding
expressions.

Of all the final states which can match the complete specification for the
array, the algorithm chooses one according to these priorities, using a
depth-first pre-traversal order of the sequences of the current array:

  * For each sequence having an active position preference:
    * Match nearest to the requested position.
  * For each sequence having an active length preference:
    * Longest or shortest match according to its preference.
  * Implicit "longest" goal for a match overall, if requested by the caller.
  * For each sequence having an active position or length preference:
    * Earliest ("leftmost") start of a match.
  * For each capture-producing substructure in the sequence specification:
    * <span id="earliest-substructure-match">Earliest array element at which
      the substructure matches.
      </span>

The first rule ensures that positions get priority, which is useful when a
pattern wants to locate expected values and then greedily capture surrounding
spans.  In this example, the "prefix" group wants a long match, but the
successful match with "target" closest to 5 will be preferred over the match
with the longest prefix.  If there are two matches with "target" equal distance
from 5, "prefix" breaks the tie pushing "target" to the latter position.

    [[
      [GROUP, "prefix", [REP]],
      [NEAR, 5, [GROUP, "target", {tag:"H3"}]],
      [GROUP, "suffix", [REP]],
    ]]

The fifth rule has no bearing on the boundaries of captures in the current
array; it resolves ambiguities in selecting which array element should provide
captures from deeper arrays or strings.  Consider this example:

    [[
      [REP],
      { a: [[ [GROUP, "from_a", [REP] ] ]] },
      [REP],
      { b: [[ [GROUP, "from_b", [REP] ] ]] },
      [REP]
    ]]

The substructure that captures "from_a" could match at *any* element of the
current array except the last, and the substructure that captures "from_b"
could match any element except the first.  The current array has no preferences
for any subsequence.  The "long" preference in the inner array has already
been resolved at that level before becoming a successful substructure match in
the context of the current array, so those sequences do not participate in
resolving the sequences of the current array.
This is given deterministic behavior by selecting the earliest candidate array
element.  In the example, this rule uses the captures from the earliest array
element having an array at property "a" followed by the first element after
that having an array at property "b".

To prevent excessive complexity (in both the specification and the
implementation) sequences with position preferences may not be nested within
the same array match, after macro expansion; doing so is an `INVALID_GRAFT`.
The intent, when combined with the preference rules above, is to allow an
implementation to simply iterate the sequences having a position preference,
testing what nearby position each can match by evaluating all its sub-sequences
using a temporary shortest-match preference.  If they are found where expected,
the actual length preferences can be applied, and then the remaining sequences
(which are likely to just be generic `REP` filler allowing the positioned
sequences to reach their desired index) can resolve quickly and the result is
found with minimal processing.  Of course, a more complex pattern can trigger a
lot of backtracking or require a more advanced algorithm to finish within
resource limits, but the common case should be fairly fast.

After a successful sequence-context match of an array, named sequences may
get carried as annotations to the current match state.  If the overall match
succeeds, the captures (which may be an empty set if no named sequences were
used) are available as output.  Uniqueness of capture names is only enforced
for the state selected by the final overall match, failing with `INVALID_GRAFT`
if there are duplicates.  Note that the quantity of captures from sequences in
the current array match is a constant, but the quantity and names of captures
from deeper matches may vary, since they are calculated.
Implementations may choose to test subtrees as if they were unobservable in a
first pass, and then resolve the deeper captures in a second pass after the
positions of sequences in the current array are resolved.
If successor captures from subtrees are generated eagerly, conflicts must be
flagged internally and not abort the match attempt unless that state would be
used in the final result.
If the match was occurring as the test of a `MATCH` or `IF` action, the
captures become the new state of the [capture namespace](#ex-cap) locally for
its contained actions.  If the match was occurring within a `CAPTURE` function,
the named captures become the properties of the returned object.

Examples:

Named groups on a subject of [1,2,3,4,5] in 'HAS' context:

    [[ [GROUP, {name: 1, long: false}, [REP,0,-1,[NUM,0,3]] ], // 0 or more [0..3]
       [GROUP, {name: 2, long: false}, [REP,0,-1,[NUM,0,5]] ]  // 0 or more [0..5]
    ]]

The captures are zero elements for each, because the initial position is a
valid final position, and the preference that both match the fewest elements
causes this position to be selected as the best match.

For the same subject in 'IS' context, the expression is implicitly:

    [[ [GROUP, {name: 1, long: false}, [REP,0,-1,[NUM,0,3]] ], // 0 or more [0..3]
       [GROUP, {name: 2, long: false}, [REP,0,-1,[NUM,0,5]] ], // 0 or more [0..5]
       [END]
    ]]

This results in an empty capture 1 and all elements in capture 2, because out
of the final states which can reach the end of the array, sequence 1
gets priority on a minimal length.  When you change both to `long: true`,

    [[ [GROUP, 1, [REP,0,-1,[NUM,0,3]] ],   // 0 or more [0..3]
       [GROUP, 2, [REP,0,-1,[NUM,0,5]] ],   // 0 or more [0..5]
       [END]
    ]]

the final state with the most elements for sequence 1 is a split of
`[1,2,3]` / `[4,5]`.

### Matching String Characters

JGraft can match the characters of a string using the same expressions used for
matching array elements, resulting in a fairly comprehensive equivalent to
"regular expressions" as seen in most programming languages.
The subject string is broken into a virtual array of characters, and then the
match expressions are applied to that virtual array, using all the same match
expressions as for arrays, though literal values are interpreted differently.
Character matching is defined over a sequence of Unicode code point values.
It is left to implementations or host languages to determine (or provide
configuration for) how input strings are converted to this sequence,
including the treatment of malformed encodings and unpaired surrogates.
For example, an implementation might reject malformed UTF-8 or strings
containing unpaired surrogates, replace malformed input, or expose surrogate
code points individually. These choices are outside the JGraft specification.

JGraft character classes may include surrogate code point values
(U+D800–U+DFFF). These can only match when the host's interpretation of the
input string exposes corresponding values in the character sequence.

When matching against a virtual character array,

  * Numbers match against the numeric value of codepoints.
  * Strings of one character match against the character itself.
  * Strings of zero or multiple characters are interpreted as `SEQ` expressions
    with empty string meaning an empty sequence.
  * No other types can match anything within the virtual array of characters.
  * Accessing an element of the array in value context returns the codepoint as
    a number.
  * If the current node is changed to something other than a virtual array
    of characters (via two-argument `HAS` / `IS`), the algorithm
    switches back to non-regex matching for the duration of that scope.

In some cases, only a boolean result is required, and the match ends as soon
as the expression is satisfied.  Other cases require finding the longest
match; for these, the match algorithm is given the implicit "longest" parameter
as described in the match resolution rules.

If an expression is constructed from only "textbook regular" match
expressions, an implementation can compile the expression into a DFA, or
possibly a host-language regular expression for improved performance.
Elaborate non-regular match expressions may be used in regex context, but can
cause a great deal of iteration and may quickly run into resource limits.

### Expression Summary

The following table is a summary of the available expressions.  The type column
distinguishes between Reference expressions, Match expressions with
sub-categories of node-matching or sequence-matching, and Function expressions.
The ID numbers are chosen to minimize encoding size of the most common
expressions, and to give lightweight implementations the ability to determine a
type from numeric ranges rather than requiring a table.

Name                     | Type    | ID | Description
-------------------------|---------|----|----------------------------------------
[CAP](#ex-cap)           | Ref     | -5 | A path in the capture namespace
[TEMP](#ex-temp)         | Ref     | -4 | A path in the temp namespace
[STASH](#ex-stash)       | Ref     | -3 | A path in the stash namespace
[CONST](#ex-const)       | Ref     | -2 | A path in the const namespace
[EX](#ex-ex)             | Ref     | -1 | Expression expansion/execution
[NODE](#ex-node)         | Ref     |  0 | A path in the current node
[ANY](#ex-any)           | Match   |  1 | Logical OR of match exprs
[ALL](#ex-all)           | Match   |  2 | Logical AND of match exprs
[HAS](#ex-has)           | Match:N |  3 | Partial structured match
[IS](#ex-is)             | Match:N |  4 | Exact structured match
[NONE](#ex-none)         | Match:N |  5 | Logical NOT of match exprs
[EXISTS](#ex-exists)     | Match:N |  6 | Node path exists
[ARRAY](#ex-array)       | Match:N |  7 | Match arrays, specific elements
[STR](#ex-str)           | Match:N |  8 | Match strings, optional regex
[NUM](#ex-num)           | Match:N |  9 | Match numbers, optional ranges
[BOOL](#ex-bool)         | Match:N | 10 | Match booleans
[DATE](#ex-date)         | Match:N | 11 | Match date-like things
[CHARS](#ex-chars)       | Match:N | 12 | Match to a set of characters
[WITH](#ex-with)         | Match   | 13 | Scoped overrides to TEMP namespace
[REP](#ex-rep)           | Match:S | 14 | Match repeatedly on adjacent elements
[START](#ex-start)       | Match:S | 15 | Match at first element of array
[END](#ex-end)           | Match:S | 16 | Match at length of array
[CAN](#ex-can)           | Match:S | 17 | Positive lookahead assertion
[CANT](#ex-cant)         | Match:S | 18 | Negative lookahead assertion
[SEQ](#ex-seq)           | Match:S | 19 | Match a sequence of adjacent elements
[GROUP](#ex-group)       | Match:S | 20 | Match a sequence, with configuration
[LONG](#ex-long)         | Match:S | 21 | Match a sequence, prefer longer
[SHORT](#ex-short)       | Match:S | 22 | Match a sequence, prefer shorter
[NEAR](#ex-near)         | Match:S | 23 | Match sequence nearest to position
[CAPTURE](#ex-capture)   | Fn      | 40 | Match, then return captured sequences
[DATA](#ex-data)         | Fn      | 41 | Provide expression-free literal data
[LOCAL](#ex-local)       | Fn      | 42 | Scoped overrides to select namespaces
[ACT](#ex-act)           | Fn      | 43 | Create an action macro
[VAL](#ex-val)           | Fn      | 44 | Create a value expression macro
[PAT](#ex-pat)           | Fn      | 45 | Create a structure-match pattern macro
[REG](#ex-reg)           | Fn      | 46 | Create a character-match pattern macro
[CASTBOOL](#ex-castbool) | Fn      | 47 | Cast value to boolean
[CASTNUM](#ex-castnum)   | Fn      | 48 | Cast value to number
[CASTSTR](#ex-caststr)   | Fn      | 49 | Cast value to string
[CASTDATE](#ex-castdate) | Fn      | 50 | Cast value to date/datetime/timestamp
[LENGTH](#ex-length)     | Fn      | 51 | Return length of an array or string
[PROPS](#ex-props)       | Fn      | 52 | Return properties of an object
[PROPV](#ex-propv)       | Fn      | 53 | Return property/value pairs
[MKOBJ](#ex-mkobj)       | Fn      | 54 | Construct an object from properties
[SLICE](#ex-slice)       | Fn      | 55 | Return span of an array or string
[CONCAT](#ex-concat)     | Fn      | 56 | Join spans of arrays or strings
[SPLIT](#ex-split)       | Fn      | 57 | Split a string into an array
[JOIN](#ex-join)         | Fn      | 58 | Join, using split metadata
[NOT](#ex-not)           | Fn      | 59 | Logical NOT of value exprs
[AND](#ex-and)           | Fn      | 60 | Logical AND of value exprs
[OR](#ex-or)             | Fn      | 61 | Logical OR of value exprs
[CASE](#ex-case)         | Fn      | 62 | If/else that returns a value
[FAIL](#ex-fail)         | Fn      | 63 | Fail with RUNTIME_ERROR
[CURPROP](#ex-curprop)   | Fn      | 64 | Get property/index of the current node.
[MAP](#ex-map)           | Fn      | 65 | Transform array elements
[REDUCE](#ex-reduce)     | Fn      | 66 | Combine array elements
[FILTER](#ex-filter)     | Fn      | 67 | Select array elements
[LESS](#ex-less)         | Fn      | 68 | Less-than test
[LESSEQ](#ex-lesseq)     | Fn      | 69 | Less-or-equal test
[ADD](#ex-add)           | Fn      | 70 | Add numbers
[SUB](#ex-sub)           | Fn      | 71 | Subtract numbers
[MUL](#ex-mul)           | Fn      | 72 | Multiply numbers
[DIV](#ex-div)           | Fn      | 73 | Divide numbers
[MOD](#ex-mod)           | Fn      | 74 | Calculate Modulus
[POW](#ex-pow)           | Fn      | 75 | Calculate exponents
[LOG](#ex-log)           | Fn      | 76 | Calculate logarithms
[ROUND](#ex-round)       | Fn      | 77 | Decimal rounding on numbers or strings

### Expression Interaction

To quickly understand how the types interact, consider these examples:

    [IS, { "a": [ANY, false, true, { c: 2 }] }]
    // implies [IS, { "a": [ANY, false, true, [IS, { c: 2 }]] }]
    // node.a === false || node.a === true || node.a.c === 2

In this case, the outer match expression passes `node.a` as the current node,
and an `IS` context.  The `ANY` expression tests whether `node.a` matches
against any of the values.  When it tests the third value, it performs an
`IS` operation rather than the default of `HAS`.  The boolean result of `ANY`
is consumed as the result for whether property 'a' matched.

    [IS, { "a": [NONE, { "b": 1 }] }]
    // implies [IS, { "a": [NONE, [IS, {"b": 1}]] }]
    // !deep_equals(node.a, {b:1})

In this case, the outer `IS` match expression passes `node.a` as the current
node to the `NONE` expression with `IS` context.  The `NONE` expression tests
whether `node.a` is not exactly identical to `{b:1}`.

    [IS, [NODE,"a"], [NODE,"b"] ]
    // deep_equals(node.a, node.b)

The `IS` and `HAS` expressions have a 2-argument form to specify both the
pattern and the target to match.  In this case, `node.a` becomes the current
node, and `node.b` becomes the fully-evaluated structure to match against.

Return values from functions are considered to be data to match against, and
do not participate as match specifications:

    [IS, { "a": [OR, [NOT, [EXISTS]], true] }]
    // node.a === true
    // probably not what was intended

In this example where someone probably meant to use `ANY` instead of `OR` and
`NONE` instead of `NOT`, a match expression calls a function (non-match
expression) and uses the return value as *a value to match against*.
`EXISTS` returns `true`, `NOT` negates it to `false`, and `OR` returns
`true || false` so `node.a` is compared to `true`.

    // This doesn't work:
    [IS, { "a": [LESS, [CASTNUM], 8] }]
    // This does:
    [IS, { "a": [IS, [LESS, [CASTNUM], 8], true] }]
    // (parseNumber(node.a) < 8) === true

If you want the return value of a function to be used as the match *result*,
simply use the two-argument form of `IS` or `HAS` to compare it to `true`.
In this case, `LESS` is not a match expression so it can't be used directly
within the structure of the outer `IS` in the intended manner.
The inner `IS` compares two values instead of comparing one value to the
current node, and the return value gets consumed as the match result because
`IS` is a match expression.

## Math

Portable JGraft includes the expectation of at least 15 decimal digits of
numeric precision and decimal exponents from −307 through +307, which is
provided in most environments by IEEE double precision math.  15 digits is also
the baseline for lossless representations of integers.  Implementations
may provide more digits, 64-bit integers, or even "big integer" or rational
number support, but this is not required.  No specific rounding mode is
required as long as the precision requirement is met.  JGraft does not
guarantee an exact outcome for math, only that the precision and exponent scale
meet a minimum threshold.

Against these requirements:

  * An implementation providing the portable numeric baseline reports numeric
    execution failures as `RUNTIME_ERROR`.
  * An implementation providing only partial numeric support may report
    `UNSUPPORTED_GRAFT` when its missing numeric capabilities prevent
    execution.
  * Implementations may support a wider range and succeed where others report
    `RUNTIME_ERROR`.

Some expressions require that integer digits not be lost or rounded; if the
number exceeds an implementation's available integer precision, the expression
must fail using `RUNTIME_ERROR` or `UNSUPPORTED_GRAFT` as described above.

JSON does not include encodings for Infinity or Not-a-Number, and so in the
default configuration calculations on floating point values must not return
these results.  Calculations that overflow or return infinity in the host
language's math system should fail.  Implementations must also fail when
underflow to zero occurs; at each arithmetic step, using the host
representation of its operands, a mathematically nonzero result that becomes
zero because its magnitude is below the implementation’s supported range must
fail.  Implementations may additionally choose to fail when the host arithmetic
engine reports underflow, including nonzero subnormal results.  Implementations
may also define a minimum supported nonzero magnitude and reject smaller
results.  These policies must be documented.  Logically impossible computations
that result in not-a-number, domain or range error flags, etc. should always
fail with `RUNTIME_ERROR`.

Implementations may give the application the option of preserving infinity
values in the output (and using them as input to other expressions where that
makes sense) instead of failing, but the implementation must then also document
the behavior of this extension.
Even then, division by exactly zero should always fail with `RUNTIME_ERROR`
rather than returning an infinity value.

## Errors

Applying a JGraft to a target data structure may fail with:

  * `NO_MATCH`        - The JGraft explicitly rejected the input data as
                        not meeting its preconditions.
  * `RUNTIME_ERROR`   - The calculated arguments to an operation are the wrong
                        type, or are impossible to execute correctly.
  * `INVALID_GRAFT`   - The structure of the JGraft itself or literal arguments
                        to an operation violate the spec.
  * `UNSUPPORTED_GRAFT` - The graft requires data or operations that the
                        implementation’s host environment cannot faithfully
                        represent or perform, including insufficient version
                        support or use of forbidden object property names.
  * `RESOURCE_LIMIT`  - Applying the graft would exceed configured limits.

Ideally (when supported by the implementation and within resource limits),
a logically valid JGraft should either succeed or generate `NO_MATCH` and a
logically invalid JGraft should result in `INVALID_GRAFT`.
A graft generator *ought to* generate comprehensive `MATCH` / `IF` tests to
ensure that the data is the expected shape before using the data in computed
arguments, in which case any runtime error that occurs is logically a fault of
the graft.  However, graft generators are permitted to take the shortcut of
probing paths or computing values during a match and letting the runtime
failure act as an indication of "it doesn't match".  However, treating
all invalid grafts as "it doesn't match" would hide generation defects that
a developer likely wants to know about.  The compromise is that malformed
JGraft structures and all locally-invalid arguments (described in further
detail below) count as `INVALID_GRAFT`, and immediately abort execution.
Every other type of logical error is `RUNTIME_ERROR`; inside a match expression
they are trapped and converted to a false match, and outside of a match they
immediately abort execution the same as `INVALID_GRAFT`.

When trapping `RUNTIME_ERROR` inside of a match, they get trapped at the
innermost match expression, including any implied `IS` or `HAS` expression
within a structural match or where a match expression calls a value expression.
However, since failed matches propagate upward through other match expressions
where the subexpression was not optional, an implementation really only needs
to trap errors around each argument of `ANY` and `NONE`, at `CANT` (to return
true), around each successor state being investigated during a sequence match,
and at the outermost match expression that initiated the match state.

Aside from structural or logical errors, grafts can fail if the implementation
simply can't execute them for some reason, such as missing functionality or
exceeding configured resource limits.  The `UNSUPPORTED_GRAFT` and
`RESOURCE_LIMIT` errors always immediately terminate the graft operation
regardless of match context.  Likewise, unspecified errors from application
callbacks or other implementation aspects should terminate the graft operation.

The `UNSUPPORTED_GRAFT` error covers the basic case of a `JGRAFT` action
declaring a version the implementation doesn't support.  It also covers cases
where a host language or environment is unable to represent (or is restricted
from representing) certain things that are legal in JSON's data model.
For example, on older JavaScript engines, the `__proto__` property is
problematic and implementations may entirely forbid use of that property in
any expression or generated value.  Other non-JavaScript implementations may
also provide an option to forbid that property in order to ensure a graft is
compatible with old JavaScript implementations.

### Validation

The following conditions cause an `INVALID_GRAFT` error:

  * A type is encountered for which the implementation has no defined behavior.
  * An array in a context where directives are permitted lacks a first element.
  * A directive array (excluding escaped arrays) has a first element which is
    not a known directive name or ID.
  * A directive has an illegal number of arguments.
  * A literal object used to supply a collection of optional named arguments
    (not general data) contains unknown or incompatible sets of properties.
  * The pre-evaluation type of an argument (including optional arguments
    supplied in literal objects) does not intersect the domain of the argument.
    Pre-evaluation types are determined as:
      * Literals: the known type of the value.
      * `LOCAL` expressions: the pre-evaluation type of its root expression
      * `FAIL` expressions: always fail with `RUNTIME_ERROR` and are exempt
        from type tests.
      * Any other expression: the range of possible return types of the root
        expression without considering its contents.  Reference expressions and
        `CASE` are assumed to be any type.
  * Pre-evaluation types do not intersect between supplied arguments which must
    match.  For example, `CONCAT` requires all arguments to be strings or all
    arguments to be arrays.  `FAIL` expressions are still exempt.
  * A literal argument value (including optional ones supplied in literal
    objects) does not match the domain explicitly specified for that argument.
    Arguments other than literal objects of named arguments are considered
    opaquely; array length or object properties are not used to narrow the
    domain of other arguments.
  * Two or more literal argument values (including optional ones supplied in
    literal objects) violate a constraint between them, like `pos <= lim`.
    If an array length is used to interpret a literal alias, it is not truly
    a literal and is exempt from this check.
  * A sequence-test match expression is encountered in a context where only a
    single node may be matched.
  * A regex-context macro (`REG`) gets expanded outside of regex context, or a
    structure-match macro (`PAT`) gets expanded inside regex context.
  * The final resolved captures of a match expression would contain duplicate
    capture names.

These rules are chosen to be easy to implement without deep semantic analysis,
but still broad enough to usefully catch bugs in generators.
All implementations must consistently generate `INVALID_GRAFT` rather than
`RUNTIME_ERROR` when encountering these cases.  Implementations are permitted
to attempt execution and resolve the cause of the error in an exception path.
In some cases this may result in `RESOURCE_LIMIT` where an `INVALID_GRAFT` has
also occurred, which is permitted.

Implementations are permitted to lazily evaluate directives.  In order to
provide portability across implementations, all implementations must provide a
lazy-evaluation mode.  In lazy mode, validation of a directive operand occurs
when evaluation requires that operand.  Operands skipped by flow control are
not validated.  Errors from validation, including `INVALID_GRAFT`, are
deferred.  A structurally invalid graft may apply cleanly so long as the
structurally invalid portions do not need to be executed.  It also means that
implementations which compile the full JGraft before execution must include the
ability to hold the deferred validation errors in the optree nodes, including
within parsed macros.

The mandatory [array-match preparation step](#matching-arrays) also applies in
lazy mode, including preparation of otherwise unused pattern branches.

More robust implementations are encouraged to provide various degrees of
validation prior to execution, such as checking for all the `INVALID_GRAFT`
conditions above throughout the JGraft tree, or even performing deeper static
analysis to look for logical impossibilities.  Implementations may choose to
make full validation the default mode, or let validation emit warnings by
default while still executing as if lazy validation were used.  The degree of
validation should always be configurable so that applications can make use of
grafts that were working on less strict implementations.

When performing static analysis, there are two categories which must never
prevent execution, both of which are intended to make generators easier to
write.  First, it is never a fatal error for match subexpressions to be
mutually exclusive to each other.  This allows results from multiple expression
generators to be combined without worry that a resulting logical impossibility
will cause a recipient to reject the graft.  For example:

    [ALL,
      {offset: "2"},
      [IS, [SLICE, [NODE, "offset"], "abcdef"], "c"]
    ]

The first condition only passes when `offset` is the string "2", which
guarantees that the second condition will receive the wrong type for the
argument of `SLICE`, and trigger a `RUNTIME_ERROR`.  But, in isolation
the second expression's correctness still depends on input data, so in a match
context this is not considered an invalid graft, just one that never matches.
A more intelligent generator could eliminate this subexpression, but is not
required to, regardless of the configured JGraft validation level.

Second, a logical `RUNTIME_ERROR` guarded behind flow-control (including
short-circuiting behavior of `AND` / `OR` / `NOT`) that unconditionally
prevents it from occurring for all inputs should never become a fatal error.
Validators may warn about these cases, but should not use them as a reason to
reject the graft prior to executing it.  For example:

    [OR, true, [LENGTH]]                     // INVALID_GRAFT
    [OR, true, [LESS,"a",[CASE,[NUM],1,2]]]  // RUNTIME_ERROR

The first expression is an `INVALID_GRAFT` because `LENGTH` always returns an
integer, not a boolean.  In lazy evaluation mode it will not be detected, due
to the short-circuiting of `OR`, but in a higher validation level, the graft
should be rejected before starting execution.  The second expression includes a
`LESS` subexpression which will always fail with `RUNTIME_ERROR` since the
arguments are not of the same type.  A lazy evaluation mode will never detect
this either, due to short circuiting.  If a more robust implementation detects
this through static evaluation, it may warn but must not reject the graft.

### Resource Limits

One of the design goals for JGraft is to provide a language for editing data
which can safely handle untrusted input; however, this language can describe
operations that require infinite memory and execution time.
Every implementation must enforce limits for memory and execution, and should
provide a means for applications to tune these limits.  At a minimum, there
should be a counter for memory allocated and another for processing effort
expended, and exceeding either should abort execution of JGraft with
`RESOURCE_LIMIT`.  Implementations must also track any other resource that gets
consumed on their particular platform.  For instance, if the total number of
objects allocated in the system degrades the performance of the host language
garbage collector, then there should be a limit on total objects created in
addition to just the memory consumed by them.  If the implementation is using
the host language call stack to implement JGraft expressions, it should include
a limit on call stack depth.

The specifics of how these are implemented and configured are left to each
implementation.  The implementation should document the model used, and where
possible, give the application tools to estimate the limits in terms of
real processing seconds and physical bytes of memory.

### Failure State

When applying a graft fails, the recommended behavior for an implementation is
to emit the error along with some diagnostic properties describing the current
node and action/expression which failed, and make the partially-edited data
structure available for inspection.  Implementations may also provide a
callback allowing the application to intercept a failure and resolve it in a
way that allows the remainder of the JGraft to continue.

Ideally, an implementation should be shallow-cloning each ancestor node of an
altered node back to the root as edits occur, so that the input data structure
remains unchanged while the output gets to share un-altered sub-trees.  This
isolates the partially-edited error state from the input data.  However, if
shared structures are difficult for the host language or it is understood that
the input data has already been deep-cloned for the library's exclusive use,
the implementation may just mangle the input tree and provide that to the user
as-is during errors.

Implementations are also encouraged to provide an option of building an
"undo" JGraft describing how to revert the changes it made.
If this option is enabled, during an error it should deliver one to the caller
that describes how to restore the original from the current mangled state.

## Actions

### <span id="act-jgraft">JGRAFT</span>

    ['JGRAFT', metadata, action1, action2...]

This action is used for the top-level of an exported JGraft, or optional
metadata deeper within the structure.
When serialized to JSON, the top-level 'JGRAFT' action name is not replaced by
a number, and there should be no whitespace until after the following comma.
This gives JGraft JSON files a "magic number" of

    ["JGRAFT",

The `metadata` is an object with semi-free-form properties, where top-level
names matching `/^[a-z][A-Za-z0-9]*$/` are reserved for the protocol, and any
others are user-defined.
The following properties are currently defined:

  - v: integer; the minimum JGraft specification version required to
       correctly interpret the contents of this structure
  - writer: a string identifying the tool that authored the structure
  - comment: a free-form text comment string
  - const: an array declaring constants

When exported to JSON, outer metadata should contain `v` (minimum version
to correctly process the structure), and it should be at least as high as
any minimum version seen within.  It is permitted to declare `v` on
sub-structures, for composability between different sources.
Future versions of the JGraft specification are expected to be backward
compatible, but if incompatibilities arise, implementations should aim to
support older versions dynamically so that they can process sub-structures
generated according to a prior specification.  If an implementation encounters
a version other than the ones it knows it supports, it must immediately fail
with `UNSUPPORTED_GRAFT`.

For user-defined properties, a good pattern is to use a unique-ish property
name containing a period (such as Java-style reverse domain name) or other
special character like '#ProjectName' and place all custom data within an
object under that.

The `JGRAFT` action acts like a scope for declaring constants and common
expressions, and also provides a fresh empty `stash` of shared temporary
variables for the actions within it.
The algorithm when beginning a `JGRAFT` action is roughly:

  - Verify the version `v` is supported.
  - If the metadata contains a `const` property,
    - Set the `const` namespace to a shallow clone of any inherited `const`
      namespace, or an empty object at the root.
    - For each (`name`,`val_expr`) pair of elements in the `const` array,
      - `name` must be a single property string, or integer (which gets
        coerced to a string)
      - Evaluate `val_expr` in [value context](#value-context).
        Within, `CONST` expressions evaluate according to the `const` namespace
        in its current state before this assignment.  `STASH` expressions still
        refer to the parent scope's stash, if one exists.
      - Set property `const[name]` to the value.
  - Set the `stash` namespace to a new empty object.

### <span id="act-raise">RAISE</span>

    ['RAISE', level, message]
    ['RAISE', level, message, data]

As JGraft applies a patch it may emit diagnostic information, such as when
a match succeeded at an offset from the requested position.  You can emit your
own custom diagnostics as well, using this action.  The motivation is that while
a tool like `patch` can make a fairly straightforward diagnostic about why
applying a text diff failed, a JGraft mismatch can be much harder to explain.
An author of a JGraft might have more domain-specific information about why
something wouldn't match, and can encode that with some `IF` actions in a way
that the graft operation fails with a useful error message.

The `level` argument (literal non-expression) is one of the following strings,
or the corresponding ID:

String | ID | Meaning
-------|----|----------------------------------------------------------------
"info" |  0 | shown if the user asks for details
"warn" |  1 | flagged for the user even if they didn't ask for details
"fail" |  2 | a fatal error that ends the graft attempt with `NO_MATCH`

`message` is evaluated in [value context](#value-context).  It must resolve
to a string and should be generally printable, and may not contain Unicode
Surrogates, Noncharacters, or control characters (codepoints 0x00–0x1F and
0x7F–0x9F).

`data` is also evaluated in [value context](#value-context) but may resolve
to any type of value.  It provides data to the user relevant to the message.
This may be shown to the user in some form such as JSON, or inspected
programmatically by code using a JGraft library.
If the data is not being consumed immediately, implementations should ensure
that it remains stable, such as deep-cloning it or setting up copy-on-write.
This is already handled if the standard operation of the engine is to
shallow-clone the ancestors of each change.

### <span id="act-at">AT</span>

    ['AT', path, subaction1, subaction2...]

Navigate to a [path](#paths) within the current node, then execute actions.

The `path` argument (path context) must refer to the current node or an
existing sub-node of it; it cannot jump to a different namespace. This will
become the current node for the duration of the execution of the sub-actions.

### <span id="act-atsplit">ATSPLIT</span>

    ['ATSPLIT', path, split_spec, subaction1, subaction2...]

Navigate into a tokenized view of a node, then execute actions.

This is a combination of the `AT` action and `SPLIT` + `JOIN` expressions.
For a target node at `path` (path context), it changes the current node to the
array returned by the [`SPLIT` function](#ex-split) called on the target node
according to `split_spec` (value context) then executes actions on that array.
After all subactions complete, the value of the current node (which may not
even be the same array after `COPY` or `MOVE`) is passed to the
[`JOIN` function](#ex-join) using the same value of `split_spec` to build a new
string value for the target node.  The `path` argument is defined per the `AT`
action, and the `split_spec` argument is defined per the `SPLIT` function.

The `split_spec` is evaluated prior to changing the current node to `path`, and
not evaluated a second time during the implied `JOIN` operation, nor is `path`
evaluated a second time when assigning the new value.

`ATSPLIT` is similar to the following, but with the added benefit of changing
the current node to the temporary array, whereas the example below would need
to repeatedly act on `[STASH,0]` during the subactions:

    [COPY, split_spec, [STASH,"split_spec"]],
    [AT, path,
      [COPY, [SPLIT, [STASH,"split_spec"]], [STASH,0]],
      subaction1,
      ...
      subactionN,
      [COPY, [JOIN, [STASH,"split_spec"], [STASH,0]], [NODE]]
    ]

`ATSPLIT` is the primary tool used to re-implement text diff/patch behavior:

    [ATSPLIT, [NODE],
      { sep: [REG, [ANY, "\n", "\r\n"]],
        default: "\n",
        trim: [REG, [REP,0,-1," "]]
      },
      [MATCH,
        [[
          [NEAR, 9,
            "Line ten",
            [GROUP, "edit",
              "Line eleven",
              "Line twelve"
            ],
            "Line thirteen"
          ]
        ]],
        [SPLICE, [NODE], [CAP, "edit"],
          "New Line eleven"
          // no line 12
        ]
      ]
    ]

The pattern searches for the four context lines nearest index 9.  The `edit`
capture identifies the two lines to replace, so the splice follows the match
even when preceding lines have been inserted or removed.

### <span id="act-match">MATCH</span>

    ['MATCH', match_spec, subaction1, subaction2...]

Execute actions on a node having the intended shape.

Assert that the current node matches a [match specification](#match-context),
then execute all sub-actions in sequence.  If it doesn't match, the graft
operation will fail with `NO_MATCH`.

The captured sequences of the match expression (even if the empty set) become
the [capture namespace](#namespaces) for the subactions.
Sub-actions can use the resulting named captures to edit the matched region.
Captures from a parent action's match are no longer visible, but could be
copied to the `STASH` namespace in an action before this if you need to access
them in the inner scope.

When using the `NEAR` expression to locate a pattern, the captures convey the
discovered offset to the actions that edit them, analogous to how Unix `patch`
applies a hunk at an adjusted offset.  Unlike Unix `patch`, literal array
offsets in sub-actions are not adjusted automatically.  Captures do not need to
be used directly; actions may be written using expressions that calculate
offsets from the captured bounds.

### <span id="act-if">IF</span>

    ['IF', match_spec1, action, else_action]
    ['IF', match_spec1, action1, match_spec2, action2... else_action]

Conditionally apply actions.

For each pair of (`match_spec`,`action`) processed in sequence, test whether
the current node matches `match_spec`.  If so, apply the action and stop,
else continue to the next pair.
If the list ends with a single element, it is treated as an "else" action.
Lacking an "else" action, the `IF` action completes successfully even if
no sub-action was performed.  If the sub-action fails with an error, the
`IF` action likewise fails.

Each condition uses the same [matching rules](#matching) as `MATCH`, including
any sequence searches specified by the pattern.  Conditions are processed in
argument order; a successful search in an earlier condition selects its action
even if a later condition would match at its exact requested position.

For a successful condition, the captured sequences of the match expression
(even if the empty set) become the [capture namespace](#namespaces) for the
condition's action.  The "else" action still sees the inherited capture
namespace.

### <span id="act-copy">COPY</span>

    ['COPY', val_expr, path]
    ['COPY', val_expr1, path1, val_expr2, path2, ...]

Construct/clone values and assign them to paths.

For each pair of (`val_expr`, `path`), evaluate `val_expr`
([value context](#value-context)) then assign the result to the `path`
([path context](#path-context)).  Each pair sees the effects of the previous
assignment.

Objects along the property path being assigned will be auto-vivified if they
don't exist, but the action fails if it would need to convert a scalar, object,
or array to a different type in order to resolve the destination.
Recall that arrays are implied when an object path contains a
number, and objects are implied when the path contains a string.
To prevent inappropriate creation of sub-objects, use a containing `MATCH`
directive that asserts the presence or absence of the structure as desired.
Unlike in JavaScript, assigning to (or a path through) an array element greater
than `LENGTH` does not auto-vivify, and fails.

Examples:

    ['COPY', {x:1,y:1}, 0]               // node[0]= { x: 1, y : 1 };
    ['COPY', 5, [NODE, 0,'x']]           // node[0].x= 5;
    ['COPY', 6, [NODE, -1,'x']]          // node[node.length-1].x= 6;
    ['COPY', {x:6}, false]               // node[node.length]= { x: 6 };
    ['COPY', [NODE,'a',4], [NODE,'b',0]] // node.b[0]= clone(node.a[4]);
    ['COPY', null, 'a']                  // node['a']= null;
    ['COPY', [NODE], 'a']                // node['a']= clone(node);
    ['COPY', [[1,2,3]], 'a']             // node.a= [1,2,3];
    ['COPY', [NODE], [TEMP,0]]           // temp['0']= clone(node);
    ['COPY', [TEMP,0,'a'], 'b']          // node.b= clone(temp['0'].a);
    ['COPY', [TEMP,0,'b'], 'a']          // node.a= clone(temp['0'].b);
    ['COPY', [NODE,'a'], [TEMP,0]]       // temp['0']= clone(node.a);
    ['COPY', [NODE,'b'], 'a']            // node.a= clone(node.b);
    ['COPY', [TEMP,0], 'b']              // node.b= clone(temp['0']);
    ['COPY', [NODE,'b'], [STASH,0]]      // jgraft.stash['0']= clone(node.b);
    ['COPY', [CONST,'big_data'], 'b']    // node.b= clone(jgraft.const.big_data);

### <span id="act-move">MOVE</span>

    ['MOVE', src_path1, dst_path1]
    ['MOVE', src_path1, dst_path1, src_path2, dst_path2, ...]

Relocate subtrees from a source property to a destination property without
copying them.

For each pair of (`src_path`,`dst_path`) processed in sequence:

  1. Resolve any expressions within the paths to establish concrete property
     lists.
  2. Verify the source exists and that the destination can be written in the
     state that would exist after removing the source, taking auto-vivification
     into account.
  3. Delete/detach the source value from its container.
  4. Assign/attach the subtree or value to the destination.
  5. Record any deferred array operations that are required.

It is permitted to delete a source property and then immediately auto-vivify
through that same property to create the destination.  If `src_path` and
`dst_path` are the same, the pair is essentially a no-op.
`src_path` and `dst_path` are both [path context](#path-context) with the
exception that a literal `null` may be used as `src_path` to write a literal
`null` value to `dst_path` (which lets you preserve the existence of a
property that would otherwise get deleted without needing a follow-up `COPY`
action to fix it) or as `dst_path` as a way of requesting deletion of the
property without preserving the value anywhere.  `MOVE` may use the current
node itself as a source (implying deletion) so long as something is written to
replace it before the end of the `MOVE` action; this way no actual deletion is
required on the parent container and the current node remains defined for the
next action.  (Note that it is not possible for the parent of the current node
to be visible from a different namespace, so it doesn't matter how an
implementation handles this temporary deletion)
The `MOVE` source may never be the root of a namespace other than the current
node; attempting to move to or from one, or any read-only namespace path in
general, fails.  A structurally invalid source or destination also fails.

When the source property is an element of an array, the deletion of the
element implies that following elements will be shifted up to fill the gap.
However, this shifting and the corresponding change to `LENGTH` does not occur
until after all pairs have been processed.
Attempts to access the value of an array element pending deletion fail,
including expressions like `SLICE` that attempt to clone
every element in a span of an array.  Moving an array with deletions pending is
not a problem since there is no need to enumerate the elements.  An `EXISTS`
test on the element still returns true, since `EXISTS` does not actually need
to read the property, just observe that a property of the container exists.
The deleted array index may still be used as a move destination, and writing a
new value to it (or through it) also cancels the deletion for that index.
For purposes of destination-path auto-vivification, an array index pending
deletion is treated as nonexistent.
The queued deletions (along with the metadata of being inaccessible to source
paths) bind to the instance of the array, following it even if it moves to a
different namespace.  Implementations need to also consider that the array
can get implicitly deleted from the tree if an ancestor node is overwritten or
deleted.

A second special case for arrays is that the final element of a path ending
within an array may refer to a "half index" of the array, like 1.5.
Values written to half-index elements get queued for insertion, to be applied
during the same process that performs deletions at the end of the `MOVE`
action.  They also have no immediate effect on `LENGTH`.
Elements written to a half-index are inaccessible from any namespace; you
cannot subsequently use them as source paths, nor write through them to deeper
sub-paths, nor auto-vivify through them.  If you need to modify a value that
will be written into a half-index, first move it to the temporary namespace,
apply subsequent `MOVE` pairs to it, then move from the temporary to the
half-index path.

Negative half-index values are permitted in mostly the same manner that
negative array indices alias positive indices, however -0.5 refers to the
insertion point before element 0 rather than after the final element of the
array.  Enumerated for an array currently of length 2, destination array
indices are handled like this:

Index  | Behavior
-------|--------------------
-0.5   | Queue insertion before element 0
 0     | Overwrite element 0
 0.5   | Queue insertion between 0 and 1
 1     | Overwrite element 1
 1.5   | Queue insertion after element 1 and before a potential element 2
 2     | Append immediately as element 2
 2.5   | Fail
 false | Append immediately as element 2
 -1    | Overwrite element 1
 -1.5  | Queue insertion at `0.5`
 -2    | Overwrite element 0
 -2.5  | Queue insertion at `-0.5`
 -3    | Fail
 -3.5  | Fail

In that chart, "append immediately" *does* imply an immediate change to the
array `LENGTH` which is seen by subsequent pairs and used to interpret negative
aliases.

The `MOVE` action modifies [`SPLIT` metadata](#split-metadata) in parallel
according to roughly the same rules as above.  Moves from an array element with
metadata to a half-index or deleted position or append-position of an array
move the element metadata as well, unless the target array already has `SPLIT`
metadata with a different `origin`.  This includes when moving to auto-vivified
arrays.  Deletions to source array elements also delete the element's metadata.
Moves to existing, non-deleted array elements overwrite the value while
preserving the destination's metadata, per normal "overwrite" semantics.
Moving a value lacking element metadata to a previously deleted array index
counts as an insertion for these purposes, and receives normal adjacent element
metadata.  The process of applying adjacent element metadata is postponed until
the `MOVE` action finishes and the final order of elements is known.
Note that if you move a value to the top of the TEMP namespace or other object
property, it will lose the array element metadata, whereas moving to an
auto-vivified array within the TEMP namespace will not.

At the end of the `MOVE` action, every array instance where an insertion or
deletion was queued gets conceptually rebuilt from the list of remaining
elements (including half-index elements) in the numeric order of their index.
If multiple values were queued to the same half-index they get enumerated in
the same order the assignments happened.

The practical consequences of these restrictions and special array handling
are:

  - No expensive deep-copying of objects is required, nor processing to
    determine whether deep-copying would be required.
  - It is not possible to degrade the data from a tree to a graph, because
    for every reference added, the old reference is immediately destroyed
    (or made inaccessible).
  - Arrays do not get resized or shifted on every single move pair
  - If an editor has re-ordered the elements of an array, and knows the source
    and destination index of each, it can easily export that edit as a `MOVE`
    argument list from those pairs by subtracting ".5" from each destination.
    Every deletion will be paired with an insertion and the `MOVE` action can
    run in `O(N)` time without actual splice() calls.

Examples:

    ['MOVE', 0,[TEMP,0],           // tmp['0']= node[0];
                                   // restrict(node, 0);
            -1,0,                  // node[0]= node[node.length-1];
                                   // unrestrict(node, 0);
                                   // restrict(node, node.length-1);
            [TEMP,0],-1]           // node[node.length-1]= tmp['0'];
                                   // unrestrict(node, node.length-1);
                                   // delete tmp['0'];
    
    ['MOVE',1,-0.5,2,false]        // pos0_queue= [ node[1] ];
                                   // restrict(node, 1);
                                   // node.push(node[2]);
                                   // restrict(node, 2);
                                   // node.splice(1,2);
                                   // node.splice(0, 0, ...pos0_queue);
    
    ['MOVE','a','b','c','a']       // node.b= node.a;
                                   // delete node.a;
                                   // node.a= node.c;
                                   // delete node.c;
    
    ['MOVE',[NODE,'x','x'],[TEMP,0], // tmp['0']= node.x.x;
                                     // delete node.x.x;
            'x',[TEMP,0,'x'],        // tmp['0'].x= node.x;
                                     // delete node.x;
            [TEMP,0],'x']            // node.x= tmp['0'];
                                     // delete tmp['0'];

### <span id="act-splice">SPLICE</span>

    ['SPLICE', path, option_args, replacement1, replacement2...]

Replace a span of an array, just like the splice function found in most
programming languages.  The `path` argument is specified in path context and
`option_args` in value context.  There are two permitted combinations:

  * If `option_args` evaluates to an integer, `path` must refer to an element
    of an array (or its insertion point at `LENGTH`).  That index supplies the
    offset.  A non-negative integer supplies `len`; a negative integer supplies
    a limit counting backward from the length of the array.
  * If `option_args` evaluates to an object, `path` supplies the source node.
    The object accepts the same optional `ofs`, `len`, `lim`, and `path`
    properties as the object configuration of [`SLICE`](#ex-slice), with the
    same defaults, alias resolution, and constraints.  At least one of `ofs`,
    `len`, or `lim` must be supplied.  The object's `path`, if present, is
    relative to the source node; the resulting target must be an array.
    A complete [capture object](#ex-cap) can be used directly as these options.

The resulting offset must fall in `[0..LENGTH]` and the limit in
`[offset..LENGTH]`, using the target array's length.  The path and options are
evaluated before mutation and are not reevaluated during the splice.

The replacement arguments ([value context](#value-context)) are each evaluated
before making any alteration to the target array.

If [`SPLIT` metadata](#split-metadata) is present on the array it gets likewise
spliced.  The replacement values may also introduce `SPLIT` metadata to the
target array if none was present, in the same manner as if each element of the
result of the splice had been inserted at the end of a fresh array.

### <span id="act-while">WHILE</span>

    [WHILE, test_expr, actions...]

Evaluate `test_expr` and if true, execute `actions` and repeat.

The `test_expr` (value context) is any expression that evaluates to a boolean.
It is evaluated, and then only if it is true, each of the `actions` is
executed in sequence.  This process repeats until `test_expr` returns false.

This action often requires the use of loop variables in the `STASH`
namespace, since only actions can mutate data, and the `TEMP` namespace is
local to each action, and other non-input namespaces are read-only.  Iteration
might also be controlled by mutating the input data.  The loop variables can be
initialized in an action prior to the `WHILE` loop.  There is no "break" or
"continue" flow control available.

### <span id="act-call">CALL</span>

    [CALL, action_ref]
    [CALL, action_ref, stash_prop1, value1, ...]

Executes an action object while also optionally making lexical overrides to the
root of the `STASH` namespace.

The `action_ref` argument is declared in path context, but with a default
namespace of `CONST` for single scalars.  For each stash override pair,
`stash_prop` must be a simple string or integer to be used as a property name
of the `STASH` namespace and `value` is any value-context expression.

Before the call, the stash is first shallow-cloned.  For each lexical override
pair, the value is evaluated with the temporary stash in scope, and then
assigned to the specified property of that temporary stash.  As `CALL`
finishes, the former root object of the STASH is restored.  This means that
for subtrees that existed prior to the call which were not overridden, changes
by the called action will remain, but the lexical overrides and any changes
within their subtrees will be reverted.

Action objects are created using the [`ACT` expression](#ex-act).

## Expressions

### Reference Expressions

#### <span id="ex-ex">EX</span>

    [EX, path]

Expand and execute a pre-defined expression macro object.

The `path` (path context) defaults to the `CONST` namespace for simple scalars,
but any path expression may be used here.  It must resolve to an expression
macro object, as created by `VAL`, `PAT`, or `REG`.  The referenced expression
replaces the `EX` expression as if it had been written there literally, however
the type of the macro must match the environment to which it is being inserted.
Regex macros cannot be applied to normal arrays, nor can structural patterns be
applied in a regex context.  Value expressions may be expanded in match
contexts with the usual behavior.

It is possible to set up infinite recursion using `EX` references, but likely
to quickly run into `RESOURCE_LIMIT` errors.  Implementations are not expected
to optimize tail-calls like a functional language would, but are permitted to.

#### <span id="ex-cap">CAP</span>

    [CAP]              // the entire namespace as an object
    [CAP, path...]

Reference data in the [capture namespace](#namespaces).

The arguments form a [path](#paths).  The capture namespace contains
[sequence capture results](#matching-arrays) from the most recent ancestor
`MATCH` or `IF` action.  This namespace is empty in any other scope.
The root-level properties are the same as the capture names and the values have
the form:

    {
      path:  // array of path elements to reach array/string
      ofs:   // starting offset
      len:   // number of elements matched
      lim:   // ofs + len
    }

These objects may be used as the argument to the [`SLICE` function](#ex-slice).
For example, to select the captured array elements of "example" as a new array
value, you can use:

    [SLICE, [CAP, 'example'] ]

Note that this works for both arrays and strings that were matched in the tree
of the current node, since SLICE can operate on both strings and arrays.

The captured `path` is computed at capture time and is not a "magic" property
that adapts to changes.  It reaches back as far as the current node when the
match began, but not beyond the most recent graft-specified override to the
current node.  So, captures inside a two-argument `IS` or `HAS` describe a
path from the root of the value argument to the node captured, not from the
root of the overall match.  Changes to the tree by actions like `MOVE` can also
render a path unusable.  JGraft generators need to be mindful of these
limitations; a good pattern is to copy the slices of interest to the `STASH` in
the first action under a match, before altering the tree.

#### <span id="ex-temp">TEMP</span>

    [TEMP, path...]

Reference data from the [temporary namespace](#namespaces).

The arguments form a [path](#paths).  This path must contain at least one
element since the root of the namespace may not be read or written.

#### <span id="ex-stash">STASH</span>

    [STASH]            // the entire namespace as an object
    [STASH, path...]

Reference data from the [stash namespace](#namespaces).

The arguments form a [path](#paths).  The path may be empty to reference the
stash namespace itself as an object, but the root may not be overwritten.

#### <span id="ex-const">CONST</span>

    [CONST]            // the entire namespace as an object
    [CONST, path...]

Reference data from the [const namespace](#namespaces).

The arguments form a [path](#paths).  The path may be empty to reference the
const namespace itself as an object.  This reference expression cannot be used
as the target of a write operation.

#### <span id="ex-node">NODE</span>

    [NODE]             // the current node itself
    [NODE, path...]    // data within the current node

Reference data relative to the [current node](#namespaces).

The arguments form a [path](#paths).  The path may be empty to reference the
current node itself.  The current node may be overwritten by `COPY` and `MOVE`
actions.  Implementations need to track both the container and property of the
current node, rather than just a pointer to it.

The current node is defined at the start of every action, though when
evaluating an expression it is possible for the current node to be undefined.
See [matching](#matching).

### Match Expressions

#### <span id="ex-any">ANY</span>

    [ANY, match_expr...]

Match when the target matches any of the [match-context](#match-context)
expressions.

This is like the function [`OR`](#ex-or), but with
[match expression](#expression-overview) semantics rather than function
expression semantics.  It requires at least one argument.

When [matching array elements](#matching-arrays), the successor states produced
by this expression are the union of all the successor states produced by its
match expressions.
Additionally, named captures within `ANY` expressions of the same match
algorithm state (i.e. not new matches initiated by functions) are ignored,
including those deeper in the structure.

#### <span id="ex-all">ALL</span>

    [ALL, match_expr...]

Match when the target matches all of the [match-context](#match-context)
expressions.

This is like the function [`AND`](#ex-and), but with
[match expression](#expression-overview) semantics rather than function
expression semantics.  It requires at least one argument.  When matching a
node in isolation (such as object properties or the root of a `HAS` or `IS`
expression), the subexpressions must also be valid for matching a single node.

When [matching array elements](#matching-arrays), sequence expressions are
permitted and each argument is treated as a constraint that must be satisfiable
over the same list of matched elements.  The successor positions of the `ALL`
expression are the intersection of the positions returned from each
subexpression.  Because all subexpressions must match, `ALL` is not exempt from
collecting captures.  For each position, the captures are simply the union of
the captures from each subexpression, and duplicates trigger failures using the
normal rules.

If `ALL` subexpressions contain sequences with position or length preferences,
they participate in the selection of a match for the overall array, using
argument order as the traversal order for the resolution algorithm.

For example, consider this expression:

    [ALL,
      [GROUP, "pairs",
        [REP,0,-1, [SEQ, [STR], [NUM]] ]
      ],
      [SEQ,
        [GROUP, "first",
          [ANY,
            [SEQ],
            [SEQ, [REP,2]]
          ]
        ],
        [REP]
      ],
      [SEQ,
        [REP],
        [GROUP, "last",
          [ANY,
            [SEQ],
            [SEQ, [REP,2]]
          ]
        ],
      ]
    ]

The first subexpression requires zero or more pairs of (string, number).  It
can only match an even number of elements.  The second subexpression can match
zero or two elements, followed by any number of elements.  The third
subexpression can match any number of elements followed by zero or two elements.
Each group prefers a longer match.  The ungrouped `REP` expressions have
no preference.

When used in an array expression and matched to an input of
`...,"a",1,"b",2,"c",3,"d",null,...`, the possible successor positions are:

Subexpression | Successor Positions
--------------|-------------------------------------
"pairs"       | +0, +2, +4, +6
"first" `REP` | +0, +1, +2, +3, +4, +5, +6, +7, +8
`REP` "last"  | +0, +1, +2, +3, +4, +5, +6, +7, +8

The intersection of them is `(+0,+2,+4,+6)`.  Absent a preference above the
`ALL` expression, the "pairs" sequence prefers the successor at +6, capturing
all elements under the name "pairs".  The "first" sequence prefers the longer
match ending at +2, capturing two elements under the name "first".  The last
sequence must end at +6 and prefers the longer match beginning at +4, capturing
the last two elements under the name "last".

#### <span id="ex-has">HAS</span>

    [HAS, match_spec]
    [HAS, value_expr, match_spec]

Match when the target has at least the properties described in `match_spec`.

The `match_spec` argument is declared using [match context](#match-context)
and the `value_expr` is declared using [value context](#value-context).
In the 1-argument form, the value being compared is the current node.

The `HAS` expression is the default for match context; when "has" mode is
already in effect, a `[HAS,...]` expression at the root of a match structure is
redundant unless used in the 2-argument form to establish an alternate current
node.

In the 2-argument form, the current node does not change until matching begins
in the subexpression; this means that if `match_spec` is a reference or
function expression or expansion of a value macro, `NODE` references within
still refer to the initial current node, but if `match_spec` is a structure or
match expression or expansion of an appropriate pattern macro, `NODE`
references within refer to the altered current node.

Examples:

    null                                node === null
    0                                   node === 0
    'str'                               node === 'str'
    [HAS, null]                         node === null
    [HAS, 42]                           node === 42
    { a: 1 }                            node.a === 1
    { a: [ANY, [NONE,[EXISTS]], 1] }    !('a' in node) || node.a === 1
    { a: [[]] }                         isArray(node.a)
    { a: [ARRAY, 3, 6, 7] }             isArray(node.a) && node.a[3] === 6
                                          && node.a[4] === 7
    [HAS, [TEMP,0], { a: 1 }]           temp['0'].a === 1

When [matching array elements](#matching-arrays), this continues to match
one node in isolation and prohibits sequence expressions used at the root node.
This provides generators with consistent semantics for testing nodes regardless
of the container type.  The [`CAN` expression](#ex-can) provides a way to test
sequence assertions, and to apply "has" mode to all elements of a sequence,
use `[GROUP, { exact: false }, ...]`.

#### <span id="ex-is">IS</span>

    [IS, match_spec]
    [IS, value_expr, match_spec]

Match according to `HAS` but fail if the object/array contains unspecified
properties/elements.

The `match_spec` argument is [match context](#match-context) and the
`value_expr` is [value context](#value-context).  In the 1-argument
form, the value being compared is the current node.

As described in the [matching section](#matching), the entire contiguous tree
of match structure and match expressions within the `IS` expression inherits
"is" mode unless overridden with a `HAS` expression or a `GROUP` with an
explicit `exact` setting.

Examples:

    [IS, null]                          node === null
    [IS, 8]                             node === 8
    [IS, 'str']                         node === 'str'
    [IS, {a:1}]                         is_deeply(node, {a:1})
    [IS, [ANY, {a:1}, {b:1}]]           is_deeply(node, {a:1})
                                         || is_deeply(node, {b:1})
    [IS, [TEMP,0], {a:1}]               is_deeply(temp['0'], {a:1})
    [IS, [NODE,'a'], [NODE,'b']]        is_deeply(node.a, node.b)
    [IS, [NODE,'a'], [IS,[NODE,'b']]]   is_deeply(node.a, node.a.b)

#### <span id="ex-none">NONE</span>

    [NONE, match_expr, ...]

Match when the target does not match one or more [match-context](#match-context)
expressions.

This is like the function [`NOT`](#ex-not), but with
[match expression](#expression-overview) semantics rather than function
expression semantics.  This matches one node.
When [matching array elements](#matching-arrays), this continues to match
one node in isolation and prohibits sequence expressions used at the root node.
For a negative sequence assertion, see [`CANT`](#ex-cant).

#### <span id="ex-exists">EXISTS</span>

    [EXISTS]              // current node
    [EXISTS, path_expr]   // hypothetical node

Match when the target node is a reference to a property that exists,
without regard to the value of the property.

With no arguments, this tests the current node.  The primary use case is for
expressions in [object matching](#matching-objects) where a property might
not exist, but you don't want a full "is" mode comparison.

When one argument is provided (path context), the existence of the implied
reference expression will be tested without attempting to read the property.
This is similar to a 2-argument `IS` expression like:

    [IS, [NODE, "a"], [EXISTS]]
    vs. [EXISTS, "a"]

    [IS, [CONST, "known_keys", [CURPROP]], [EXISTS]],
    vs. [EXISTS, [CONST, "known_keys", [CURPROP]]]

but more efficient, since those 2-argument `IS` expressions are actually
failing and then the error gets trapped as a false match because `IS` is a
match expression.  The `[EXISTS, path]` form can take a lighter-weight approach
of checking the path as it is resolved.

The root of each namespace (when considering the root of the input data rather
than the temporary value of the current node) is considered to be an "existing"
property, even though `CURPROP` returns `null`.  This also returns true for a
property pending deletion in a `MOVE` action, but not if it needs to descend
*through* the inaccessible value of that property.

When [matching array elements](#matching-arrays), this continues to require and
consume one node, even in the 1-argument form.  For zero-width assertions, use
[`CAN`](#ex-can).  For testing the end of an array, use [`END`](#ex-end).

#### <span id="ex-array">ARRAY</span>

    [ARRAY]
    [ARRAY, length]
    [ARRAY, offset, match_spec1...]

With no arguments, this matches when the current node is an array.

The `length` / `offset` argument is interpreted in value-context and must
resolve to an integer.  The `offset` may be negative to count backward from the
end of the array.  An `offset` out of bounds is not an error and simply tests
false.

With one argument, it asserts the current node is an array with at least this
number of elements in the context of `HAS`, or exactly this number of elements
in the context of an `IS` expression.

With more than one argument, this asserts the current node is an array and
that a subset of its elements match, even in "is" mode.
It is equivalent to an escaped array with initial `[EXISTS]` repeated `offset`
times (after resolving negative aliases), and in "is" mode a following
`[EXISTS]` repeated until the end of the array:

    [ARRAY, 3, true]
    // in HAS context is equivalent to
    [[ [SEQ, [REP,3]], true ]]
    // in IS context is equivalent to
    [[ [SEQ, [REP,3]], true, [SEQ, [REP]] ]]

Negative offset can be used to test elements at the end of the array:

    // Assert that the array ends with 'x', 'y', 'z'
    [ARRAY, -3, 'x', 'y', 'z']

#### <span id="ex-str">STR</span>

    [STR]
    [STR, regex_expr]

With no arguments, this matches when the current node is a string.

With one argument (specified in [regex context](#regex-context) ) it asserts
that the node is a string and matches a regular expression.  The expression is
not implicitly anchored (even within `IS` scope) and will locate the earliest
("leftmost") match within the characters of the string.  It also defaults to a
["longest match"](#matching-string-characters), which can be overridden by
wrapping variable-length portions of the expression with explicit length
preferences.

This expression is the primary way of invoking regular expression matching on a
string.  Captures within this regex *do* become available in the capture
results of the match expression containing this `STR` expression, but subject
to the normal capture-suppression rules.  If you want to locate named capture
bounds in a string during evaluation of a larger expression, wrap this
expression with the [`CAPTURE` function](#ex-capture).

#### <span id="ex-num">NUM</span>

    [NUM]
    [NUM, min]
    [NUM, min, max]

With no arguments, this matches when the current node is numeric, inclusive of
NaN and Inf if the implementation enables those extensions.

With one or two arguments (which may be value-context expressions), also verify
that `min <= node <= max`.  `min` or `max` may be `null` (or absent) to omit
the respective test.  In implementations where infinity or NaN are available,
neither may be used as the range boundary.

#### <span id="ex-bool">BOOL</span>

    [BOOL]

Match when the current node is a boolean.

#### <span id="ex-date">DATE</span>

    [DATE]

Match when the current node is a valid input for the
[`CASTDATE` expression](#ex-castdate).  See the details of that expression
and also the [dates section](#dates) for details.

#### <span id="ex-with">WITH</span>

    [WITH, match_expr, temp_prop, value_expr]
    [WITH, match_expr, temp_prop0, val0, temp_prop1, val1, ...]

Set up a lexical overlay on the TEMP namespace.

This sets one or more properties at the root of the TEMP namespace to new
values that are only visible for the duration of the `WITH` expression.
`temp_prop` may be any string or integer, but not an expression.
Each `value_expr` is declared in [value context](#value-context) and evaluated
before assignment.  Assignments are visible to subsequent `value_expr`
arguments and then to the `match_expr` argument.  The `match_expr` is declared
in [match context](#match-context) and the result is passed through as the
result of the `WITH` expression.

The purpose of this expression is to capture values within the tree of the
current node before descending into the tree with match expressions where they
would no longer be accessible.  Since expressions have no side effects and the
changes to TEMP are local to this expression, implementations are free to store
references to other trees rather than deep-cloning the data.

#### <span id="ex-group">GROUP</span>

    [GROUP, config_args, match_expr...]
    // config_args:
    {
      name: capture_name,
      prefix: capture_name_prefix,
      near: integer,
      long: boolean,
      exact: boolean
    }

Match a series of array elements against a series of match expressions.

To understand the arguments, first read the [Matching Arrays](#matching-arrays)
section.

The `config_args` (value context) are evaluated with the current node set to
the array being matched, not the element being searched; this allows them to be
evaluated before array matching begins, since expressions have no side effects.
All configuration arguments are optional, and a value of `null` may be used if
no arguments are required (but the `SEQ` expression is an alias for that).
If `config_args` is a boolean, it supplies the `long` property.
If `config_args` is an integer or string, it supplies the `name` property.
Otherwise, `config_args` must be an object with zero or more of the properties
`name`, `prefix`, `near`, `long`, and `exact`.

`name` specifies a string (or integer to be coerced to a string) for the
[capture namespace](#ex-cap).  When a group defines `prefix` (which must be a
string), the declared `name` and `prefix` values in any nested group
participating in the same match state implicitly get prefixed with this string.
The prefix system is useful when expanding macros so that capture names of the
macro can be localized and avoid collision with other expansions of that same
macro.

`long` is a boolean that expresses a preference for capturing greater or fewer
elements in this group, when considering the successful final match states for
the whole array.  A named group must have a width preference.  If `name` is
supplied and `long` is not, `long` defaults to `true`.

`near` specifies a preferred array index where the group should begin.  It must
be an integer, but may be specified as a negative integer to count backward
from the end of the array.

`exact` changes the "has" vs. "is" context flag for the elements of the group,
which can avoid needing to force the mode on every sequence element when the
generator isn't sure of the surrounding context.

`match_expr...` is any list of match expressions, and may be an empty list.
Using an empty sequence allows you to specify things like
`[ANY, "foo", "bar", [SEQ]]` allowing the `ANY` expression to match zero
elements, though the same could be achieved by wrapping the `ANY` with
`[REP,0,1,...]`.

The options are permitted to be an expression to deal with cases where a
pattern macro wants to name a capture, but might need to be applied multiple
times during the same match.  Using the `WITH` expression to set a prefix in the
`TEMP` namespace, the expanded macro can then generate different capture names
at each expansion site.

#### <span id="ex-seq">SEQ</span>

    [SEQ, match_expr...]

This is an alias for `[GROUP, null, match_expr...]`.

#### <span id="ex-long">LONG</span>

    [LONG, match_expr...]

This is an alias for `[GROUP, { long: true }, match_expr...]`.

#### <span id="ex-short">SHORT</span>

    [SHORT, match_expr...]

This is an alias for `[GROUP, { long: false }, match_expr...]`.

#### <span id="ex-near">NEAR</span>

    [NEAR, index, match_expr...]

This is an alias for `[SEQ, [REP], [GROUP, { near: index }, match_expr...]]`.

The leading `REP` allows a forward search from the previous match to reach the
desired `index`.  The sequence containing `match_expr` is not named, and has no
length preference.

#### <span id="ex-rep">REP</span>

    [REP]                         // consume any number of elements
    [REP, min]                    // consume exactly min elements
    [REP, min, max]               // consume between min and max elements
    [REP, min, max, match_expr]   // match expression between min and max times

Match repetitions of an expression against a series of array elements.

`min` and `max` are [value context](#value-context) expressions which must
evaluate to integers.  The value of `min` must be non-negative.  The value of
`max` may be -1 to mean "unbounded", or 0 as an alias for "same as min".
("same as min" is particularly useful if `min` is a complex expression)
Otherwise, `max` must have a value greater than or equal to `min`.
`match_expr` is a [match context](#match-context) expression.

The default `match_expr` is `[EXISTS]`, which basically just consumes elements.
In the zero argument form, `min` defaults to `0` and `max` defaults to
unbounded.  In the one argument form, `max` defaults to `min`.

This expression is invalid outside a context which is
[matching array elements](#matching-arrays) or characters.
It produces all the successor cursor positions that can satisfy a count of
matches of the expression between `min` and `max`.  (Of course, implementations
need to limit the successor states to the length of the array and handle
expressions which consume zero elements when `max` is unbounded.)

Regex Notation               | REP notation
-----------------------------|--------------------
 `.*` (where . includes \n)  | [REP]
 `.+`                        | [REP,1,-1]
 `.?`                        | [REP,0,1]
 `(...)*`                    | [REP,0,-1,...]
 `(...)+`                    | [REP,1,-1,...]
 `(...)?`                    | [REP,0,1,...]
 `(...){5}`                  | [REP,5,0,...]
 `(...){3,5}`                | [REP,3,5,...]

Implementations should optimize the pattern `[REP, ... [EXISTS]]` (specifically
the no-argument form of `EXISTS`) to simply identify successor states based on
the elements which exist, rather than executing an `EXISTS` expression at each
of them.  This prevents quadratic application of `EXISTS` when testing possible
successor states from expressions like `[SEQ, [REP], "needle", [REP] ]` and
avoids running into resource limits unnecessarily.

#### <span id="ex-start">START</span>

    [START]

Zero-width assertion that returns true when the cursor position is at element
zero.  This expression is invalid outside a context which is
[matching array elements](#matching-arrays) or characters.

#### <span id="ex-end">END</span>

    [END]

Zero-width assertion that returns true when the cursor position is at the
length of the array.  This expression is invalid outside a context which is
[matching array elements](#matching-arrays) or characters.

#### <span id="ex-can">CAN</span>

    [CAN, match_expr...]

Zero-width assertion that the sequence of arguments (which may be empty) can
match from this position.  This does not count as an expression branch that
"consumes" elements.

#### <span id="ex-cant">CANT</span>

    [CANT, match_expr...]

Zero-width assertion that the sequence of arguments (which may be empty) cannot
match from this position.

#### <span id="ex-chars">CHARS</span>

    [CHARS, ...
      true,                // include following elements
      false,               // exclude following elements
      "abcdef",            // 6 literal characters
      "a","z",             // a range of characters to be added
      "a",null,            // open-ended range
      "a","",              // not a range, just the character 'a'
      48,57,               // Unicode codepoint range
      value_expr           // reference a value or CHARS expression
    ]

Match when the current node is a character in the defined set.

This expression matches both integers in the Unicode codepoints range, and
one-character strings. ("one character" according to the implementation's
construction of codepoint arrays from a JSON string)

Boolean values switch between inclusion and exclusion.  The default is
inclusion to an empty set.  If the first element is false, it instead becomes
exclusion from the complete set of Unicode.  Further boolean values affect
the elements that follow but do not themselves modify the set.

A string of zero or more than one character is considered a list of characters
to include.  A single character begins an inclusive range
of characters if the following element is also one character.  Ranges must be
specified in ascending codepoint order.  `null` may be used as an alias for
the maximum Unicode character.  An integer is treated as a Unicode codepoint
value (and must fall within the valid Unicode range).  Since integers and
`null` represent single characters, they also begin or end ranges when
possible.

Finally, you may use an expression that evaluates to either a string (of which
all characters will be added or removed; it never participates in a range) or
the expression macro object of another `CHARS` expression created using
[`REG`](#ex-reg).  Any other type is invalid.

Examples:

    // Regex /./
    [CHARS, false, "\n"]

    // Regex /./s
    [CHARS, 0,null]
    [CHARS, false]
    
    // Regex /[0-9]/
    [CHARS, "0123456789"]
    [CHARS, "0","9"]
    [CHARS, 48,57]
    [CHARS, "0",57]
    
    // Regex /[0-9a-zA-Z_.-]/
    [CHARS, "0","9", "A","Z", "a","z", "_-."]
    [CHARS, 0x30,0x39, 0x41,0x5A, 0x61,0x7A, "_-."]
    
    // "All printable but no punctuation"
    // Regex /[^\P{Print}\p{Punct}]/
    // (assuming you define these classes in the JGRAFT action)
    [CHARS, [CONST,"regex_Print"], false, [CONST,"regex_Punct"]]

### Function Expressions

#### <span id="ex-act">ACT</span>

    [ACT, action]

Create an action macro.

The `action` argument is declared as a normal action, but instead of executing
it, an opaque object representing it is returned.  This object can be invoked
with the `CALL` action.  Parameters may be passed via the `STASH` namespace
using whatever convention the JGraft generator prefers.

#### <span id="ex-val">VAL</span>

    [VAL, value_expr]

Create a value-context expression macro.

The `value_expr` is given in value context, but instead of executing it, an
opaque object representing it is returned.  The object can be invoked with the
`EX` expression.  None of the subexpressions within `value_expr` are evaluated
until the point where `EX` expands it.  Parameters may be passed via the `TEMP`
or `STASH` namespaces using whatever convention the JGraft generator prefers.

#### <span id="ex-pat">PAT</span>

    [PAT, match_expr...]

Create a match-context expression macro.

The `match_expr` argument is given in match context, but instead of using it to
start a match, an opaque object representing it is returned.  If more than one
argument is provided (or zero), it implicitly becomes a `SEQ` expression.
None of the subexpressions within `match_expr` are evaluated until the point
where `EX` expands it.

#### <span id="ex-reg">REG</span>

    [REG, match_expr...]

Create a regex-context expression macro.

Like `PAT`, but `match_expr` arguments are interpreted according to
regular-expression context, where the meaning of scalars is altered.

#### <span id="ex-data">DATA</span>

    [DATA, literal_data]

Supply value-context data which is guaranteed to not contain subexpressions.

This is primarily useful for generators to supply data to a graft without
needing to escape the arrays within.  Likewise, implementations can consume it
as-is without checking for subexpressions.

#### <span id="ex-capture">CAPTURE</span>

    [CAPTURE, match_expr]

Match, then return captured sequences.

This function invokes the matching algorithm using the match-context
`match_expr`, which may be any expression including 2-argument IS or HAS
which match against a value other than the current node.  If the match fails,
this expression returns `false`.  If the match succeeds, it returns the capture
namespace produced by the match engine as an object where each named sequence
capture is a property of the object, with values of the form returned by
[`CAP`](#ex-cap).  The `CAPTURE` function has no effect on the
[capture namespace](#namespaces).

#### <span id="ex-local">LOCAL</span>

    [LOCAL, subexpr, prop0, value_expr0, ...]

Set up a lexical overlay on the `TEMP` namespace or override the current node,
then evaluate `subexpr` and return that value.

This is very similar to the [`WITH` expression](#ex-with), but as a function
rather than a match expression.  Each `prop` argument must either be a literal
string (or integer which gets coerced to string) naming a TEMP namespace
root property, or a literal `null` to request a lexical override of the
current node.  Changes made by each `prop` / `val` pair are visible to the
evaluation of subsequent pairs.  After evaluating `subexpr`, the TEMP namespace
and current node revert to their previous state.

The `prop` argument is restricted to the root of the TEMP namespace or the
current node pointer.  Combined with the restriction that the path of `[TEMP]`
itself is not a valid reference, it ensures that the changes cannot be seen in
any other namespace or path within the TEMP namespace.  The TEMP namespace may
hold references to other trees temporarily, but nothing can hold a reference to
the root of the TEMP namespace.
Likewise, rebinding the current node does not modify, replace, or otherwise
write through any reference in the target tree or another namespace.

#### <span id="ex-and">AND</span>

    [AND, value_expr, ...]

Logical AND of one or more value expressions.

Each evaluated expression must evaluate to a boolean.  Each argument is
evaluated in sequence, stopping after the first false value or error raised.
This means later arguments may contain expressions that would trigger errors so
long as a previous argument evaluating false guards against reaching the later
argument.

#### <span id="ex-or">OR</span>

    [OR, value_expr, ...]

Logical OR of one or more value expressions.

Like `AND`, each argument is evaluated in sequence, and must evaluate to a
boolean.  Evaluation stops after the first true value or error raised.

#### <span id="ex-not">NOT</span>

    [NOT, value_expr, ...]

Logical NOT ("NOR", really) of one or more value expressions.

Like `AND`, each argument is evaluated in sequence, and must evaluate to a
boolean.  Evaluation stops after the first true value or error raised.

#### <span id="ex-length">LENGTH</span>

    [LENGTH]               // operate on the current node
    [LENGTH, value_expr]

Return the length of an array or string.

If `value_expr` (value context) is not specified, the value of the current node
is used.  The value must be an array or string.  The length of a string is
determined by the same rules that break a string into an array of characters,
which may differ from the host language's concept of "length".

#### <span id="ex-curprop">CURPROP</span>

    [CURPROP]

If the current node is a property of an object, return the property name, else
if it is an element of an array, return the element number, else return `null`.

This is useful when iterating over an array in a match expression or `MAP` /
`REDUCE` / `FILTER` expression to know which array index is being processed.
It can be used to help generate capture names or look up parallel paths from
another array or object.
When generating a sequence capture name, the current node is the array being
searched, so `CURPROP` identifies that array's property in its parent, not the
starting index of the sequence being captured.

It returns `null` when the current node refers to the root of a namespace.

#### <span id="ex-slice">SLICE</span>

    [SLICE, config_args]
    [SLICE, config_args, source_val]
    // config_args may be:
    //   ofs
    //   [[ ofs, len ]]
    //   [[ ofs, -(LENGTH-lim) ]]
    //   { ofs: N, len: N, lim: N, path: P }

Return a span of an array or string.

All arguments are [value context](#value-context) expressions.
If `source_val` is not specified, the value of the current node is used.
The `config_args` may be a single integer to supply `ofs`,
an (escaped) array with a non-negative second element to supply `ofs` and `len`,
an (escaped) array with a negative second element to supply `ofs` and a
calculated `lim`, or an object of arguments.

The optional `path` argument must be an array value.  It modifies the source
as per the expression `[NODE, path]`, or `[LOCAL,[NODE, path],null,source_val]`
if `source_val` is provided.  After following this path (or using the source
directly when no path is supplied), the target must be an array or string.
All offsets and bounds refer to this target, whose length is used for alias
resolution and defaults.

All arguments are individually optional, though at least one of `ofs`, `len`,
or `lim` must be provided.  The `ofs` argument must evaluate to an integer;
when negative it is an alias for `LENGTH(target) + ofs`, and this alias is
resolved before considering any relation to `len` or `lim`.  The `len` and
`lim` arguments must evaluate to non-negative integers.
After normalizing negative arguments, they must obey the relation
`ofs + len = lim`.  When one property is absent, it is derived from the other
two using that equality.  When two are absent, `ofs` defaults to 0, else `lim`
defaults to `LENGTH` to provide a second parameter.  After computing `ofs` and
`lim`, they must then obey the relation `0 ≤ ofs ≤ lim ≤ LENGTH(target)`.
Note that invalid literal arguments provided using negative aliases cannot
trigger `INVALID_GRAFT`; resolving a negative alias uses `LENGTH(target)` and
counts as an expression evaluation.

When [`SPLIT` metadata](#split-metadata) is present on the input array, the
portion describing the sliced elements is copied to the output array.

Examples:

    // For NODE of [0,1,2,3,4,5,6]
    [SLICE, 3]                      -> [3,4,5,6]
    [SLICE, -1]                     -> [6]
    [SLICE, [[3, 1]]]               -> [3]
    [SLICE, [[3, -1]]]              -> [3,4,5]
    [SLICE, {ofs: 3}]               -> [3,4,5,6]
    [SLICE, {len: 2}]               -> [0,1]
    [SLICE, {lim: 4}]               -> [0,1,2,3]
    [SLICE, {ofs: 3, lim: 6}]       -> [3,4,5]
    [SLICE, {ofs: 1, len: 1}]       -> [1]
    [SLICE, {len: 2, lim: 5}]       -> [3,4]

#### <span id="ex-concat">CONCAT</span>

    [CONCAT, value_expr1, ...]

Concatenate one or more arrays or strings into a larger array or string.

All arguments must evaluate to the same type.  If they are all strings, they
get joined into a string.  If they are all arrays, a new array of the combined
lists of elements is returned.

When [`SPLIT` metadata](#split-metadata) is present on an input array, it gets
copied to the output array unless an earlier input array already copied `SPLIT`
metadata with a different `origin`.  This causes all other elements to receive
"adjacent element metadata" unless they have some from a matching `origin`.

#### <span id="ex-reduce">REDUCE</span>

    [REDUCE, reduce_expr, temp_prop, initial_value]
    [REDUCE, reduce_expr, temp_prop, initial_value, array_expr]

Combine the elements of an array into a result value.

`reduce_expr` is specified in value context, but is not evaluated immediately.
(In order to use a value expression macro, `reduce_expr` should be an `EX`
expression, not the expression that resolves to the macro object.)
`temp_prop` is a literal property name string of the TEMP namespace, but may
also be an integer that gets coerced to a string.
The `initial_value` and `array_expr` arguments are specified in value context.
If `array_expr` is provided, it must evaluate to an array, otherwise the
current node is used as input and must be an array.  `initial_value` may
evaluate to any type.

The `initial_value` is evaluated prior to any iteration, and becomes the
accumulator value.  For each element of the input array (which may be empty),
the current node is set to alias the array element, and the `TEMP` namespace
property `temp_prop` is set to alias the accumulator, and then `reduce_expr`
is evaluated.  The changes to the current node and TEMP namespace are *only*
visible to the evaluation of `reduce_expr`.
The return value of `reduce_expr` is kept as the new accumulator value.
After all array elements have been processed, the accumulator value is
returned as the result of the `REDUCE` expression.

`REDUCE` can actually be implemented using Lisp-style recursive iteration, but
is provided for efficiency and to reduce the chance of exceeding
`RESOURCE_LIMIT` from recursive behavior.
Minimalist implementations should not fall back to an internal common
subexpression of `REDUCE` if it would make a graft more likely to hit resource
limits than a proper `REDUCE` implementation.

#### <span id="ex-filter">FILTER</span>

    [FILTER, match_expr]
    [FILTER, match_expr, array_expr]

Select matching elements from an array.

`match_expr` is a match context expression which is not immediately evaluated.
(In order to use a pattern expression macro, `match_expr` should be an `EX`
expression, not the expression that resolves to the macro object.)
With one argument, the current node must be an array.  Otherwise, the
`array_expr` specified in value context must evaluate to an array.
Each element of the array is localized as the current node while evaluating
`match_expr`.  The elements which match become part of the returned array, in
the same order they appeared in the original array.

If the source array contains [`SPLIT` metadata](#split-metadata), the metadata
for the selected elements gets copied to the new array.

#### <span id="ex-map">MAP</span>

    [MAP, transform_expr]
    [MAP, transform_expr, array_expr]

Transform each element of an array to produce a new array.

The `transform_expr` is specified in value context, but is not evaluated
immediately.  (In order to use a value expression macro, `transform_expr` should
be an `EX` expression, not the expression that resolves to the macro object.)
In the one-argument form, the input comes from the current node,
which must be an array.  Otherwise the `array_expr` (also value context) is
evaluated and likewise must return an array to be used as the input.
Then, for each element of the input array, the current node is localized to
reference it, and `transform_expr` is evaluated in that context.
The values returned by each evaluation of `transform_expr` become the elements
of the array returned by `MAP`.

If you need to replace one element with a differing number of elements you
need to use `REDUCE`, which may construct an array in its accumulator.

If the source array contains [`SPLIT` metadata](#split-metadata), the returned
array is given a copy and new values for each element are applied as if by
assignment to that index.  This means each element retains its separator and
trimmings, which is different than if a graft recursively assembled a new array
from computed values.

#### <span id="ex-split">SPLIT</span>

    [SPLIT, split_spec]                 // operate on current node
    [SPLIT, split_spec, string_expr]

Split a string into an array, optionally preserving separators and trimmed
strings in hidden metadata.

In the one-argument form, the input is the current node, else the input comes
from evaluating `string_expr` (value context).  The input must be a string.

The `split_spec` argument (value context) may evaluate to a simple string used
as a verbatim separator, a pattern macro object (see [`REG`](#ex-reg) ) to be
evaluated in [regex longest-match context](#regex-context), or an object
with a more elaborate specification:

    {"sep": ...,      // A string or regex macro to split on
     "element": ...,  // A regex macro to match prior to testing for 'sep'
     "default": ...,  // The default separator used for joining new elements
     "keep": ...,     // Preserve the separator within the generated array
     "ltrim": ...,    // A string or regex macro to trim from start of elements
     "rtrim": ...,    // A string or regex macro to trim from end of elements
     "trim": ...,     // sets 'ltrim' and 'rtrim' to the same value
     "discard": bool, // Don't preserve trimmed chars when re-assembling
    }

`default` is not used by `SPLIT`, but defined here since the specification is
shared with `JOIN`.

The split operation iterates through the characters of the string looking for
[the leftmost match](#matching-string-characters) of the separator pattern
with the longest-overall preference enabled, as described in
[the matching section](#matching-arrays).
If you specify an `element` regex, a test for a separator will only be
attempted when the element characters (from the limit of the previous separator
(or start of string) up to the current match position) also match the `element`
pattern.  The `element` pattern is implicitly anchored to the start and end of
the element characters.  This gives you a way to pass over escape sequences
without accidentally detecting a separator, and without requiring the
complexity of "look-behind" or capture groups in the separator pattern.

Once a separator is found, it uses the value of `keep` to determine what to do
with it.  The default is to hide the separator from the resulting array but
store it (attached invisibly to the preceding element) until it is time to
reconstruct the string.
The value "<" means to keep the separator as part of the current element in
the generated array, and likewise ">" means to keep it as part of the
following element.  The value "@" means to include the separator as its own
element of the resulting array.  In all three cases, separator metadata is not
used, and elements get reassembled with an empty string as the separator since
the actual separator is part of the data.

The search for a separator repeats while characters remain in the string.
When a separator is not found, the substring from the limit of the final
separator (or start of string) is returned as the final element, even if it is
empty or does not match the `element` regex.  If the input is an empty string,
no search is required, and the empty string is returned as the only element.

A zero-length separator is considered to match at every character-array index
(including the character-array length) other than the limit of the previous
separator, which prevents an infinite loop of empty elements.  Likewise, a
zero-length regex match that doesn't advance the cursor is restricted from
succeeding at the limit of the previous separator.
This means the separator of `""` can be used to split the string
into its individual characters.  It also means that a regular expression which
can unconditionally match the empty string will generate a single-character
element any time none of the alternatives matched.

For example, consider the pattern `/a*/` applied to the following strings:

    [SPLIT, [REG, [REP,0,-1,"a"]], "baabc"]
      => ["b", "b", "c"]
    
    [SPLIT, [REG, [REP,0,-1,"a"]], "baabca"]
      => ["b", "b", "c", ""]
    
    [SPLIT, { sep: [REG, [REP,0,-1,"a"]], keep: "@" }, "baabca"]
      => ["b", "aa", "b", "", "c", "a", ""]

`ltrim` and `rtrim` are used to hide unimportant characters from the resulting
array element strings, such as leading/trailing whitespace (like `diff -b`)
and you can (mutually exclusive with the others) specify `trim` to set them
both to the same value.
`ltrim` is implicitly anchored to the start of the element string, and `rtrim`
is implicitly anchored to the end, allowing a common value for `trim`.
Both trim expressions are tested with the longest-overall preference enabled.
The match of `ltrim` gets removed first, followed by a match of `rtrim` from
the remainder, to resolve cases where the trimming could overlap.
If you want to permanently remove the trimmed characters, use `discard: true`.

If the separators are not added to the array using `keep` and are not a
constant string, they are stored in a parallel array of metadata associated
with the array, referred to as [`SPLIT` metadata](#split-metadata).  Likewise,
trimmed characters are stored there if not being discarded.  As modifications
are applied to the array to rearrange its elements, this metadata is modified
in parallel as described below.

##### Split Metadata

"SPLIT metadata" carries the hidden separators and end-trimmings from the
[`SPLIT` function](#ex-split).  It is associated *with the array* as a parallel
array of per-element data, rather than being bound to the values themselves.
The separator is paired to the element it *followed* and the final element will
not logically have one since a string ending with a separator receives a final
element of the empty string, though for the purposes of this algorithm it
receives a copy of the separator of the preceding element.
Only one instance of `SPLIT` metadata may be associated with any one array.
It also contains an `origin` tag, unique to each execution of the `SPLIT`
function; in any case where values are transferred between element references,
the `SPLIT` metadata will only carry over when both arrays have metadata of the
same `origin`.

Actions and expressions that operate on an array need to do a bit of extra work
when `SPLIT` metadata is present in order to keep it associated with the
correct element value.  To avoid this extra work, implementations should only
generate `SPLIT` metadata when the separator is not a constant or when trimming
is requested and not being discarded.

Individual actions and expressions may define their handling of `SPLIT`
metadata more specifically, but in general:

  * If an array with `SPLIT` metadata is receiving an element in an "insert"
    manner from a direct reference to an array element having `SPLIT`
    metadata of the same `origin`, the element metadata carries over.
    (function expressions derived from reference expressions do not qualify,
    but references via aliases like negative integers do)
  * If an array with `SPLIT` metadata is receiving an element in an "insert"
    manner from a direct reference to an array without `SPLIT` metadata of the
    same `origin`, the element receives "adjacent element metadata" described
    below.
  * If an array with `SPLIT` metadata is receiving a new value for an existing
    element in an "overwrite" manner, the existing separator and trimming are
    unchanged, regardless of the source.
  * If an array without `SPLIT` metadata is receiving an element from an
    array with `SPLIT` metadata in an "insert" manner, the destination array
    is upgraded to have `SPLIT` metadata (of the same `origin`) to preserve the
    metadata for that element.
  * Construction of new arrays and appending elements to arrays count as an
    "insert" operation.

`SPLIT` metadata must describe all array elements uniformly; if separators
exist for any element, separators must exist for all elements, and likewise for
trimmings.  To resolve this for elements added to the array, the element
receives "adjacent element metadata".  For separators, new elements receive the
separator of the preceding element, or at the start of the array, the
following element.  (arrays of no elements drop the `SPLIT` metadata)
If trimmings are present, the new element receives the left-trimming of the
previous line, or an empty string if there is no previous line.
Right-trimming for new elements is always the empty string.
These rules are all designed around the concept of preserving indent and
comments in text while allowing changes to the strings within, and extending
indent to subsequent lines without replicating comments.

#### <span id="ex-join">JOIN</span>

    [JOIN, split_spec]                  // operate on current node
    [JOIN, split_spec, array_expr]

This is the counterpart to the `SPLIT` expression, joining an array into a
string.

This expression takes a `split_spec` argument identical to the
[`SPLIT` expression](#ex-split), though it only really needs the `keep`,
`discard`, `sep`, and `default` properties.
In the 1-argument form, the input is the current node,
else the value-context `array_expr` is evaluated to determine the input.
The input must be an array and all its elements must be strings.
If `discard` is not true, each element gets any trimmings stored in
the [`SPLIT` metadata](#split-metadata) re-added.
If `keep` was not used and `sep` is not a constant, it looks for
captured separators in the `SPLIT` metadata, falling back to the `default`
separator.  `default` must be specified when `sep` is a regular expression and
`keep` is not used; if `sep` is a string then it also implies `default` and if
`keep` is used then separators are not relevant to the join operation.
`default` is declared in value context, and must resolve to a string.
Separators are only added *between* elements; any separator associated with the
final element is ignored.  In order to get a "newline at the end of the file"
the final element of the array needs to be an empty string.

#### <span id="ex-props">PROPS</span>

    [PROPS]                             // operate on current node
    [PROPS, object_expr]

Return the names of properties of an object.

Lacking `object_expr`, this operates on the current node.  Otherwise,
`object_expr` is specified in value-context and must resolve to an object.
The property names of the object are returned as an array, sorted by Unicode
codepoint sequence to ensure deterministic behavior across implementations when
iterating over properties.

#### <span id="ex-propv">PROPV</span>

    [PROPV]                           // operate on current node
    [PROPV, object_expr]

Return the properties of an object as name/value arrays.

Lacking `object_expr`, this operates on the current node.  Otherwise,
`object_expr` is specified in value-context and must resolve to an object.
Each property (sorted by Unicode codepoint sequence) is returned as a
`[name, value]` pair within an array, suitable for concatenation or passing to
`MKOBJ`.

#### <span id="ex-mkobj">MKOBJ</span>

    [MKOBJ, prop_array ]                    // array of [name,val] elements
    [MKOBJ, prop_array, name1, val1, ... ]  // additional overrides

Construct an object from dynamically calculated properties.

All arguments are specified in value context.  The `prop_array` is an array
(or `null` to omit it) whose elements are each an array of `[name, value]`.
The array may also contain `null` entries which are ignored; this provides an
easy way for `MAP` to filter the properties of an existing object.  The array
may be empty or contain only `null` entries, resulting in an empty object.
If the property array contains a duplicate name, the earlier property value is
overwritten with the latter (higher array index).

If additional arguments are provided, they must be provided in pairs.
Each pair, in argument order, is treated as if that additional entry had been
appended to the array.

In all cases, the name arguments/elements must evaluate to strings and cannot
be `null`.

Examples:

    // Remove properties with leading underscore
    [MKOBJ, [FILTER,
      [[ [STR, [SEQ, [START], [CANT, "_"]] ] ]],
      [PROPV, [NODE]]
    ]]
    
    // Translate or remove properties
    [MKOBJ, [MAP,
      [CASE,
        [EXISTS, [CONST, "renames", [NODE,0]]],
          [[ [CONST, "renames", [NODE,0]], [NODE,1] ]],
        null
      ],
      [PROPV, [NODE]]
    ]]

#### <span id="ex-case">CASE</span>

    [CASE, match_expr, value_expr, ..., else_value_expr]
    [CASE, match_expr, value_expr, ...]   // or implied FAIL

Evaluate one value expression selected by a series of conditional tests.

For pairs of `match_expr` (match context) and `value_expr` (value context),
return the evaluated `value_expr` of the first successful `match_expr`, else
evaluate and return the `else_value_expr` (value context).
At least one pair must be specified.  If no "else" is provided and none of the
matches succeed, the implied else value is the `FAIL` expression.
Conditions are tested in argument order, and only the selected value-context
expression gets evaluated.

Because [match context](#match-context) lets a plain value describe a `HAS`
match against the current node, this can be an efficient way to choose an
expression based on its value.  If the value you want to compare is not the
current node, you can temporarily set it up as the current node using
[`LOCAL`](#ex-local).

#### <span id="ex-fail">FAIL</span>

    [FAIL]

Fail with a `RUNTIME_ERROR`.  This is useful for rejecting unexpected
scenarios in expressions.  Note that this converts to a false match when used
in match context.

#### <span id="ex-castbool">CASTBOOL</span>

    [CASTBOOL]                  // cast current node
    [CASTBOOL, value_expr]

Cast a value to boolean.

Boolean values always pass through.  Only integers 1 and 0 and strings "true"
and "false" may be cast to booleans, and every other value fails.

If you want something closer to the "everything is true unless it is false-ish"
seen in many programming languages, consider adding your preferred list of
false values to a `NONE` expression, optionally combined with an `EXISTS` test:

    // return true/false for current node, fail on undefined
    [CASE, [EXISTS], [NONE, false, 0, "", null]]
    // return true/false for an arbitrary value expression
    [IS, value_expr, [NONE, false, 0, "", null]]

#### <span id="ex-castnum">CASTNUM</span>

    [CASTNUM]                   // cast current node
    [CASTNUM, value_expr]

Cast a value to a number.

Numeric values always pass through.  Any string which parses as a valid number
according to JSON syntax also becomes a number, but non-numeric characters like
whitespace are not permitted.  In addition to JSON syntax, leading '+' and
trailing '.' are permitted.
Extensions to the data model permitted by the implementation may also support
numification, as decided (and documented) by the implementation.

#### <span id="ex-caststr">CASTSTR</span>

    [CASTSTR]                   // cast current node
    [CASTSTR, value_expr]

Cast a value to a string.

String values always pass through.  Booleans stringify to "true" and "false".
Numbers with no fractional part stringify to decimal digits with a possible
leading minus sign.  Other numbers stringify to any digits accurate to the
requirement of the [Math section](#math), which is not consistent across all
implementations, and the exact character representation should not be relied
on.  Dates stringify in ISO8601 format.  Datetimes stringify as
"yyyy-mm-dd hh:nn:ss" with the possibility of more digits in the year and
sub-second precision.  Timestamps stringify as "yyyy-mm-ddThh:nn:ssZ" (for a
zero timezone offset) or "yyyy-mm-ddThh:nn:ss±zzzz", and with the same
longer-year/subsecond possibility.
Extensions to the data model permitted by the implementation (including numbers
Inf and NaN) may stringify according to the implementation or configuration
from the application.

Every other value (objects, arrays, `null` and the nonexistent property that
can be encountered when matching objects) causes `CASTSTR` to fail.

#### <span id="ex-castdate">CASTDATE</span>

    [CASTDATE]                  // cast current node
    [CASTDATE, value_expr]

Cast a value to a JGraft date, datetime, or timestamp.

The result of a previous `CASTDATE` expression should always pass through.
All implementations should support parsing strings of at least the following
formats:

    yyyy-mm-dd                      // date
    yyyy-mm-ddThh:nn:ss             // datetime
    yyyy-mm-ddThh:nn:ssZ            // timestamp
    yyyy-mm-ddThh:nn:ss+hh          // timestamp
    yyyy-mm-ddThh:nn:ss+hh:nn       // timestamp
    yyyy-mm-ddThh:nn:ss+hhnn        // timestamp

where the hyphens and colons are optional when the standard number of digits
is present, the 'T' separator may also be a space, `ss` can be written
`ss.sss` or `ss,sss` to an arbitrary precision (silently truncated to the
precision supported by the implementation), and the timezone '+' may be a '-'
or Unicode minus sign for any nonzero timezone (as prescribed by ISO-8601).
The year field should also be permitted to have more than 4 digits if hyphens
are used.

Additional date formats may be supported if the list above doesn't cover a
commonly encountered format of a particular host language, but implementations
should avoid supporting ambiguous string formats, and force users to generate
more specific expressions to parse them if required.

Additionally, `value_expr` may evaluate to an object with the following
properties:

    { "year":      // required
      "month":     // default is 1
      "day":       // default is 1
      "hour":      // indicates datetime if present, default is 0
      "minute":    // indicates datetime if present, default is 0
      "second":    // indicates datetime if present, default is 0
      "tz_offset": // indicates timestamp if present
    }

where the precision of the result (`date` vs `datetime` vs `timestamp`) is
chosen based on the least-significant property supplied in the object before
applying defaults.

All date formats should be validated against the Gregorian calendar for years
1583 and onward (the cutoff defined in ISO 8601) and invalid days rejected.
Hours and minutes should be validated against the standard
range, but seconds should permit a leap second (60 and fractions above that)
without historic validation.

If host language date objects are permitted in the data, they should also be
supported by this expression, though depending on the capabilities or
mutability of those date objects an implementation may still need to convert
them to a different internal representation.

If an implementation cannot confidently infer a date-like meaning for a value,
it should fail.

#### <span id="ex-less">LESS</span>

    [LESS, expr_b]              // current node less than b
    [LESS, expr_a, expr_b]

Perform a less-than comparison and return true/false.

Both arguments must evaluate to the same type.

For booleans, `false` compares less than `true`.

For numbers, this performs a numeric comparison according to the host language.

For strings, this performs a character-by-character comparison on the codepoint
values, using the same string-to-characters algorithm as configured for regular
expressions.

For arrays, this performs an element-by-element `LESS` test on corresponding
elements, stopping at the first pair which are not equal and returning the
result.  This fails if it encounters types without a defined comparison, but
such invalid elements are not encountered if a valid difference is found at an
earlier element.  If it makes it to the end of one array before the other, that
array is considered the lesser of the two.

For dates and datetimes, the fields are compared most-significant to
least-significant as if they were an array of those values.  On timestamps, the
timezone offset is applied first before comparing logical instants.  Note that
timezone offsets have a minute resolution, so applying the offset and comparing
fields can be done independently of whether leap seconds exist.

All other types (e.g. objects) fail.

#### <span id="ex-lesseq">LESSEQ</span>

    [LESSEQ, expr_b]            // current node less or equal to b
    [LESSEQ, expr_a, expr_b]

Perform a less-than-or-equal comparison and return true/false.

This uses the same rules as `LESS` but also returns true if the values are
equal.

#### <span id="ex-add">ADD</span>

    [ADD, array_expr]
    [ADD, value_expr1, value_expr2, ...]

Add numbers, ignoring `null`.

Arguments are described in value context.  When a single expression is supplied,
it must evaluate to an array whose elements will be used as the input values.
When more than one argument is supplied, those values are used as the input.
Each input value must be a number, or `null`; `null` values are ignored.
The input list may be empty, resulting in the value `0`.
The result is the host language's addition of those numbers combined in element
order, using the rules described in the [math section](#math).

#### <span id="ex-sub">SUB</span>

    [SUB, value_expr1, value_expr2]

Subtract numbers.

Arguments are described in value context.  There must be exactly 2 arguments
and they must evaluate to numbers.  The result is the host language's
subtraction of those numbers, within the rules described in the
[math section](#math).

#### <span id="ex-mul">MUL</span>

    [MUL, array_expr]
    [MUL, value_expr1, value_expr2, ...]

Multiply zero or more numbers.

Arguments are described in value context.  When a single expression is supplied,
it must evaluate to an array whose elements will be used as the input values.
When more than one argument is supplied, those values are used as the input.
Each input value must be a number, or `null`; `null` values are ignored.
The input list may be empty, resulting in the value `1`.
The result is the host language's multiplication of those numbers combined in
element order, using the rules described in the [math section](#math).

#### <span id="ex-div">DIV</span>

    [DIV, value_expr1, value_expr2]

Divide numbers.

Arguments are described in value context and must evaluate to numbers.
The result is the host language's mathematical division of those numbers (not
integer division with rounding), within the rules described in the
[math section](#math).

#### <span id="ex-mod">MOD</span>

    [MOD, value_expr1, value_expr2]

Calculate a modulus.

Arguments are described in value context and must evaluate to numbers.
The result is the modulus in the range `[0..value_expr2)` or `(value_expr2..0]`
if `value_expr2` was negative.  If `value_expr2` is zero it counts as division
by zero.

Note that this is not the same as the C language `%` operator, which returns
a remainder.

#### <span id="ex-pow">POW</span>

    [POW, base]
    [POW, base, exponent]

Return the value of `base` to the power of `exponent`.  If `exponent` is
omitted the current node is used.

The `base` (value context) must be a nonnegative number.  The `exponent`
(value context) can be any number but must be nonnegative if `base` is zero.

For valid arguments, when `exponent` is zero, the result is always one.
If `base` and `exponent` are both integers, implementations must check to see
if the result can be represented exactly in an available number storage type,
and if so, use an exact power calculation instead of floating point math.

#### <span id="ex-log">LOG</span>

    [LOG, base]
    [LOG, base, value]

Return the `base` logarithm of `value`.  If `value` is omitted the current
node is used.

The `base` and `value` (both value context) must be positive numbers, and
`base` may not be exactly one.  For valid arguments, when `value` is one the
result is zero, and if `value` is equal to `base` the result is one.

#### <span id="ex-round">ROUND</span>

    [ROUND]
    [ROUND, option_args]
    [ROUND, option_args, value_expr]

Round to a decimal position, defined for both numbers and strings.

This operates on the current node unless a second argument (value context) is
provided.  The input must be a number or string.  The `option_args`
(value context) may be an integer providing the `shift` parameter, or an object
with any of the following properties: `mode`, `at`, `shift`, `as`.

This expression is defined in terms of decimal digits, allowing it to operate
on strings as well as numbers.  String inputs must pass validation according to
`CASTNUM`.  Numeric inputs are first converted to decimal representations
according to `CASTSTR`, and rounding is defined in terms of those decimal
digits.  (implementations are free to use any algorithm that produces
equivalent results)  In many cases, floating point error cannot be avoided, and
graft authors should attempt to process numbers in an integer or string form to
work around the problem.

Rounding is performed according to one of the following modes, which may be
specified by ID or name:

ID | Name      | Meaning
---|-----------|---------------------------------
 0 | DOWN      | round toward zero (truncate)
 1 | HALF_UP   | round nearest, exact .5 away from zero (financial)
 2 | HALF_EVEN | round nearest, exact .5 toward even (scientific)
 3 | CEILING   | round toward positive
 4 | FLOOR     | round toward negative
 5 | UP        | round away from zero

The default mode is `1`, for standard math and accounting rounding.

The `at` and `shift` options must be integers, but default to zero if not
specified.  Rounding is applied at the `at`-th digit below the decimal point as
if multiplying by `10**at`, rounding to an integer, then dividing by that
same multiplier.  `at` may be negative to round within the whole portion
of the number.  The parameter `shift` works in a similar manner, but actually
does pre-multiply the number by `10**shift`.  The overall effect can be
described as

    round_to_int(number * 10**shift * 10**at) * 10**(-at)

but all changes to the decimal point should be done logically according to
base-10 instead of using base-2 floating point math.  If the number was
described in scientific notation, the exponent should be processed directly.

The `as` option determines the output format, and may be specified by ID or by
name:

ID | Name | Behavior
---|------|-----------------------------------------------------------------
 0 | NUM  | Return a number in any available number format
 1 | INT  | Return a number specifically as an integer (lossless)
 2 | STR  | Return a string of pure decimal digits (and sign)
 3 | SIG  | Return a string preserving significant digits

When the input is a string, `as` defaults to "STR".  When applied to numbers,
`as` defaults to "NUM".  Negative zero is preserved if that information is
available and can be preserved in the desired format.  (host JSON decoders
often discard it, but it will be known if the input was a string)
When returned as `"NUM"`, casting to a number is permitted to lose precision.
When returned as `"INT"` the implementation must store the value in a container
without loss of precision, or fail.

When returned as `"STR"`, the implementation must write the full decimal
representation without scientific notation.  If `at` is positive, exactly `at`
digits must follow the decimal point, including trailing zeroes as necessary.
Otherwise, the result must have no decimal point.
This may run into resource limits if the exponent is particularly large.

When returned as `"SIG"`, the result preserves the decimal precision of the
input, possibly truncated at the digits being rounded.  Precision of the input
is determined in the usual manner where trailing zeroes do not count unless
they follow a decimal point.  However, for this function the number may not end
with a decimal point since that is not a valid JSON syntax; scientific notation
is required for representing a precision coarser than the tenths digit when the
digits end with zero.  More precisely, the precision of the result is the
lesser of the input's significant decimal position (adjusted by shift) and the
rounding position `at`.  When the trailing digits of precision are zero,
including when rounding produces a value of zero, the decimal precision must
still be represented.  Scientific notation outputs with multiple digits should
have exactly one digit before the decimal point.

By example:

    [ROUND, { as: "SIG" }, "9.9"]
       -> "1.0e1"
    [ROUND, { as: "SIG" }, "9.900"]
       -> "1.0e1"
    [ROUND, { at: 2, as: "SIG" }, "9.500"]
       -> "9.50"
    [ROUND, { at: -2, as: "SIG" }, "1234"]
       -> "1.2e3"
    [ROUND, { at: -10, as: "SIG" }, "1.25e20"]
       -> "1.25e20"
    [ROUND, { at: -9, as: "SIG" }, "1.25e10"]
       -> "1.3e10"
    [ROUND, { at: 2, as: "SIG" }, "0.0000" ]
       -> "0.00"
    [ROUND, { at: -1, as: "SIG" }, "0" ]
       -> "0e1"

Implementations must not be written in a way that triggers failure due to the
logical size of intermediate numbers vs. the available numeric storage types,
unless the output format requires a number and the final computed value would
also exceed those limits.  Implementations may fail if the addition/subtraction
on the exponent number itself would exceed the portable integer-size
requirements.

Note that the plain-integer form of the options argument is used as the `shift`
parameter to enable easy tests against floating-point numbers:

    // foo == 1.234, without relying on floating point equality
    { foo: [IS, [ROUND,6], 1234000] }

## Implementation Hints

This specification tries not to dictate too many details of an implementation,
but implementors may find these details helpful.

### Array Metadata

There are three special features that require annotating arrays with some
metadata:

  * They may carry [`SPLIT` metadata](#split-metadata) which various actions
    and expressions need to process, if present.
  * They may have delayed insertions or deletions pending for a
    [`MOVE` action](#act-move), though this can perhaps be kept locally to the
    action's own execution state.
  * They may be a virtual array of characters used during a regular expression
    (or even during SPLIT) where implementations likely want to keep the data
    in string form and make elements available on demand.  This can be avoided
    if an implementation actually does expand the string into a true array,
    which is a valid strategy for more minimalist implementations.

There are multiple ways that implementations can deal with these requirements:
they can create tree node objects of "array with metadata" and then ensure
those get flattened to regular arrays before potentially storing them into the
target tree of data, or record the metadata as inside-out properties of an
array keyed to the array's memory address or similar identity, or even build a
complete parallel tree of metadata for all namespaces and mutate it with the
same operations being applied to the data tree.

### Failure State

While this specification avoids taking a stance on exactly how a failed JGraft
operation should look to applications, each implementation needs to provide
some concrete rules about this to its users.  In particular, the `MOVE` action
leaves arrays in an inconsistent state until it is complete.

The simplest approach for `MOVE` is to just complete all the pending insertions
and deletions as if the move action was composed of only the successful pairs,
which doesn't require any additional code.  An equally valid approach would be
to set queued array element deletions to `null` and forget about queued
insertions, providing a clearer state to the error handler about how things
looked when it failed.

Implementations may also choose to guarantee that all actions are atomic with
respect to the runtime JGraft state, but this is much more difficult to
implement.

