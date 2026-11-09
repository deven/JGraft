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
convention.

Implementations may choose to use host-language objects of some sort to
represent actions and expressions at runtime, then perform the array encoding
during serialization and reconstruct the objects during deserialization.
Implementations could also choose to leave the JGraft data
structure in its JSON-compatible form and interpret it on the fly.
They should make it clear to the developer whether the data structure the
application code interacts with is using objects and literal arrays, or the
direct "arrays-are-special" representation of JGraft.
Since the object model of a host language is left unspecified, the remainder of
this specification uses the JSON representation of actions and expressions,
using JavaScript-like notation for readability.

### Argument Contexts

Every action and expression declares the context of each of its arguments.
Argument Contexts help reduce the verbosity of the encoding by giving more
complex meaning to simpler JSON structures.

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

Reference expressions used in value context may only refer to paths which
exist.  Missing path properties count as an `INVALID_TARGET` error.

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
    structure to match against.  Reference expressions are also treated as
    returning values, except for `EXPR` which substitutes some other
    expression in its place, to be composed at runtime.

The section [Matching](#matching) describes the process in detail.

#### Regex Context

Regular expressions are implemented using mostly the same specification
structure as general matching, but operating on a virtual array of characters.

  * One-character strings describe characters
  * Strings of other lengths implicitly become [`SEQ`](#ex-seq)
    expressions, matching a sequence of characters
  * Non-negative integers describe Unicode codepoints
  * Arrays represent expressions; match expressions become part of the matching
    algorithm, subexpressions (via [`EXPR`](#ex-expr) ) that resolve to match
    expressions get re-interpreted according to these rules, and all other
    expressions evaluate to a plain value interpreted according to these rules.
  * Any other type of data (non-integer number, object, escaped-array, or date)
    counts as an `INVALID_OPERAND` error.

The section [Regex Matching](#regex-matching) describes the process in
detail.

#### Path Context

Paths are used to refer to data within one of the [namespaces](#namespaces),
and may be used for reading or writing.

  * Non-objects/non-arrays are interpreted as a single argument to a
    [`NODE` expression](#ex-node), though some actions can override the
    implied namespace.
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
and `LESSEQ` expressions will fail with an `INVALID_TARGET` error.
You can use the `CASTDATE` function to cast values to the same precision for
comparison.

## Namespaces

Actions and expressions can make references to data in six namespaces:

  * Current Node       - initial tree of data supplied as input, implicitly
                         referenced by many expressions and directly by the
                         [`NODE` expression](#ex-node).
  * Constants          - a read-only tree of values declared in the
                         [`JGRAFT` action](#act-jgraft) and referenced by the
                         [`CONST` expression](#ex-const).
  * Common Expressions - a read-only collection of parsed/validated expression
                         trees declared in the [`JGRAFT` action](#act-jgraft)
                         and referenced by the [`EXPR` expression](#ex-expr).
  * Stash              - a read/write tree of temporaries shared between
                         actions in the scope of the same `JGRAFT` action,
                         referenced by the [`STASH` expression](#ex-stash).
  * Match Captures     - a read-only tree of data captured by the named
                         sequences in an enclosing `MATCH` or `IF` action,
                         referenced by the [`CAP` expression](#ex-cap).
  * Temporaries        - a read/write tree of temporaries that only exists for
                         the duration of one action, referenced by the
                         [`TEMP` expression](#ex-temp) and which may be
                         localized during expressions using [`WITH`](#ex-with)
                         or [`LOCAL`](#ex-local).

While the Current Node starts as a distinct namespace, within some expressions
it can become an alias of something other than the input data.  Aside from
current node aliasing, each tree logically owns its own data and is strictly a
tree for all purposes of JGraft actions and expressions.  However, so long as a
tree can only be read from (the read-only namespaces, and the effectively
read-only environment while evaluating expressions, which are not permitted to
have side effects) implementations are permitted to share subtrees within and
across namespaces, making the namespaces technically acyclic graphs.
The expression language has no means to observe that two read-only objects or
arrays are the same entity, so authors of JGraft can still consider
the namespaces to always be trees.  Application code interacting with the
JGraft state may be able to tell the difference, though.

No namespace other than the input data may have its root node overwritten.
All namespaces except the `TEMP` namespace may reference the root node directly
for copying or enumerating properties.  `TEMP` is excluded so that extensions
may expose unofficial data into the `TEMP` namespace without it becoming
discoverable by JGrafts that don't expect it to be there.  A JGraft can still
test for the existence of `TEMP` properties using match expressions, but they
have to know specifically what they are looking for.

## Paths

Several actions and expressions use the concept of a "path".  A path is a
list of object properties, array indices, or aliases that descend into the tree
of a namespace.

In general, strings may only refer to object properties and integers may only
refer to array elements.  This is particularly important when auto-vivifying a
path; integers will create arrays and strings will create objects.
However, paths for the `CONST`, `EXPR`, `STASH` and `TEMP` namespaces permit a
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
type of value found in a path counts as an `INVALID_OPERAND` and should always
be upgraded to `INVALID_GRAFT` if it was specified as a literal value.

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
verify that the input data tree matches expectations (or find a matching
location in the tree with some [fuzzy matching](#fuzzy-matching) ) and then
within that use `COPY`, `MOVE`, or other actions to alter the tree.

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

The `RAISE` action can be used to provide improved diagnostics to a user
applying a JGraft, or within `IF` to detect unhandled inputs that should be
rejected.

The `ATSPLIT` action is a tool for tokenizing strings in order to make changes
within them, then reassembling the modified string.  It can also be used to
access specific substrings and copy them into stash variables for use in other
actions.

The `SPLICE` action is an optimization vs. `COPY` or `MOVE` for making
changes to a range of an array.

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
because they may be evaluated any number of times during fuzzy-matching, and
because JGraft does not define an order for enumerating object properties
during the matching process.  They *may* have a side effect of incrementing
a resource counter that aborts the graft operation due to resource usage, but
that is not visible *to the expressions*.

### Matching

The matching system compares the current node with a specification structure
composed of literal data and/or subexpressions.  It operates on several pieces
of scoped state:

  * `exact` - whether unspecified properties/elements cause a match to fail.
  * `regex` - whether the match is applied to a virtual array of characters.
  * `sequence` - how expressions may match variable numbers of array elements.

The `exact` flag is set for an expression subtree using the `IS` or `HAS`
expressions.  The `sequence` mode is enabled with the [`SEQ`](#ex-seq),
[`SEQMIN`](#ex-seqmin) or [`SEQMAX`](#ex-seqmax) expressions but is not
inherited by subexpressions which match deeper into the data tree beyond the
current array.  The `regex` flag is set by any expression declared in
[regex context](#regex-context) such as within the [`STR` expression](#ex-str).

For all contiguous portions of the match specification composed of plain
structures or match expressions, the matching algorithm continues building on
the same match state.  If the match algorithm encounters an `EXPR` path
expression, the referenced expression becomes part of the current match
specification and likewise continues building on the same match state.
Note that expressions are values by default, and interpreting them as match
expressions requires them to be declared as such, as described in
[the `EXPR` expression](#ex-expr).
If the matching algorithm encounters any other type of expression, it evaluates
it as a function and uses the resulting value (which may not contain
expressions) as a literal structure to match against.
If the function expression includes an inner match expression, the inner match
expression begins a new match state independent of any ancestor match state.
It retains the current node, but begins with default HAS semantics and no
sequence context, and only gets regex context if matching against a virtual
array of characters.  This is covered in more detail under
[expression interaction](#expression-interaction).

The baseline for a match is that nothing can compare equal unless it is the
same type.  Plain objects can only match plain objects, arrays can only match
arrays, and each type of scalar can only match that same type of scalar.
For non-object non-array elements of the specification, matching checks for
equality as follows:

  * `null`, `true`, and `false` are equal only to themselves.
  * Numbers compare using the implementation's native representation of JSON
    numbers after decoding.  JGraft does not specify behavior related to
    floating point roundoff; see the [`NUM` expression](#ex-num) for a quick
    way of checking whether a value is within a range.
  * Strings compare codepoint-to-codepoint, though implementations may be
    configurable in determining how an array of codepoints is generated.
  * `date` can only match `date`, and all fields must be identical.
  * `datetime` can only match `datetime`, and all fields must be identical.
  * `timestamp` can only match `timestamp`, and both must refer to the same
    instant after adjusting for time zone offset.

For an object `spec_obj` in the specification being compared to current node
`data_obj`, the matching algorithm iterates the properties of `spec_obj` and
temporarily sets the current node to the corresponding property of `data_obj`,
even if no such property exists.  It then recursively tests the specification
for that property.  This may succeed even on a nonexistent current node due to
the [`NONE` expression](#ex-none) which returns true when a pattern *doesn't*
match.

For arrays in the specification, the matching algorithm takes steps identical
to object-matching, iterating the array elements instead of object properties,
and likewise fails in `exact` context if array elements exist which were not
included in the specification.
When sequence context is not involved, every element of the specification
matches against one element of the data (or one nonexistent element at the
end).  Specification elements beyond the `LENGTH` of the array do not match.
However, if sequence context is involved with any element of the array, the
array match is handled according to the rules described in
[sequence matching](#sequence-matching).

#### Sequence Matching

Sequence matching is based on a regular language automata theme.  Expressions
evaluated in sequence context (initiated implicitly by
[regexes](#regex-matching) or by applying a [`SEQ`](#ex-seq) /
[`SEQMIN`](#ex-seqmin) / [`SEQMAX` expression](#ex-seqmax) to array elements)
have behavior defined in terms of "initial state" and "generated successor
states", with the initial state being a position within [0,length] where a
match needs to occur, and successor states being all the ways that the match
can resolve successfully from that starting position.
For every match expression where sequence context behavior is not specified,
the successor state produced in sequence context is the position following the
current element; i.e. match expressions consume one element by default.
Some expressions are simply described as "zero width assertions", which means
they consume no elements and the successor position is identical to the initial
position, unless the assertion fails, making the successor the empty set.

Implementations are likely to need to iterate the successor states as they look
for an overall match for the array specification, but no specific order is
required for this iteration and implementations are free to apply optimizations
that eliminate impossible states or collapse redundant successor states.
This also gives implementations the option to optimize things with a DFA
compilation when the specification is composed purely of regular language
constructs.

Sequence context can be configured to resolve in one of three ways:

  * boolean - Nothing needs to know which elements matched, and the
              algorithm may terminate as soon as it finds any match.
  * longest - The algorithm finds the greatest number of elements which can be
              matched by the specification.
  * shortest - The algorithm finds the fewest number of elements which can be
              matched by the specification.

Sequence context is only resolved in terms of the whole array, not as decisions
within individual expressions or named sequences.  Various regex contexts will
set either `boolean` or `longest` resolution.  When performing structural
matches, there is normally no preference for the overall length matched unless
one is explicitly requested.  As `SEQMAX` / `SEQMIN` are designed, making the
match observable with a capture also requires specifying the longest/shortest
preference.  When no captures are observable, implementations may stop as soon
as any complete match succeeds, without resolving length or position
preferences.  When captures are observable, of all the final states which can
match the complete specification for the array, the algorithm chooses one
according to these priorities:

  * Longest overall or shortest overall, if an overall length preference was
    specified.
  * For each sequence of the current array having a length preference, in
    specification order:
    * Longest or shortest match according to its preference.
  * For each sequence of the current array having a length preference, in
    specification order:
    * Earliest ("leftmost") start of a match.
  * For each capture-producing substructure in the sequence specification, in
    specification order:
    * <span id="earliest-substructure-match">Earliest array element at which
      the substructure matches.
      </span>

The fourth rule has no bearing on the boundaries of captures in the current
array; it resolves ambiguities in selecting which array element should provide
captures from deeper arrays or strings.  Consider this example:

    [[
      [SEQ,
        [REP],
        { a: [[ [SEQMAX, "from_a", [REP] ] ]] },
        [REP],
        { b: [[ [SEQMAX, "from_b", [REP] ] ]] },
        [REP]
      ]
    ]]

The substructure that captures "from_a" could match at *any* element of the
current array except the last, and the substructure that captures "from_b"
could match any element except the first.  The current array has exactly one
sequence with no length preference.  The "longest" preference in the
inner array has already been resolved at that level before becoming a
successful substructure match in the context of the current array, so those
sequences do not participate in resolving the sequences of the current array.
This is given deterministic behavior by selecting the earliest candidate array
element.  In the example, this rule uses the captures from the earliest array
element having an array at property "a" followed by the first element after
that having an array at property "b".

Sequence context affects the behavior of several other match expressions:

  * [`NONE`](#ex-none) becomes a zero-width assertion.
  * [`ANY`](#ex-any) matches however many elements its subexpression does.
  * [`ALL`](#ex-all) matches at least as many elements as required for all of
    its subexpressions to match.  (see the expression description for details)
  * [`REP`](#ex-rep) expressions are permitted.

A `SEQMIN` / `SEQMAX` expression may only be used at the root of a match
specification being applied to an array's elements, and a `SEQ` expression may
only initiate sequence context there (though `SEQ` may be used in any existing
sequence context as a general way to specify sequential matches).
The restrictions on entering sequence context ensure that `NONE`, `ANY`, and
`ALL` don't gain surprising semantics without directly requesting them, and the
specific restriction on `SEQMIN` and `SEQMAX` ensures that named sequences are
always referring to unambiguous ranges of array elements without needing to
define an iteration order for testing alternatives or greedy semantics for
every `REP` expression.  These restrictions are applied *after* replacing any
common subexpression references.

After a successful sequence-context match of an array, named sequences may
get carried as annotations to the current match state.  The `capture_name` must
not be currently defined in the match state; a duplicate counts as an
`INVALID_OPERAND` error.
This process is skipped entirely if the current match state is within a `NONE`,
`ANY`, or `REP` expression at a higher level of the match structure; i.e.
anything that could make the capture conditional causes it to be excluded
entirely.  This also means that the captures are not observable within these
expressions, and the length preference of each sequence reverts to `boolean`.

If the overall match succeeds, the captures (which may be an empty set if no
named sequences were used) are available as output.  If the match was occurring
as the test of a `MATCH` or `IF` action, the captures become the new state of
the [capture namespace](#ex-cap) locally for its contained actions.
If the match was occurring within a `CAPTURE` function, the named captures
become the properties of the returned object.

#### Fuzzy Matching

Implementations may offer a feature for looking for matches at a slightly
different path than the one specified, such as by trying nearby array elements
if the path named a specific array element.

The exact algorithm for performing the search for a "fuzzy" match is dependent
on the engine and parameters supplied by the user.  This specification leaves
fuzzy matching open to experimentation by implementations.  However, all
implementations should follow these guidelines:

  * If a path referring to the source tree was altered to allow a match to
    succeed, all access to the node(s) where the alteration(s) were made must
    receive the same alteration, but only for actions (and their expressions)
    under the scope of that match.
  * The alteration to a path must be linked to the node (object or array)
    such that if the node gets moved to a different path, the alteration
    metadata now affects only the new path.
    This includes moves to/from other namespaces like the stash.
  * Alterations to a path must only apply *before* resolving aliases.
    If a match expression using a negative array index is altered, it will
    not have any effect on the same array element when specified as a positive
    integer.
  * Fuzzy matching may not be used in regular expression context.
  * Implementations are strongly discouraged from attempting fuzzy matching on
    an array involving sequence context.  The sequence matching feature is
    capable enough to make fuzzy matching unnecessary, so falling back to fuzzy
    matching is probably unwanted.
  * Implementations are encouraged to restrict fuzzy matching to arrays/objects
    where every property affected by an action was previously tested by its
    containing `MATCH` action.  i.e. record every path that was tested during a
    successful fuzzy match and then if the actions try to access any path
    outside of those paths, abort the attempt and return `NO_MATCH` as if the
    fuzzy match wasn't attempted.
  * Implementations should not enable fuzzy matching by default.

Future versions of this specification may specify fuzzy matching in more
detail as common useful strategies and antipatterns emerge.

### Regex Matching

Regex matching can only begin when the current node is a string.
The subject string is broken into a virtual array of characters, and then the
match expressions are applied to that virtual array, with
[sequence context](#matching) implicitly enabled.
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
  * If the current node is changed to something other than a virtual array
    of characters (via 2-argument `HAS` or 2-argument `IS`), the algorithm
    switches back to Non-Regex Matching for the duration of that scope.

In some cases, only a boolean result is required, and the match ends as soon
as the expression is satisfied.  Other cases require finding the longest
match, requiring a search over every possibility of the match expression to
see which is the longest, though it may end early if the whole string is
consumed.  If an expression is constructed from only "textbook regular" match
expressions, an implementation can compile the expression into a DFA, or
possibly a host-language regular expression for improved performance.
Elaborate non-regular match expressions may be used in regex context, but can
cause a great deal of iteration and may quickly run into resource limits.

### Expression Summary

The following expressions are available:

Name                     | Type  | ID | Description
-------------------------|-------|----|----------------------------------------
[EXPR](#ex-expr)         | Ref   | -5 | An element of the common subexpressions
[CAP](#ex-cap)           | Ref   | -4 | A path in the capture namespace
[TEMP](#ex-temp)         | Ref   | -3 | A path in the temp namespace
[STASH](#ex-stash)       | Ref   | -2 | A path in the stash namespace
[CONST](#ex-const)       | Ref   | -1 | A path in the const namespace
[NODE](#ex-node)         | Ref   |  0 | A path in the current node
[HAS](#ex-has)           | Match |  1 | Partial structured match
[IS](#ex-is)             | Match |  2 | Exact structured match
[NONE](#ex-none)         | Match |  3 | Logical NOT/NOR of match exprs
[ANY](#ex-any)           | Match |  4 | Logical OR of match exprs
[ALL](#ex-all)           | Match |  5 | Logical AND of match exprs
[EXISTS](#ex-exists)     | Match |  6 | Current node exists
[ARRAY](#ex-array)       | Match |  7 | Match arrays, specific elements
[STR](#ex-str)           | Match |  8 | Match strings, optional regex
[NUM](#ex-num)           | Match |  9 | Match numbers, optional ranges
[BOOL](#ex-bool)         | Match | 10 | Match booleans
[DATE](#ex-date)         | Match | 11 | Match date-like things
[WITH](#ex-with)         | Match | 12 | Scoped overrides to TEMP namespace
[SEQ](#ex-seq)           | Match | 13 | Match a sequence of adjacent elements
[SEQMAX](#ex-seqmax)     | Match | 14 | Named sequence, prefer longest match
[SEQMIN](#ex-seqmin)     | Match | 15 | Named sequence, prefer shortest match
[REP](#ex-rep)           | Match | 16 | Match repeatedly on adjacent elements
[START](#ex-start)       | Match | 17 | Match at first element of array
[END](#ex-end)           | Match | 18 | Match at length of array
[CHARS](#ex-chars)       | Match | 19 | Match to a set of characters
[CAPTURE](#ex-capture)   | Fn    | 50 | Match, then return captured sequences
[LOCAL](#ex-local)       | Fn    | 51 | Scoped overrides to select namespaces
[NOT](#ex-not)           | Fn    | 52 | Logical NOT of value exprs
[AND](#ex-and)           | Fn    | 53 | Logical AND of value exprs
[OR](#ex-or)             | Fn    | 54 | Logical OR of value exprs
[LENGTH](#ex-length)     | Fn    | 55 | Return length of an array or string
[CURPROP](#ex-curprop)   | Fn    | 56 | Get property/index of the current node.
[SLICE](#ex-slice)       | Fn    | 57 | Return span of an array or string
[CONCAT](#ex-concat)     | Fn    | 58 | Join spans of arrays or strings
[REDUCE](#ex-reduce)     | Fn    | 59 | Combine array elements
[FILTER](#ex-filter)     | Fn    | 60 | Select array elements
[MAP](#ex-map)           | Fn    | 61 | Transform array elements
[SPLIT](#ex-split)       | Fn    | 62 | Split a string into an array
[JOIN](#ex-join)         | Fn    | 63 | Join, using split metadata
[PROPS](#ex-props)       | Fn    | 64 | Return properties of an object
[MKOBJ](#ex-mkobj)       | Fn    | 65 | Construct an object from properties
[CASE](#ex-case)         | Fn    | 66 | If/else that returns a value
[FAIL](#ex-fail)         | Fn    | 67 | Fail with INVALID_TARGET
[CASTBOOL](#ex-castbool) | Fn    | 68 | Cast value to boolean
[CASTNUM](#ex-castnum)   | Fn    | 69 | Cast value to number
[CASTSTR](#ex-caststr)   | Fn    | 70 | Cast value to string
[CASTDATE](#ex-castdate) | Fn    | 71 | Cast value to date/datetime/timestamp
[LESS](#ex-less)         | Fn    | 72 | Less-than test
[LESSEQ](#ex-lesseq)     | Fn    | 73 | Less-or-equal test
[ADD](#ex-add)           | Fn    | 74 | Add numbers
[SUB](#ex-sub)           | Fn    | 75 | Subtract numbers
[MUL](#ex-mul)           | Fn    | 76 | Multiply numbers
[DIV](#ex-div)           | Fn    | 77 | Divide numbers
[MOD](#ex-mod)           | Fn    | 78 | Calculate Modulus
[POW](#ex-pow)           | Fn    | 79 | Calculate exponents
[LOG](#ex-log)           | Fn    | 80 | Calculate logarithms
[ROUND](#ex-round)       | Fn    | 81 | Decimal rounding on numbers or strings

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
Return values from functions cannot contain expressions; arrays are considered
literally.

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

For any operation that computes a new numeric value, if the value would
overflow the host language's representation for numbers (or configured limits,
which an application might want for portability) the operation fails with
`UNSUPPORTED_GRAFT`.  Several math expressions are defined in terms of
the host language math operators.  In some environments an overflow can return
a special infinity value, though these cannot be serialized to JSON.
Implementations may give the application the option of preserving infinity
values in the output (and using them as input to other expressions where that
makes sense) instead of failing with `UNSUPPORTED_GRAFT`.  However, division
by exactly zero should always fail with `INVALID_TARGET` rather than returning
an infinity value.

Some environments also return a "not a number" value for nonsensical
operations.  These values should always be converted to an `INVALID_TARGET`
error.

## Errors

Applying a JGraft to a target data structure may fail with:

  * `NO_MATCH`        - The JGraft explicitly rejected the input data as
                        not meeting its preconditions.
  * `INVALID_TARGET`  - The graft describes an operation that can't apply due
                        to the type or value of the data it was applied to.
  * `INVALID_OPERAND` - The calculated runtime parameters describing how an
                        operation should be performed violate the spec.
  * `INVALID_GRAFT`   - The structure of the JGraft itself or parameters of
                        expressions intrinsically violate the spec.
  * `UNSUPPORTED_GRAFT` - The graft requires data or operations that the
                        implementation’s host environment cannot faithfully
                        represent or perform, including insufficient version
                        support or use of forbidden object property names.
  * `RESOURCE_LIMIT`  - Applying the graft would exceed configured limits,
                        such as too much memory, too much recursion, too many
                        generated properties, or too deep of a tree.

Ideally (when supported by the implementation and within resource limits),
a logically valid JGraft should either succeed or generate `NO_MATCH` and a
logically invalid JGraft should result in `INVALID_GRAFT`.
When expressions are used for arguments and evaluate to values that violate
the spec, this is less clear, and the errors `INVALID_TARGET` and
`INVALID_OPERAND` are used to discern between errors that could be the result
of the input data (or data used by the generator) vs. more fundamental bugs in
the generation of the expressions.
When these errors occur during action execution, outside of match evaluation,
they represent uncertainties between the cases where either the graft should
have used more comprehensive match expressions to validate the input data
before starting, or where the graft is logically invalid in an indirect manner.
Each action and expression documents which invalid conditions constitute
`INVALID_TARGET` vs. `INVALID_OPERAND`.  If an action or expression detects
both `INVALID_OPERAND` and `INVALID_TARGET` conditions while evaluating its
arguments or performing its own operation, it should report the higher-priority
`INVALID_OPERAND` error.  Implementations are not required to evaluate
additional arguments after encountering an error, but are encouraged to do so
within the constraints of the specified behavior for that action or expression
in order to improve diagnostics.

Implementations may perform static analysis to determine whether
`INVALID_TARGET` and `INVALID_OPERAND` errors actually represent
`INVALID_GRAFT` and report them as such, but to make lightweight
implementations possible, this is not required.  For example, if an
implementation is constructing host language objects to represent expressions
and the constructor detects that an integer parameter is being supplied by an
expression that can only return strings, it may end with `INVALID_GRAFT` before
it even begins executing the JGraft, while simpler implementations would report
this at runtime as `INVALID_OPERAND`.  However, `INVALID_TARGET` errors within
match expressions are never upgraded to `INVALID_GRAFT`, as described below,
and intentional failures (like `RAISE` with level "fail", `FAIL`, or `CASE`
lacking an "else") are also never upgraded to `INVALID_GRAFT`.
In the remaining cases, to upgrade an `INVALID_TARGET` error
to `INVALID_GRAFT` the static analysis must prove that in the *complete* graft
semantics (such as the short-circuiting behavior of `AND`, `OR`, and `NOT`,
which may be used intentionally to guard deeper expressions from evaluation
unless an earlier test succeeds) the expression always results in an error
regardless of input.

By default, `INVALID_TARGET` or `INVALID_OPERAND` errors that occur within
match expressions are considered part of the normal process of probing the
shape of the data without being overly verbose.  Generators of JGraft might
produce expressions that always resolve to these error states and it would be a
burden on the generators to eliminate those from generated expressions.
Implementations must trap `INVALID_TARGET` or `INVALID_OPERAND` errors in
match expressions and convert them to simple failed-to-match conditions, unless
static analysis can prove that `INVALID_OPERAND` is actually `INVALID_GRAFT`,
in which case it may be upgraded.  Additionally, for expressions `ANY` and
`NONE`, these errors get trapped for each individual argument and converted to
false subexpressions rather than causing the outer expression to fail.
If an implementation can prove that a match expression always generates an
`INVALID_TARGET` error, it may emit warnings about this, but must not upgrade
them to `INVALID_GRAFT`.
Static analysis of match expressions should be narrower than static analysis
of actions; to upgrade `INVALID_OPERAND` to `INVALID_GRAFT` it must establish
that the parameter is intrinsically invalid without relying on constraints
established by surrounding match assertions or preceding actions.  Analysis may
consider an expression supplying a parameter, including its subexpressions
and local bindings.  This avoids upgrading automated combinations of assertions
into a fatal error.  For example:

    [ALL,
      {offset: "2"},
      [IS, [SLICE, "abcdef", [NODE, "offset"]], "c"]
    ]

The first condition establishes that the second condition will trigger an
`INVALID_OPERAND`, but in isolation the second expression's correctness still
depends on input data, so in a match context this is not considered an invalid
graft, just one that never matches.  A more intelligent generator could
eliminate this subexpression, but is not required to, regardless of the
configured JGraft validation level.

The `INVALID_GRAFT`, `UNSUPPORTED_GRAFT`, and `RESOURCE_LIMIT` errors always
immediately terminate the graft operation regardless of match context.
Likewise, unspecified errors from application callbacks or other
implementation aspects should terminate the graft operation.

The `UNSUPPORTED_GRAFT` covers the basic case of a new JGraft version seen by
an old implementation, and also cases where a host language or environment
is unable to represent (or restricted from representing) certain things that
are legal in JSON's data model.  For example, on older JavaScript engines, the
`__proto__` property is problematic and implementations may entirely forbid
use of that property in any expression or generated value.  Other
non-JavaScript implementations may also provide an option to forbid that
property in order to ensure a graft is compatible with old JavaScript
implementations.

The error generated by application of a JGraft is not always deterministic.
Implementations may encounter a nonfatal error that aborts a match before
finding a different fatal error that also exists, such as when iterating object
properties in an implementation-defined order where the expression for one
property hits a resource limit and the expression for another property is
logically invalid and the expression for a third property simply doesn't
match.  While deterministic errors would be nice, allowing this nondeterminism
also allows light-weight implementations to perform lazy validation of the
graft structure.  The degree of validation effort an implementation uses could
even be configurable.

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
  - expr: an array declaring value context macros

When exported to JSON, outer metadata should contain `v` (minimum version
to correctly process the structure), and it should be at least as high as
any minimum version seen within.  It is permitted to declare `v` on
sub-structures, for composability between different sources.
Future versions of the JGraft specification are expected to be backward
compatible, but if incompatibilities arise, implementations should aim to
support older versions dynamically so that they can process sub-structures
generated according to a prior specification.  If the version is greater
than the highest specification version the implementation knows it supports,
it immediately fails with `UNSUPPORTED_GRAFT`.

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
      - `val_expr` may be a [value or expression](#value-context).
      - Set property `const[name]` to the value, after evaluating any
        expressions within.  `CONST` expressions evaluate according to the
        `const` namespace in its current state before this assignment. `STASH`
        expressions still refer to the parent scope's stash, if one exists.
  - If the metadata contains an `expr` property,
    - Set the `expr` namespace to a shallow clone of the parent `expr`
      namespace, or an empty object at the root.
    - For each (`name`,`val_expr`) pair of elements in the `expr` array,
      - `name` must be a single property string, or integer (which gets
        coerced to a string)
      - `val_expr` may be a [value or expression](#value-context).
      - Set property `expr[name]` to the value-construction structure *without*
        evaluating any of it.  In other words, it captures no context and paths
        like `NODE` or `TEMP` will be interpreted in the context of the `EXPR`
        expression that invokes it.
  - Set the `stash` namespace to a new empty object.

### <span id="act-raise">RAISE</span>

    ['RAISE', level, message]
    ['RAISE', level, message, data]

As JGraft applies a patch it may emit diagnostic information, such as when
a match succeeded at an offset from the declared array.  You can emit your own
custom diagnostics as well, using this action.  The motivation is that while
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

Invalid literal arguments for `level` or `message` fail with `INVALID_GRAFT`.
If the `message` is an expression returning an invalid value, the action
fails with `INVALID_TARGET` (with the usual error escalation rules).

### <span id="act-at">AT</span>

    ['AT', path, subaction1, subaction2...]

Navigate to a [path](#paths) within the current node, then execute actions.

The `path` argument (path context) must refer to the current node or an
existing sub-node.  This will become the current node for the duration of the
execution of the sub-actions.  A nonexistent path fails with `INVALID_TARGET`,
but a path referring to the wrong namespace fails with `INVALID_OPERAND` (with
the usual error escalation rules).

### <span id="act-atsplit">ATSPLIT</span>

    ['ATSPLIT', path, split_spec, subaction1, subaction2...]

Navigate into a tokenized view of a node, then execute actions.

This is a combination of the `AT` action and `SPLIT` + `JOIN` expressions.
For a target node at `path`, it changes the current node to the array returned
by the [`SPLIT` function](#ex-split) called on the target node,
then executes actions on that array.  After all subactions complete, the value
of the current node (which may not even be the same array after `COPY` or
`MOVE`) is passed to the [`JOIN` function](#ex-join) along with `split_spec` to
build a new string value for the target node.  The `path` argument is defined
per the `AT` action, and the `split_spec` argument is defined per the `SPLIT`
function.  The `path` for the target node is not evaluated a second time when
assigning the new value, nor are any of the expressions within `split_spec`.
(this means implementations must be able to pass pre-evaluated `split_spec` to
their `SPLIT` and `JOIN` functions)

`ATSPLIT` is similar to the following, but with the added benefit of changing
the current node to the temporary array, whereas the example below would need
to repeatedly act on `[STASH,0]`:

    [AT, path,
      [COPY, [SPLIT, split_spec], [STASH,0]],
      subaction1,
      ...
      subactionN,
      [COPY, [JOIN, split_spec, [STASH,0]], [NODE]]
    ]

`ATSPLIT` is the primary tool used to re-implement text diff/patch behavior:

    [ATSPLIT, [NODE],
      { sep: [ANY, "\n", "\r\n"], default: "\n", trim: [REP,0,-1," "] },
      [MATCH,
        [ARRAY, 10,
          "Line ten",
          "Line eleven",
          "Line twelve",
          "Line thirteen"
        ],
        [SPLICE, 11, 2,
          "New Line eleven"
          // no line 12
        ]
      ],
    ]

### <span id="act-match">MATCH</span>

    ['MATCH', match_spec, subaction1, subaction2...]

Execute actions on a node having the intended shape.

Assert that the current node matches a [match specification](#match-context),
then execute all sub-actions in sequence.  If it doesn't match, the graft
operation will fail with `NO_MATCH`, unless the user has enabled
[fuzzy matching](#fuzzy-matching) in which case the engine may look for nearby
potential matches.
If a fuzzy match is successful, the alterations to the paths described in
`match_spec` are likewise applied during all sub-actions.
This is analogous to how unix `patch` applies "hunk at offset" by first
searching for the matching lines then continuing as if they'd been specified
for that location.

The captured sequences of the match expression (even if the empty set) become
the [capture namespace](#namespaces) for the subactions.
Captures from a parent action's match are no longer visible, but could be
copied to the `STASH` namespace in an action before this if you need to access
them in the inner scope.

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

`IF` uses the same [fuzzy matching mechanism](#fuzzy-matching) as `MATCH`.
However, implementations should always attempt every condition of the `IF`
statement *without* additional fuzzy match alterations before trying them all
again with fuzzy searching enabled.  Alterations inherited from a fuzzy match
at a parent action will still be applied to both attempts.

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
don't exist, but the action fails with `INVALID_TARGET` if it would need to
convert a scalar, object, or array to a different type in order to resolve the
destination.  Recall that arrays are implied when an object path contains a
number, and objects are implied when the path contains a string.
To prevent inappropriate creation of sub-objects, use a containing `MATCH`
directive that asserts the presence or absence of the structure as desired.
Unlike in JavaScript, assigning to (or a path through) an array element greater
than `LENGTH` does not auto-vivify and fails with `INVALID_TARGET`.

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
general, counts as `INVALID_OPERAND`.  A structurally invalid source or
destination counts as `INVALID_TARGET`.

When the source property is an element of an array, the deletion of the
element implies that following elements will be shifted up to fill the gap.
However, this shifting and the corresponding change to `LENGTH` does not occur
until after all pairs have been processed.
Attempts to access an array element pending deletion fail with
`INVALID_TARGET`, including expressions like `SLICE` that attempt to clone
every element in a span of an array.  Moving an array with deletions pending is
not a problem since there is no need to enumerate the elements.
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
 2.5   | Fail with `INVALID_TARGET`
 false | Append immediately as element 2
 -1    | Overwrite element 1
 -1.5  | Queue insertion at `0.5`
 -2    | Overwrite element 0
 -2.5  | Queue insertion at `-0.5`
 -3    | Fail with `INVALID_TARGET`
 -3.5  | Fail with `INVALID_TARGET`

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
    argument list from those pairs by adding ".5" to each destination.  Every
    deletion will be paired with an insertion and the `MOVE` action can run in
    `O(N)` time without actual splice() calls.

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

    ['SPLICE', array_elem_path, count_expr, replacement1, replacement2...]

Replace a span of an array, just like the splice function found in most
programming languages.  The `array_elem_path` must resolve to an element of
an array (or to the `LENGTH` insertion point of an array) or the graft
fails with `INVALID_TARGET`.  `count` (value context) must evaluate to an
integer, and is the number of elements to replace.  Negative numbers are
aliases for the count that would end just before element `length-N`, and
`null` is an alias for `length-offset`.  The resulting count must be within
`[0..length-offset]` or it likewise fails with `INVALID_TARGET`.

The replacement arguments ([value context](#value-context)) are each evaluated
before making any alteration to the target array.

If [`SPLIT` metadata](#split-metadata) is present on the array it gets likewise
spliced.  The replacement values may also introduce `SPLIT` metadata to the
target array if none was present, in the same manner as if each element of the
result of the splice had been inserted at the end of a fresh array.

## Expressions

### Reference Expressions

#### <span id="ex-expr">EXPR</span>

    [EXPR, name]

Reference a pre-defined expression.

The common expression namespace is populated by the
[`JGRAFT` action](#act-jgraft).
It is a flat namespace, so referencing one of the expressions uses only a
single name rather than a path.  The other expression will be used as if it
had been specified in place of this `EXPR` expression, but preserving the
definition's value-construction or matching semantics.  It is possible to
set up infinite recursion using EXPR references, but likely to quickly run
into `RESOURCE_LIMIT` errors.  Implementations are not expected to optimize
tail-calls like a functional language would (but are permitted to).

Note that expressions are declared in value context and imply value
construction unless the root of the expression is a match expression.
This means if you declare a data structure containing expressions and
reference that expression in match context, it will still construct a value
to match against rather than applying subexpressions *during* the match.
A bare structure in match context would normally imply `HAS` or `IS`,
but to preserve that behavior as a common subexpression it must be explicit.
To preserve existing `HAS` / `IS` context of the caller, use an expression
like `ALL`.  Match expressions referenced in Regex context do still get
interpreted according to the Regex rules; regex context should be implemented
as a runtime context for match expressions rather than a distinct class of
expressions that happen to have the same names as match expressions.

#### <span id="ex-cap">CAP</span>

    [CAP]              // the entire namespace as an object
    [CAP, path...]

Reference data in the [capture namespace](#namespaces).

The arguments form a [path](#paths).  The capture namespace contains
[sequence capture results](#sequence-matching) from the most recent ancestor
`MATCH` or `IF` action.  This namespace is empty in any other scope.
The root-level properties are the same as the capture names and the values have
the form:

    {
      path:  // array of path elements from root of match to target
      ofs:   // starting offset
      len:   // number of elements matched
      lim:   // ofs + len
    }

These may be used as the argument for [`SLICE`](#ex-slice).  For example, to
select the captured array elements of "example" as a new array value,
you can use:

    [SLICE, [CAP, 'example'] ]

Note that this works for both arrays and strings that were matched in the tree
of the current node, but not for matches that applied against a temporary
current node.  It may also fail or return unintended results if used after
actions that re-alias the current node or modify data along the target path.
JGraft generators need to be mindful of these problems and should probably
copy slices to `STASH` or `TEMP` in the first action under a match.

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

#### <span id="ex-has">HAS</span>

    [HAS, match_spec]
    [HAS, value_expr, match_spec]

Match when the target has at least the properties described in `match_spec`.

The `match_spec` argument is declared using [match context](#match-context)
and the `value_expr` is declared using [value context](#value-context).
In the 1-argument form, the value being compared is the current node.

The `HAS` expression is the default for match context; a `[HAS,...]`
expression at the root of a match structure is redundant unless used in
the 2-argument form to establish an alternate current node.

In the 2-argument form, the current node does not change until matching begins
in the subexpression; this means that if `match_spec` is a reference or
function expression (evaluated to produce the match structure) `NODE`
references still refer to the old tree, but if `match_spec` is a structure or
match expression, `NODE` references refer to the new tree.  Further, if
`match_spec` is an `EXPR` expression which resolves to a non-match expression,
`NODE` expressions within the replacement still refer to the old tree until
it returns something that causes matching to begin again.

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

In [sequence context](#sequence-matching), the successor state produced is the
position following the current element, unless 2-argument form was used in
which case it becomes a zero-width assertion.

#### <span id="ex-is">IS</span>

    [IS, match_spec]
    [IS, value_expr, match_spec]

Match according to `HAS` but fail if the object/array contains unspecified
properties.

More precisely,

  * Every property named by the specification must successfully match,
    including against a nonexistent current node.
  * Every property actually present in the target must have a corresponding
    property in the specification.

The `match_spec` argument is [match context](#match-context) and the
`value_expr` is [value context](#value-context).  In the 1-argument
form, the value being compared is the current node.

As described in the [matching section](#matching), the entire tree of match
structure and match expressions within the `IS` expression inherit `IS`
semantics unless overridden with a `HAS` expression, but a match expression
used as a direct child of a function expression resets to `HAS` semantics.

Like `HAS`, in the 2-argument form the current node does not change until
matching begins in the subexpression.

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

    [NONE, match_expr...]

Match when the target does not match any of the [match-context](#match-context)
expressions.

This is like the function [`NOT`](#ex-not), but with
[match expression](#expression-overview) semantics rather than function
expression semantics.

In [sequence context](#sequence-matching), this is a zero-width assertion.
Additionally, named captures within `NONE` expressions of the same match
algorithm state (i.e. not new matches initiated by functions) are ignored,
including those deeper in the structure.

#### <span id="ex-any">ANY</span>

    [ANY, match_expr...]

Match when the target matches any of the [match-context](#match-context)
expressions.

This is like the function [`OR`](#ex-or), but with
[match expression](#expression-overview) semantics rather than function
expression semantics.  It requires at least one argument.

In [sequence context](#sequence-matching), the successor states produced by
this expression are the union of all the successor states produced by its match
expressions.
Additionally, named captures within `ANY` expressions of the same match
algorithm state (i.e. not new matches initiated by functions) are ignored,
including those deeper in the structure.

#### <span id="ex-all">ALL</span>

    [ALL, match_expr...]

Match when the target matches all of the [match-context](#match-context)
expressions.

This is like the function [`AND`](#ex-and), but with
[match expression](#expression-overview) semantics rather than function
expression semantics.  It requires at least one argument.

In element context `ALL` is fairly straightforward, but the behavior in
[sequence context](#sequence-matching) is a bit more involved.
Each argument is treated as a constraint that must be satisfiable from the
starting position.  The `ALL` expression generates one successor state for each
position among the states returned by any argument which also contains at least
enough elements to satisfy all of the other arguments.  Conceptually, matching
gets to continue from any of those successor state positions so long as all
the other arguments are satisfied within that number of elements, but not
requiring all arguments to have a state ending *at* that position.

Named captures are restricted to the top level of the array specification, so
are not found within the arguments of `ALL`, however named captures may come
from substructures matched against the elements of the current array.
For each argument's successor positions, if there are multiple potential
elements where a substructure could match, they are immediately resolved per
the [earliest-substructure-match](#earliest-substructure-match) rule so that
this argument successor position has exactly one possibility for its captures.
When merging the captures for an output successor position, the captures of
each argument come from that argument's successor having a position nearest to
the output position.  Uniqueness of capture names is enforced at this point,
generating `INVALID_OPERAND` if there are duplicates.  (Since capture names are
dynamically evaluated, they could vary per successor position.  Implementations
are not required to enumerate all possibilities looking for conflicting names;
just ensure that the successor state used does not have name conflicts.)

For a much-needed example, if you combine an expression matching 1, 3, or 7
elements of the current array with an expression matching 2 or 4 elements, the
first position containing enough elements to match both of them is position 2.
The returned successor states are then 2, 3, 4, and 7.
Suppose the first expression captures a sequence named "A" in its subtree and
the second expression captures a sequence named "B" in its subtree.  At output
successor state 2, capture "A" comes from the first expression's successor
state at 1 and capture "B" comes from the second expression's successor state
at 2.  At output successor state 3 capture "A" comes from the first
expression's successor state 3 and capture "B" comes from the second
expression's successor state 2.

#### <span id="ex-exists">EXISTS</span>

    [EXISTS]

Match when the current node exists, including the value `null`.

This is also particularly useful when negated as `[NONE,[EXISTS]]`.  As this
implies, the matching system must consider property expressions even when the
property doesn't exist on the target.

#### <span id="ex-array">ARRAY</span>

    [ARRAY]
    [ARRAY, length]
    [ARRAY, offset, match_spec1...]

With no arguments, this matches when the current node is an array.

The `length` / `offset` argument is interpreted in value-context and must
resolve to an integer, or the expression fails with `INVALID_OPERAND`.

With one argument, it asserts the current node is an array with at least this
number of elements in the context of `HAS`, or exactly this number of elements
in the context of an `IS` expression.

With more than one argument, this asserts the current node is an array and
that a subset of its elements match, even in `IS` context.
It is equivalent to an escaped array with initial `[EXISTS]` repeated `offset`
times, and in `IS` context a following `[EXISTS]` repeated until the end of
the array:

    [ARRAY, 3, true]
    // in HAS context is equivalent to
    [[ [SEQ, [REP,3,3]], true ]]
    // in IS context is equivalent to
    [[ [SEQ, [REP,3,3]], true, [SEQ, [REP]] ]]

The `offset` may be negative to count backward from the end of the array.
An `offset` out of bounds is not an error and simply tests false.

    // Assert that the array ends with 'x', 'y', 'z'
    [ARRAY, -3, 'x', 'y', 'z']

The `ARRAY` expression does not initiate sequence context for its arguments,
though `SEQ`-family subexpressions may be used to do so.  It also does
not participate in an existing sequence context because it descends further
into the tree where a sequence context has not yet been initialized.
It matches only a single array, so the successor state is the position
following the current element.

#### <span id="ex-str">STR</span>

    [STR]
    [STR, regex_expr]

With no arguments, this matches when the current node is a string.

With one argument (specified in [regex context](#regex-context) ) it asserts
that the node is a string and matches a regular expression.  The regex is not
implicitly anchored and will iterate through the characters of the string
looking for the "leftmost" match.  (engines may be optimized to perform
different search strategies so long as they derive the same leftmost match)
This expression is the primary way of invoking regular
expression matching on a string.  Captures within this regex *do* become
available in the capture results of the match expression containing this `STR`
expression, but subject to the normal capture-suppression rules when `ANY`,
`REP`, or `NONE` are involved.  If you want to locate named capture bounds
in a string during evaluation of a larger expression, wrap this expression with
the [`CAPTURE` function](#ex-capture).

#### <span id="ex-num">NUM</span>

    [NUM]
    [NUM, min]
    [NUM, min, max]

With no arguments, this matches when the current node is any JSON number,
or additionally NaN and Inf if those extensions are relevant.

With one or two arguments (which may be value-context expressions), also verify
that `min <= node <= max`.  `min` or `max` may be `null` (or absent) to omit
the respective test.  In implementations where infinity or NaN are available,
neither may be used as the range boundary.  If both are present, `min` must be
less than or equal to `max`.  Invalid types or values for these arguments count
as `INVALID_OPERAND`.

#### <span id="ex-bool">BOOL</span>

    [BOOL]

Match when the current node is a boolean.

#### <span id="ex-date">DATE</span>

    [DATE]

Match when the current node is a valid input for the
[`CASTDATE` expression](#ex-castdate).  See the details of that expression
and also the [dates section](#dates) for details.

#### <span id="ex-with">WITH</span>

    [WITH, temp_prop, value_expr, match_expr]
    [WITH, temp_prop0, val0, temp_prop1, val1, ..., match_expr]

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

#### <span id="ex-seq">SEQ</span>, <span id="ex-seqmax">SEQMAX</span>, <span id="ex-seqmin">SEQMIN</span>

    [SEQ, match_expr...]
    [SEQMAX, capture_name, match_expr...]
    [SEQMIN, capture_name, match_expr...]

Match a series of array elements against a series of match expressions,
optionally expressing a preferred length strategy, and optionally capturing the
range matched under the specified name.

To understand this expression, first read the
[Sequence Matching](#sequence-matching) section.

`match_expr...` is any list of match expressions, and may be an empty list.
Using an empty sequence allows you to specify things like
`[ANY, "foo", "bar", [SEQ]]` allowing the `ANY` expression to match zero
elements, though the same could be achieved by wrapping the `ANY` with
`[REP,0,1,...]`.

The `SEQMAX` and `SEQMIN` expressions have an extra `capture_name` argument
(specified in value context) that lets you name the sequence.  If not `null`
(for an unnamed sequence with length preference) the name must be a string,
but for encoding efficiency may be coerced from an integer.
Beware that the name must be unique across any expression participating in the
same match algorithm state, including arrays at different structural positions.
However, also note that captures and length preferences are *ignored* when the
current array occurs within `ANY`, `NONE`, or `REP` expressions at a parent
structural level.  Within the same match state, a `SEQMIN` or `SEQMAX`
occurring beneath these expressions behaves as an ordinary `SEQ`.

The `capture_name` is defined as an expression to deal with cases where a
common subexpression (called with `EXPR`) wants to perform a capture, but
might need to be applied multiple times to the same tree.  Using the `WITH`
expression to set a prefix in the TEMP namespace, the common subexpression can
then generate different capture names at each call site.  The `capture_name`
expression may not make use of the current node; the current node is treated
as nonexistent while evaluating `capture_name`.  The evaluation of
`capture_name` happens at the beginning of the sequence matching algorithm for
a specific array, but they are not evaluated at all if the captures for that
array are not observable (i.e. boolean sequence context).

The "min" vs. "max" designation indicates a preference for which match should
be chosen if multiple match states are valid at the end of matching the array.
They do *not* mean that the capture group will always maximize or minimize the
elements matched during the algorithm, only that if multiple outcomes for
matching an array are possible, the selection of the match should prefer longer
matches or shorter matches for those sequences, giving precedence to the
sequences in the order they occur.  If the captures of the match are unobservable,
the implementation may skip resolving the preferred match.

Examples:

For a subject of [1,2,3,4,5] in 'HAS' context:

    [[ [SEQMIN, 1, [REP,0,-1,[NUM,0,3]] ],   // 0 or more [0..3]
       [SEQMIN, 2, [REP,0,-1,[NUM,0,5]] ]    // 0 or more [0..5]
    ]]

The captures are zero elements for each, because the initial position is a
valid final position, and the preference for both matching the fewest elements
selects this as the best match.

For the same subject in 'IS' context, the expression is implicitly:

    [[ [SEQMIN, 1, [REP,0,-1,[NUM,0,3]] ],   // 0 or more [0..3]
       [SEQMIN, 2, [REP,0,-1,[NUM,0,5]] ],   // 0 or more [0..5]
       [END]
    ]]

This results in an empty capture 1 and all elements in capture 2, because out
of the final states which can reach the end of the array, sequence 1
gets priority on a minimal length.  When you change both to `SEQMAX`,

    [[ [SEQMAX, 1, [REP,0,-1,[NUM,0,3]] ],   // 0 or more [0..3]
       [SEQMAX, 2, [REP,0,-1,[NUM,0,5]] ],   // 0 or more [0..5]
       [END]
    ]]

the final state with the most elements for sequence 1 is a split of
`[1,2,3]` / `[4,5]`.

#### <span id="ex-rep">REP</span>

    [REP]                         // consume any number of elements
    [REP, min]                    // consume at least min elements
    [REP, min, max]               // consume between min and max elements
    [REP, min, max, match_expr]   // match between min and max elements

Match repetitions of an expression against a series of array elements.

`min` and `max` are [value context](#value-context) expressions which must
evaluate to integers.  The value of `min` must be non-negative.  The value of
`max` may be -1 as an alias for infinity, or 0 as an alias for "same as min".
Otherwise, `max` must have a value greater than or equal to `min`.
`match_expr` is a [match context](#match-context) expression.
When the `match_expr` argument is omitted, it defaults to `[EXISTS]` which
basically just consumes elements.  When the `max` argument is omitted, it
defaults to -1.  When the `min` argument is omitted, it defaults to 0.

This expression is illegal outside of [sequence context](#matching).
It produces all the successor cursor positions that can satisfy a count of
matches of the expression between `min` and `max`.  (Of course, implementations
need to limit the successor states to the length of the array and handle
expressions which consume zero elements when `max` is infinite.)

Regex Notation               | REP notation
-----------------------------|--------------------
 `.*` (where . includes \n)  | [REP]
 `.+`                        | [REP,1]
 `.?`                        | [REP,0,1]
 `(...)*`                    | [REP,0,-1,...]
 `(...)+`                    | [REP,1,-1,...]
 `(...)?`                    | [REP,0,1,...]
 `(...){5}`                  | [REP,5,0,...]
 `(...){3,5}`                | [REP,3,5,...]

#### <span id="ex-start">START</span>

    [START]

Match when the current node refers to the first element of an array.

This also returns true when testing the nonexistent beyond-the-end element on
an empty array.
In [sequence context](#sequence-matching), this is a zero-width assertion
based on the array cursor.

#### <span id="ex-end">END</span>

    [END]

Match when the current node is the undefined element beyond the final element
of its containing array.

In [sequence context](#sequence-matching), this is a zero-width assertion
based on the array cursor.

#### <span id="ex-chars">CHARS</span>

    [CHARS, ...
      true,                // include following elements
      false,               // exclude following elements
      "abcdef",            // 6 literal characters
      "a","z",             // a range of characters to be added
      "a",null,            // open-ended range
      "a","",              // not a range, just the character 'a'
      48,57,               // Unicode codepoint range
      [EXPR,name]          // reference a common CHARS expression

Match when the current node is a character in the defined set.

Outside of regex context, this means both integers representing Unicode
codepoints and one-character strings. ("one character" according to the
implementation's construction of codepoint arrays from a JSON string)

Boolean values switch between inclusion and exclusion.  The default is
inclusion to an empty set.  If the first element is false, it instead becomes
exclusion from the complete set of Unicode.  Further boolean values affect
the elements that follow but do not themselves modify the set.

A string of more than one character is considered a list of characters to
include.  The list may be empty.  A single character begins an inclusive range
of characters if the following element is also one character.  Ranges must be
specified in ascending codepoint order.  `null` may be used as an alias for
the maximum Unicode character.  An integer is treated as a Unicode codepoint
value (and must fall within the valid Unicode range).  Since integers and
`null` represent single characters, they also begin or end ranges when
possible.

Finally, you may use an [`EXPR expression`](#ex-expr) to reference a `CHARS`
expression from the common expression namespace.  It must resolve to exactly
a `CHARS` expression; anything else results in `INVALID_OPERAND`.  Other
expressions and data types also count as `INVALID_OPERAND`.

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
    [CHARS, [EXPR,"regex_Print"], false, [EXPR,"regex_Punct"]]

### Function Expressions

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

    [LOCAL, prop, value_expr, ..., return_value_expr]

Set up a lexical overlay on the TEMP namespace or override the current node,
then evaluate `return_value_expr` and return that value.

This is very similar to the [`WITH` expression](#ex-with), but as a function
rather than a match expression.  Each `prop` argument is either a string
(or number which gets coerced to string) naming a TEMP namespace root property,
or the special value `null` to request a lexical override of the current node.
Other types count as `INVALID_OPERAND`.
Changes made by each `prop` / `val` pair are visible to the evaluation of
subsequent pairs.  After evaluating `return_value_expr`, the TEMP namespace and
current node revert to their previous state.

The `prop` argument is restricted to the root of the TEMP namespace or the
current node pointer.  Combined with the restriction that the path of `[TEMP]`
itself is not a valid reference, it ensures that the changes cannot be seen in
any other namespace or path within the TEMP namespace.  The TEMP namespace may
hold references to other trees temporarily, but nothing can hold a reference to
the root of the TEMP namespace.
Likewise, rebinding the current node does not modify, replace, or otherwise
write through any reference in the target tree or another namespace.

#### <span id="ex-and">AND</span>

    [AND, value_expr...]

Logical AND of one or more value expressions.

Each evaluated expression must evaluate to a boolean, or the expression fails
with `INVALID_TARGET`.

Each argument is evaluated in sequence, stopping after the first false value
or error raised.  This means later arguments may contain expressions that
trigger errors so long as a previous argument evaluating false guards against
reaching the later argument.

#### <span id="ex-or">OR</span>

    [OR, value_expr...]

Logical OR of one or more value expressions.

Like `AND`, each argument is evaluated in sequence, and must evaluate to a
boolean, or the expression fails with `INVALID_TARGET`.  Evaluation stops after
the first true value or error raised.

#### <span id="ex-not">NOT</span>

    [NOT, value_expr...]

Logical NOT ("NOR", really) of one or more value expressions.

Like `AND`, each argument is evaluated in sequence, and must evaluate to a
boolean.  Evaluation stops after the first true value or error raised.

#### <span id="ex-length">LENGTH</span>

    [LENGTH]               // operate on the current node
    [LENGTH, value_expr]

Return the length of an array or string.

If `value_expr` (value context) is not specified, the value of the current node
is used.  The value must be an array or string or it fails with
`INVALID_TARGET`.  The length of a string is determined by the same rules that
break a string into an array of characters, which may differ from the host
language's concept of "length".

#### <span id="ex-curprop">CURPROP</span>

    [CURPROP]

If the current node is a property of an object, return the property name, else
if it is an element of an array, return the element number, else return `null`.

This is useful when iterating over an array in a match expression or
MAP / REDUCE / FILTER expression to know which array index is being processed.
It can be used to help generate capture names or look up parallel paths from
another array or object.

#### <span id="ex-slice">SLICE</span>

    [SLICE, value_expr, ofs]
    [SLICE, value_expr, ofs, len]
    [SLICE, config_obj]
    // Where config_obj must evaluate to an object of the form:
    // { ofs: N, len: N, lim: N, path: P }
    // like the objects of the capture namespace

Return a span of an array or string.

All parameters are [value context](#value-context) expressions.
If `value_expr` is not specified, the value of the current node is used.
The value must be an array or string or it fails with `INVALID_TARGET`.
The `ofs` argument must evaluate to an integer, and may be negative to count
backwards from the `LENGTH` of the target value.  The `len` argument must
also evaluate to an integer, and may also be negative to count backward from
the `LENGTH` of the value in which case it represents a limiting offset.
If `ofs` or `len` are not integers, the expression fails with `INVALID_OPERAND`.

In the third form, a `config_obj` (object value, after any expression
evaluation) may be used to pass values for the starting offset, count of
elements, limiting offset, and an optional `path` under the current node.
The `path` is an array value, becoming the implied expression `[NODE, path]`.
Lacking `path`, the `SLICE` applies to the current node itself.
The positional properties of the object may not be negative, and if all three
are given, they must agree such that `ofs + len == lim` or it results in
`INVALID_OPERAND`.  When one property is absent, it is derived from the other
two using that equality.  When two are absent, `ofs` defaults to 0, or `lim`
defaults to `LENGTH` to provide a second parameter.

After normalizing negative arguments, the parameters must obey the relation
`0 <= offset <= limit <= LENGTH(value)` or the expression fails with
`INVALID_TARGET`.

When [`SPLIT` metadata](#split-metadata) is present on the input array, the
portion describing the sliced elements is copied to the output array.

Examples:

    // For NODE of [0,1,2,3,4,5,6]
    [SLICE, [NODE], 3]              -> [3,4,5,6]
    [SLICE, [NODE], -1]             -> [6]
    [SLICE, [NODE], 3, 1]           -> [3]
    [SLICE, [NODE], 3, -1]          -> [3,4,5]
    [SLICE, {ofs: 3}]               -> [3,4,5,6]
    [SLICE, {len: 2}]               -> [0,1]
    [SLICE, {lim: 4}]               -> [0,1,2,3]
    [SLICE, {ofs: 3, lim: 6}]       -> [3,4,5]
    [SLICE, {ofs: 1, len: 1}]       -> [1]
    [SLICE, {len: 2, lim: 5}]       -> [3,4]

#### <span id="ex-concat">CONCAT</span>

    [CONCAT, value_expr1, ...]

Concatenate one or more arrays or strings into a larger array or string.

All arguments must evaluate to the same type, or this generates
`INVALID_TARGET`.  If they are all strings, they get joined into a string.
If they are all arrays, a new array of the combined lists of elements is
returned.

When [`SPLIT` metadata](#split-metadata) is present on an input array, it gets
copied to the output array unless an earlier input array already copied `SPLIT`
metadata with a different `origin`.  This causes all other elements to receive
"adjacent element metadata" unless they have some from a matching `origin`.

#### <span id="ex-reduce">REDUCE</span>

    [REDUCE, reduce_expr, temp_prop, initial_value]
    [REDUCE, reduce_expr, temp_prop, initial_value, array_expr]

Combine the elements of an array into a result value.

`reduce_expr` is specified in value context, but is not evaluated immediately.
`temp_prop` is a single property name string of the TEMP namespace, but may
also be a number that gets coerced to a string; any other type counts as
`INVALID_OPERAND`.
The `initial_value` and `array_expr` arguments are specified in value context.
If `array_expr` is provided, it must evaluate to an array, otherwise the
current node is used as input and must be an array.  Non-arrays result in
`INVALID_TARGET`.  `initial_value` may evaluate to any type.

The `initial_value` is evaluated prior to any iteration, and becomes the
accumulator value.  For each element of the input array (which may be empty),
the current node is set to alias the array element, and the `TEMP` namespace
property `temp_prop` is set to alias the accumulator, and then `reduce_expr`
is evaluated.  The changes to the current node and TEMP namespace are *only*
visible to the evaluation of `reduce_expr`.
The return value of `reduce_expr` is kept as the new accumulator value.
After all array elements have been processed, the accumulator value is
returned as the result of the `REDUCE` expression.

`REDUCE` can actually be implemented using lisp-style recursive iteration, but
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
With one argument, the current node must be an array.  Otherwise, the
`array_expr` specified in value context must evaluate to an array.
Non-arrays result in `INVALID_TARGET`.
Each element of the array is localized as the current node while evaluating
`match_expr`.  The elements which match become part of the returned array, in
the same order they appeared in the original array.

If the source array contains [`SPLIT` metadata](#split-metadata), the metadata
for the selected elements gets copied to the new array.

#### <span id="ex-map">MAP</span>

    [MAP, transform_expr]
    [MAP, transform_expr, array_expr]

Transform each element of an array to produce a new array.

The `transform_expr` is specified in value context; however, it is not evaluated
immediately.  In the one-argument form, the input comes from the current node,
which must be an array.  Otherwise the `array_expr` (also value context) is
evaluated and likewise must return an array to be used as the input.
Non-arrays result in `INVALID_TARGET`.
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
from evaluating `string_expr` (value context).  The input must be a string, or
`SPLIT` fails with `INVALID_TARGET`.  The validity of the input should be
checked after the validity of `split_spec`.

The `split_spec` argument may be a simple string used as a verbatim separator,
a match expression to be evaluated in
[regex longest-match context](#regex-context), a reference expression resolving
to one of those two, or a literal object with a more elaborate specification:

    {"sep": ...,        // A string or regex to split on
     "element": ...,    // A regex that must match prior to testing for 'sep'
     "default": ...,    // The default separator used for joining new elements
     "keep": ...,       // Preserve the separator within the generated array
     "ltrim": ...,      // A string or regex to trim from start of elements
     "rtrim": ...,      // A string or regex to trim from end of elements
     "trim": ...,       // sets 'ltrim' and 'rtrim' to the same value
     "discard": bool,   // Don't preserve trimmed chars when re-assembling
    }

The `split_spec` object must be literal, not value context, since it needs to
be able to contain expressions without evaluating them.  Unknown properties
and illegal literal property values count as `INVALID_OPERAND`.
If the `sep` parameter is an [expression reference](#ex-expr), it is first
resolved to something that isn't an expression reference.  Then, if the root is
a match expression it is treated as a regular expression to be applied
repeatedly when searching for separators, but otherwise it is evaluated
immediately and must return a string.  `default` is not used by `SPLIT`, but
defined here since the specification is shared with `JOIN`.

The split operation iterates through the characters of the string looking for
[the longest match](#regex-context) of the separator pattern.  If you specify
an `element` regex, a test for a separator will only match when the element
characters (from the end of the previous separator until the current match
position) also match the `element` pattern.   The `element` pattern is
implicitly anchored to the start and end of the element characters.
This gives you a way to pass over escape sequences without accidentally
detecting a separator, and without requiring the complexity of "look-behind"
or "look-ahead" or capture groups in the separator pattern.

A zero-length separator (including a successful zero-length regex match)
is considered to match at every boundary between characters except the current
position (meaning the boundary between the end of the previous separator and
the following character) which prevents an infinite loop of empty
elements.  This means the separator of `''` can be used to split the string
into its individual characters.  It also means that a regular expression which
can match the empty string will generate a single-character element any time
none of the alternatives matched.

For example, the pattern `/a*/` applied to the string "baabca" results in:

    ['b', 'b',  'c', '']

(Note that splitting a string into an array of individual characters is a
quick way to reach a `RESOURCE_LIMIT` error)

Once a separator is found, it uses the value of `keep` to determine what to do
with it.  The default is to hide the separator from the resulting array but
store it (attached invisibly to the preceding element) until it is time to
reconstruct the string.
The value "<" means to keep the separator as part of the current element in
the generated array, and likewise ">" means to keep it as part of the
following element.  The value '@' means to include the separator as its own
element of the resulting array.  In all three cases, separator metadata is not
used, and elements get reassembled with an empty string as the separator since
the actual separator is part of the data.

`ltrim` and `rtrim` are used to hide unimportant characters from the resulting
array element strings, such as leading/trailing whitespace (like `diff -b`)
and you can (mutually exclusive with the others) specify `trim` to set them
both to the same value.
`ltrim` is implicitly anchored to the start of the element string, and `rtrim`
is implicitly anchored to the end, allowing a common value for `trim`.
The longest match of `ltrim` gets removed first, followed by removing
the longest match of `rtrim` from the remainder, to resolve cases where the
trimming could overlap.
If you want to permanently remove the trimmed characters, use `discard: true`.

If the separators are not added to the array using `keep` and are not a
constant string, they are stored in a parallel array of metadata associated
with the array, referred to as [`SPLIT` metadata](#split-metadata).  Likewise,
trimmed characters are stored there if not being discarded.  As modifications
are applied to the array to rearrange its elements, this metadata is modified
in parallel as described below.

##### Split Metadata

"SPLIT metadata" carries the hidden separators and end-trimmings from `SPLIT`.
It is associated *with the array* as a parallel array of per-element data, rather
than being bound to the values themselves.  The separator is paired to the
element it *followed* and the final element will not logically have one since
a string ending with a separator receives a final element of the empty string,
though for the purposes of this algorithm it receives a copy of the separator
of the preceding element.
Only one instance of `SPLIT` metadata may be associated with any one array.
It also contains an `origin` tag; in any case where values are transferred
between element references, the `SPLIT` metadata will only carry over when both
arrays have metadata of the same `origin`.

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
The input must be an array and all its elements must be strings, or `JOIN`
fails with `INVALID_TARGET`.  This is tested after validating `split_spec`.
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
    [PROPS, object_expr, options]

Return the properties of an object in various forms.

Lacking `object_expr`, this operates on the current node.  Otherwise,
`object_expr` is specified in value-context and must resolve to an object.
Non-objects result in `INVALID_TARGET`.
`options` is a literal value that must currently be numeric `1` or `2`.
Future versions may define an object form for `options`.
Without options, the property names (and only the names) of an object are
returned as one array.  When `options === 1`, the return value is an array
where each element is an array of `[propertyname, value]`.  When
`options === 2`, the return value is an array of two arrays where the first
array holds property names and the second array holds the corresponding
property values.  In all cases, the properties must be sorted (by Unicode
codepoint sequence) to ensure deterministic behavior across implementations
when iterating over properties.

#### <span id="ex-mkobj">MKOBJ</span>

    [MKOBJ, name_expr, val_expr, ...]            // string, string, ...
    [MKOBJ, name_array_expr, value_array_expr ]  // [name,...], [val,...]
    [MKOBJ, prop_array_expr ]                    // [ [name,val], ... ]

Construct an object from properties.

All arguments are specified in value context.
In the first form, pairs of `name_expr` and `val_expr` each become a
property of the created object.  At least one pair must be given in this form.
In the second form, recognized by two array arguments, the names are provided
in one array and the values are provided in a second array.  The arrays must be
the same length, but also may be empty.
In the third form, recognized by one array argument, the array holds one
element for each property which is a two-element array of `[name,val]`.
This array may also be empty to construct an empty object.

In all cases, the names must evaluate to strings, and it is an error for any
two names to be identical strings.  All errors described above count as
`INVALID_TARGET`.

#### <span id="ex-case">CASE</span>

    [CASE, match_expr, value_expr, ..., else_value_expr]
    [CASE, match_expr, value_expr, ...]   // or implied FAIL

Evaluate one value expression selected by a series of conditional tests.

For pairs of `match_expr` (match context) and `value_expr` (value context),
return the evaluated `value_expr` of the first successful `match_expr`, else
evaluate and return the `else_value_expr` (value context).
At least one pair must be specified.
If no "else" is provided and none of the matches succeed, the implied else
value is the `FAIL` expression, which fails with error `INVALID_TARGET`.
Conditions are tested in argument order, and only the selected value-context
expression gets evaluated.

Because [match context](#argument-contexts) lets a plain value describe a `HAS`
match against the current node, this can be an efficient way to choose an
expression based on its value.  If the value you want to compare is not the
current node, you can temporarily set it up as the current node with
 [`LOCAL`](#ex-local).

#### <span id="ex-fail">FAIL</span>

    [FAIL]

Generate an `INVALID_TARGET` error.  This is useful for rejecting unexpected
scenarios in expressions.  Note that this does not immediately end the graft
operation if used in match context.

#### <span id="ex-castbool">CASTBOOL</span>

    [CASTBOOL]                  // cast current node
    [CASTBOOL, value_expr]

Cast a value to boolean.

Boolean values always pass through.  Only integers 1 and 0 and strings "true"
and "false" may be cast to booleans, and every other value generates
`INVALID_TARGET`.

If you want something closer to the "everything is true unless it is false-ish"
seen in many programming languages, consider adding your preferred list of
false values to a `NONE` expression, optionally wrapped with an `EXISTS` test:

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
numification, as decided by the implementation.
Numbers outside the range supported by an implementation generate
`UNSUPPORTED_GRAFT` errors.  Every other value generates `INVALID_TARGET`.

#### <span id="ex-caststr">CASTSTR</span>

    [CASTSTR]                   // cast current node
    [CASTSTR, value_expr]

Cast a value to a string.

String values always pass through.  Booleans stringify to "true" and "false".
Numbers with no fractional part stringify to decimal digits with a possible
leading minus sign.  Other numbers stringify to the same string that the host
JSON encoder would produce, which is not consistent across all implementations,
and the exact character representation should not be relied on.
Dates stringify in ISO8601 format.  Datetimes stringify as
"yyyy-mm-dd hh:nn:ss" with the possibility of more digits in the year and
sub-second precision.  Timestamps stringify as "yyyy-mm-ddThh:nn:ssZ" (for a
zero timezone offset) or "yyyy-mm-ddThh:nn:ss±zzzz", and with the same
longer-year/subsecond possibility.
Extensions to the data model permitted by the implementation (including numbers
Inf and NaN) may stringify according to the implementation or configuration
from the application.

Every other value (objects, arrays, `null` and the nonexistent property that
can be encountered when matching objects/arrays) generates `INVALID_TARGET`.

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
1583 and onward (the cutoff defined in ISO 8601) and invalid days rejected with
`INVALID_TARGET`.  Hours and minutes should be validated against the standard
range, but seconds should permit a leap second (60 and fractions above that)
without historic validation.

If host language date objects are permitted in the data, they should also be
supported by this expression, though depending on the capabilities or
mutability of those date objects an implementation may still need to convert
them to a different internal representation.

If an implementation cannot confidently infer a date-like meaning for a value,
it should generate `INVALID_TARGET`.

#### <span id="ex-less">LESS</span>

    [LESS, expr_b]              // current node less than b
    [LESS, expr_a, expr_b]

Perform a less-than comparison.

Both arguments must evaluate to the same type, or this generates
`INVALID_TARGET`.

On booleans, `false` compares less than `true`.

On numbers, this performs a numeric comparison according to the host language;
however, comparisons using host extensions of NaN should generate
`INVALID_TARGET`.

On strings, this performs a character-by-character comparison on the codepoint
values, using the same string-to-characters algorithm as configured for regular
expressions.

On arrays, this performs an element-by-element `LESS` test in the order of the
elements, stopping at the first pair which are not equal and returning the
result.  If it encounters types without a defined comparison, it aborts with
`INVALID_TARGET`, but such invalid elements are not encountered if a valid
difference is found at an earlier element.  If it makes it to the end of one
array before the other, that array is considered the lesser of the two.

On dates and datetimes, the fields are compared most-significant to
least-significant as if they were an array of those values.  On timestamps, the
timezone offset is applied first before comparing logical instants.  Note that
timezone offsets have a minute resolution, so applying the offset and comparing
fields can be done independently of whether leap seconds exist.

All other types (e.g. objects) generate `INVALID_TARGET`.  If it does not
fail, the result is always a boolean.

#### <span id="ex-lesseq">LESSEQ</span>

    [LESSEQ, expr_b]            // current node less or equal to b
    [LESSEQ, expr_a, expr_b]

Perform a less-than-or-equal comparison.

This is the same as `LESS` but also returns true if the values are equal.

#### <span id="ex-add">ADD</span>

    [ADD, value_expr1...]
    [ADD, array_expr]

Add zero or more numbers.

Arguments are described in value context.  All `value_expr` arguments must
evaluate to numbers, unless provided as a single argument that evaluates to an
array of numbers.  The list may be empty, resulting in the value `0`.
Any other type of argument fails with `INVALID_TARGET`.
The result is the host language's addition of those numbers combined in element
order, within the rules described in the [math section](#math).

#### <span id="ex-sub">SUB</span>

    [SUB, value_expr1, value_expr2]

Subtract numbers.

Arguments are described in value context.  There must be exactly 2 arguments
and they must evaluate to numbers.  Any other type results in `INVALID_TARGET`.
The result is the host language's subtraction of those numbers, within the rules
described in the [math section](#math).

#### <span id="ex-mul">MUL</span>

    [MUL, value_expr1...]
    [MUL, array_expr]

Multiply zero or more numbers.

Arguments are described in value context.  All `value_expr` arguments must
evaluate to numbers, unless provided as a single argument that evaluates to an
array of numbers.  The list may be empty, resulting in the value `1`.
Any other type of argument fails with `INVALID_TARGET`.
The result is the host language's multiplication of those numbers combined in
element order, within the rules described in the [math section](#math).

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
if `value_expr2` was negative.  Division by zero, or a result of `Inf` or `NaN`
when not configured to allow them must fail with `INVALID_TARGET`.

Note that this is not the same as the C language `%` operator, which returns
a remainder.

#### <span id="ex-pow">POW</span>

    [POW, base]
    [POW, base, exponent]

Return the value of `base` to the power of `exponent`.  If `exponent` is
omitted the current node is used.

The `base` (value context) must be a nonnegative number.  The `exponent`
(value context) can be any number but must be nonnegative if `base` is zero.
Invalid values for either argument count as `INVALID_TARGET`.

For valid arguments, when `exponent` is zero, the result is always one.
If `base` and `exponent` are both integers, implementations must check to see
if the result can be represented exactly in an available number storage type,
and if so, use an exact power caluclation instead of floating point math.

Overflow and underflow count as `UNSUPPORTED_GRAFT`.  A nonzero mathematical
result must not be returned as zero due to floating-point underflow.

If an implementation permits NaN and Inf values, it must specify how they
behave for inputs and outputs of this function.

#### <span id="ex-log">LOG</span>

    [LOG, base]
    [LOG, base, value]

Return the `base` logarithm of `value`.  If `value` is omitted the current
node is used.

The `base` and `value` (both value context) must be positive numbers, and
`base` may not be exactly one.  Invalid values for either argument count as
`INVALID_TARGET`.

For valid arguments, when `value` is one the result is zero, and if `value` is
equal to `base` the result is one.

Overflow and underflow count as `UNSUPPORTED_GRAFT`.  A nonzero mathematical
result must not be returned as zero due to floating-point underflow.

If an implementation permits NaN and Inf values, it must specify how they
behave for inputs and outputs of this function.

#### <span id="ex-round">ROUND</span>

    [ROUND]
    [ROUND, options]
    [ROUND, options, value_expr]

Round to a decimal position, defined for both numbers and strings.

This operates on the current node unless a second argument (value context) is
provided.  The input must be a number or string, with other types triggering
`INVALID_TARGET`.  The options (value context) may be an integer providing the
`shift` parameter, or an object with any of the following properties: `mode`,
`at`, `shift`, `as`.  Invalid options are classified as `INVALID_OPERAND`.

This expression is defined in terms of decimal digits, allowing it to operate
on strings as well as numbers.  String inputs must pass validation according to
CASTNUM.  Numeric inputs are first converted to decimal representations
according to CASTSTR, and rounding is defined in terms of those decimal digits.
(implementations are free to use any algorithm that produces equivalent
results)    In many cases, floating point error cannot be avoided, and graft
authors should attempt to process numbers in an integer or string form to work
around the problem.

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
does pre-multiply the number by `10**shift`.  The overall effect can described
as

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
When returned as `"NUM"`, casting to a number is permitted to lose precsion.
When returned as `"INT"` the implementation must store the value in a container
without loss of precision, failing with `INVALID_TARGET` if the number is not
an integer and `UNSUPPORTED_GRAFT` if the integer is too large to store without
loss.

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
still be represented.  Scientific notation outputs should have exactly one
digit before a decimal point.

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

Implementations must not fail with `UNSUPPORTED_GRAFT` due to the logical size
of the number unless the output format requires a number and the final computed
value would exceed limits of the available storage type.  Implementations may
also fail with `UNSUPPORTED_GRAFT` if the addition/subtraction on the exponent
number itself would exceed the limits of an integer.

Note that the plain-integer form of the options argument is used as the `shift`
parameter to enable easy tests against floating-point numbers:

  // foo == 1.234, without relying on floating point equality
  { foo: [IS, [ROUND,6], 1234000] }

## Implementation Hints

This specification tries not to dictate too many details of an implementation,
but implementors may find these details helpful.

### Array Metadata

There are four special features that require annotating arrays with some
metadata:

  * They may carry [`SPLIT` metadata](#split-metadata) which various actions
    and expressions need to process, if present.
  * They may have [fuzzy matching](#fuzzy-matching) aliases applied.
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

