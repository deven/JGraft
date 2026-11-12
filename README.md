# JGraft

JGraft is a data structure that describes how to edit a tree of data.  It can
describe edits where portions of the source and destination are fully defined
and thus reversible, edits applicable to any compatible data structure, or
conditional edits where the change depends on the state of the target data.
The data structure is defined in basic JSON-compatible concepts, though a host
language may include other native data types within the tree if they don't
need to serialize to JSON.

Broadly speaking, it takes the principles and use cases of the popular
unified-diff format and expands them to trees of JSON-like data.
It emphasizes an algorithm of looking for matching elements before applying
edits, so patches can be applied at adjusted array offsets much like how text
patches can be applied at a different line number of a text file.
It can also patch within string nodes of a tree, and apply changes that depend
on the shape of the target, which RFC 6902 "json patch" format cannot.
This makes JGraft a good choice for an "optimistic editing" strategy vs. tools
designed for the strategy of applying a rigid patch to a specific known
revision of a data structure.

The specific design goals were:

  * Easy to generate
  * Easy to apply
  * Likely to "do the right thing" when applied
  * Easy to compose JGrafts into a larger JGraft
  * Highly portable
  * Highly expressive
  * Replicate the "fuzzy match" behavior of Unix `patch`

The result is basically a small language with Lisp-like functions, where a
small collection of tree-mutating operations are guided by a moderate
collection of pattern-matching and value-construction expressions.

## Examples

#### Diff

If you wanted to apply this diff output of `diff -U1 a b`

    @@ -10,4 +10,3 @@
     Line ten
    -Line eleven
    -Line twelve
    +New Line eleven
     Line thirteen

to a string within a JSON structure, you can describe the equivalent operation
with JGraft:

    ["ATSPLIT", ["NODE"], "\n",
      ["MATCH",
        ["ARRAY", 9, // 0-based 9 is 1-based "line 10"
          "Line ten",
          "Line eleven",
          "Line twelve",
          "Line thirteen"
        ],
        ["SPLICE", 10, 2,
          "New Line eleven"
          // no line 12
        ]
      ]
    ]

#### Record re-ordering

If you started with records like

    [
      {"id":"abcd",...},
      {"id":"efgh",...},
      {"id":"ijkl",...},
      ...
    ]

and wanted to describe moving record "abcd" to a position after "ijkl" in the
containing array regardless of other edits made to those records so long as
they were still found in their original locations, you could describe it as:

    ["MATCH",
      [[{"id":"abcd"},{"id":"efgh"},{"id":"ijkl"}]],
      ["MOVE",0,2.5]
    ]

and the result would be:

    [
      {"id":"efgh",...},
      {"id":"ijkl",...},
      {"id":"abcd",...},
      ...
    ]
