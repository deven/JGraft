#!/usr/bin/env perl

# Properties of this implementation that the conformance suite cannot see.

use v5.36;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use JSON::PP;
use Storable ();
use JGraft;
use JGraft::Compiler;
use JGraft::JSON;

my $json = JSON::PP->new->canonical->allow_nonref;
sub graft (@actions) { JGraft->new([ JGRAFT => { v => 1 }, @actions ]) }
sub show ($v)        { $json->encode($v) }

subtest 'the examples in the README' => sub {
    my $text = join "\n", map { "Line $_" } qw(one two three four five six seven eight nine ten eleven twelve thirteen);
    my $diff = graft([ ATSPLIT => ['NODE'], "\n",
        [ MATCH => [ ARRAY => 9, 'Line ten', 'Line eleven', 'Line twelve', 'Line thirteen' ],
            [ SPLICE => 10, 2, 'New Line eleven' ] ] ]);
    (my $want = $text) =~ s/Line eleven\nLine twelve/New Line eleven/;
    is $diff->apply($text), $want, 'a unified diff hunk';

    my $move = graft([ MATCH => [ [ { id => 'abcd' }, { id => 'efgh' }, { id => 'ijkl' } ] ], [ MOVE => 0, 2.5 ] ]);
    my @records = map { { id => $_, n => 1 } } qw(abcd efgh ijkl mnop);
    is show([ map { $_->{id} } @{ $move->apply(\@records) } ]), '["efgh","ijkl","abcd","mnop"]', 'reordering records';
};

subtest 'the input is never changed, nor one result by another' => sub {
    my $in  = { a => { n => 1 }, list => [ { n => 1 }, { n => 2 } ] };
    my $was = show($in);
    my $out = graft(
        [ COPY => ['NODE', 'a'], 'b', 9, ['NODE', 'a', 'n'] ],                       # copy, then change the original
        [ COPY => ['NODE', 'list'], ['STASH', 'saved'], 7, ['NODE', 'list', 0, 'n'] ],
        [ COPY => ['STASH', 'saved'], 'saved' ],
        [ COPY => ['SLICE', ['NODE', 'list'], 1], 'tail', 8, ['NODE', 'list', 1, 'n'] ],
        [ COPY => ['FILTER', {}, ['NODE', 'list']], 'kept', 6, ['NODE', 'kept', 0, 'n'] ],
        [ COPY => ['MAP', ['NODE'], ['NODE', 'list']], 'mapped', 5, ['NODE', 'mapped', 1, 'n'] ],
    )->apply($in);
    is show($in), $was, 'the input is untouched';
    is show($out->{b}),      '{"n":1}',           'a copy is independent of its source';
    is show($out->{saved}),  '[{"n":1},{"n":2}]', 'a stashed copy is independent';
    is show($out->{tail}),   '[{"n":2}]',         'a slice is independent';
    is show($out->{list}),   '[{"n":7},{"n":8}]', 'writes into a result do not reach back';
    is show($out->{kept}),   '[{"n":6},{"n":8}]', 'a filtered copy is independent';
    is show($out->{mapped}), '[{"n":7},{"n":5}]', 'a mapped copy is independent';

};

subtest 'what a graft supplies is copied for each run, unless it is shared' => sub {
    my $struct = [ JGRAFT => { v => 1 },
        [ COPY => { list => [ [ 1, { n => 2 } ] ], tag => 'x' }, 'made', [ CONCAT => [ [1] ], [ [2] ] ], 'folded' ] ];
    my $g = JGraft->new($struct);
    my ($one, $two) = map { $g->apply({}) } 1, 2;
    my $was = show($one);
    ok $one->{made} != $two->{made} && $one->{made}{list} != $two->{made}{list} && $one->{folded} != $two->{folded},
        'a literal, and a value worked out when the graft was compiled, is a new one in each output';
    ok eval { push @{ $one->{made}{list} }, 3; $one->{made}{list}[0] = 9; $one->{made}{tag} = 'y'; $one->{made}{extra} = 1; $one->{made}{list}[1]{n} = 9; push @{ $one->{folded} }, 3; 1 },
        'and is the caller\'s to change, at any depth';
    is show($two), $was, 'another output is none the worse for it';
    is show($g->apply({})), $was, 'nor is any later run';
    ok eval { push @{ $struct->[2][1]{list}[0] }, 3; 1 }, 'the structure the graft was compiled from stays the caller\'s too';
    is show($g->apply({})), $was, '... and changing it does not reach the graft';

    my $edit = graft([ COPY => { x => [ [ 1, 2 ] ] }, 'made', 9, [ 'NODE', 'made', 'x', 0 ] ]);
    is show([ map { $edit->apply({}) } 1, 2 ]), '[{"made":{"x":[9,2]}},{"made":{"x":[9,2]}}]', 'a graft can change what it made, run after run';
    is show([ map { graft([ COPY => [ MAP => { k => [ [ 1 ] ] }, ['NODE'] ], ['NODE'] ])->apply([ 1, 2 ]) } 1 ]), '[[{"k":[1]},{"k":[1]}]]', 'a literal made many times in one run';
    my $each = graft([ COPY => [ MAP => { k => [ [1] ] }, ['NODE'] ], ['NODE'] ])->apply([ 1, 2 ]);
    ok $each->[0] != $each->[1] && $each->[0]{k} != $each->[1]{k}, '... is a new one each time';

    # A constant that is declared is held by the graft, and only what is read out of it is copied.
    my %table = map { ("k$_" => { rate => $_, zone => [ [ $_ % 7, $_ % 11 ] ] }) } 1 .. 2000;
    my $look  = JGraft->new([ JGRAFT => { const => [ table => \%table, word => 'w' ] },
        [ COPY => [ CONST => 'table', [ NODE => 'key' ] ], 'entry', [ CONST => 'table', [ NODE => 'key' ], 'rate' ], 'rate' ] ]);
    my @found = map { $look->apply({ key => 'k777' }) } 1, 2;
    is show($found[0]), '{"entry":{"rate":777,"zone":[0,7]},"key":"k777","rate":777}', 'an entry is read from a table of constants';
    ok $found[0]{entry} != $found[1]{entry} && eval { $found[0]{entry}{rate} = 0; push @{ $found[0]{entry}{zone} }, 1; 1 }, 'and is a copy, the caller\'s to change';
    is show($look->apply({ key => 'k777' })->{entry}), '{"rate":777,"zone":[0,7]}', '... which does not change the table';
    is $look->run({ key => 'k777' }, limits => { mem => 500, ops => 20 })->ok, 1, 'the table itself is not copied: a run pays for the entry it takes';
    is $look->run({ key => 'k777' }, limits => { mem => 20 })->error->code, 'RESOURCE_LIMIT', '... but does pay for that';
    my $all = JGraft->new([ JGRAFT => { const => [ a => [ [ 1, 2 ] ], b => [ NODE => 'n' ] ] }, [ COPY => ['CONST'], 'all', [ CONST => 'a' ], 'a' ] ])->apply({ n => [ 3 ] });
    ok eval { push @{ $all->{all}{a} }, 9; push @{ $all->{a} }, 8; 1 } && show($all) eq '{"a":[1,2,8],"all":{"a":[1,2,9],"b":[3]},"n":[3]}', 'every constant at once, and one whole, are copies as well';
    my $inner = JGraft->new([ JGRAFT => { const => [ t => [ [ 1, 2 ] ] ] }, [ JGRAFT => { const => [ t => [ NODE => 'n' ] ] }, [ COPY => [ CONST => 't' ], 'got' ] ] ])->apply({ n => [ 5 ] });
    ok $inner->{got} == $inner->{n}, 'a constant declared again, from the data, is the data and not a copy of it';

    # A value that holds one array in many places is copied as it is, and not written out in full.
    my $many = JGraft->new([ JGRAFT => {}, [ COPY => [ REDUCE => [ [ [ 'TEMP', 'a' ], [ 'TEMP', 'a' ] ] ], 'a', 0, [ [ 1 .. 40 ] ] ], ['NODE'] ] ])->apply(0);
    ok $many->[0] == $many->[1] && $many->[0][0] == $many->[0][1], 'a constant that holds the same value in many places is copied with it still in as many';

    # Shared, as it used to be: one value for every output, which Perl protects where it can.
    my $s = JGraft->new($struct, share => 1);
    my ($first, $second) = map { $s->apply({}) } 1, 2;
    ok $first->{made} == $second->{made}, 'with share, a literal is one value however often it is produced';
    my $refused = sub ($what, $edit) { ok !eval { $edit->(); 1 } && $@ =~ /read-only/, "$what is refused" };
    $refused->('adding to its array',        sub { push @{ $first->{made}{list} }, 3 });
    $refused->('replacing an element',       sub { $first->{made}{list}[0] = 9 });
    $refused->('replacing a property',       sub { $first->{made}{tag} = 'y' });
    $refused->('a change at any depth',      sub { $first->{made}{list}[1]{n} = 9 });
    $refused->('a change to a folded value', sub { push @{ $first->{folded} }, 3 });
    is show([ map { JGraft->new([ JGRAFT => {}, [ COPY => { x => [ [ 1, 2 ] ] }, 'made', 9, [ 'NODE', 'made', 'x', 0 ] ] ], share => 1)->apply({}) } 1 ]), '[{"made":{"x":[9,2]}}]',
        'a graft that shares can still change what it made: the engine copies first';

    # And an output that shares nothing at all.
    my $in  = { keep => { deep => [ 1, 2 ] }, twice => [ 7 ] };
    my $run = graft([ COPY => [ NODE => 'twice' ], 'again', { lit => [ [ 1 ] ] }, 'new' ]);
    my $out = $run->apply($in);
    ok $out->{keep} == $in->{keep} && $out->{again} == $out->{twice}, 'an output shares with the input what the graft left alone, and one part of itself with another';
    my $own = $run->apply($in, mutable => 1);
    is show($own), show($out), 'with mutable, the output is the same';
    ok $own->{keep} != $in->{keep} && $own->{keep}{deep} != $in->{keep}{deep} && $own->{again} != $own->{twice}, '... and shares nothing';
    ok eval { push @{ $own->{keep}{deep} }, 3; push @{ $own->{again} }, 8; $own->{new}{lit}[0] = 0; 1 } && show($in) eq '{"keep":{"deep":[1,2]},"twice":[7]}' && show($own->{twice}) eq '[7]',
        '... so that changing it changes nothing else';
    is $run->run($in, mutable => 1, limits => { mem => 60 })->error->code, 'RESOURCE_LIMIT', 'the copy is part of what the run costs';
    # What a failure left is the caller's own as well.  A log is not: it is for reading, in any run.
    my $logged = graft([ RAISE => 'info', 'seen', [ NODE => 'keep' ] ], [ RAISE => 'info', 'made', { lit => [ [ 1 ] ] } ], [ COPY => { lit => [ [ 1 ] ] }, 'new' ], [ MATCH => { stop => [ NONE => 1 ] } ]);
    my @heard;
    my ($r1, $r2) = map { $logged->run($in, mutable => 1, on_raise => sub ($record) { push @heard, $record->{data} }) } 1, 2;
    ok $r1->logs != $r2->logs && $r1->logs->[0] != $r2->logs->[0], 'a log and its records are new for each run';
    ok $r1->logs->[0]{data} == $in->{keep} && $r1->logs->[0]{data} != $r1->output->{keep}, 'but what is logged from the document is the document\'s, though the output is a copy';
    ok $heard[0] == $in->{keep}, '... as on_raise is given it';
    my $plain = $logged->run($in);
    ok $plain->logs->[0]{data} == $in->{keep} && $plain->logs->[1]{data} != $logged->run($in)->logs->[1]{data}, 'as it is in any run (where what is logged from the graft is a copy)';
    my $snap = graft([ RAISE => 'info', 'before', ['NODE'] ], [ COPY => 2, 'n' ], [ RAISE => 'info', 'after', ['NODE'] ])->run({ n => 1 }, mutable => 1);
    is show([ map { $_->{data} } @{ $snap->logs } ]), '[{"n":1},{"n":2}]', 'what is logged is the value as it was then';
    my $stopped = $logged->run({ %$in, stop => 1 }, mutable => 1);
    ok !$stopped->ok && $stopped->partial->{keep} != $in->{keep} && $stopped->partial->{keep}{deep} != $in->{keep}{deep}, 'what a failure left shares nothing with the input';
    ok eval { push @{ $stopped->partial->{new}{lit} }, 2; $stopped->partial->{new}{k} = 1; push @{ $stopped->partial->{keep}{deep} }, 3; 1 }
        && show($in) eq '{"keep":{"deep":[1,2]},"twice":[7]}' && show($logged->run({ %$in, stop => 1 }, mutable => 1)->partial->{new}) eq '{"lit":[1]}', '... nor with the graft: it can be changed';
    is $logged->run({ %$in, stop => 1 }, mutable => 1, limits => { mem => 40 })->error->code, 'RESOURCE_LIMIT', 'a run that fails for want of memory';
    is show($logged->run({ %$in, stop => 1 }, mutable => 1, limits => { mem => 40 })->partial), show({ %$in, stop => 1 }), '... still hands back a copy of what it left';
    # A mutable run has no need of the copies that a run is otherwise handed, and makes none.
    my $counted = JGraft->new([ JGRAFT => {}, [ COPY => [ LENGTH => [ MAP => [ [ 1, 2, 3, 4, 5, 6, 7, 8 ] ], ['NODE'] ] ], ['NODE'] ] ]);
    is $counted->run([ 1 .. 50 ], limits => { mem => 3000 })->error->code, 'RESOURCE_LIMIT', 'fifty copies of a literal are memory';
    ok $counted->run([ 1 .. 50 ], limits => { mem => 3000 }, mutable => 1)->ok, '... which a mutable run does not spend, since all it leaves is copied anyway';
    # The undo of a mutable run is as small as any other, and is of the output as it was given.
    my $big    = { rec => [ map { { id => $_, tags => [ 1, 2 ] } } 1 .. 300 ] };
    my $change = graft([ COPY => 'x', [ 'NODE', 'rec', 5, 'id' ] ], [ SPLICE => [ 'NODE', 'rec', 100 ], 1 ]);
    my ($usual, $owned) = ($change->run($big), $change->run($big, mutable => 1));
    is show($owned->undo), show($usual->undo), 'the undo of a mutable run is the undo of any other';
    ok length(show($owned->undo)) < 200, '... which says what changed, and not the whole document';
    my $kept = Storable::dclone($owned->output);
    push @{ $owned->output->{rec} }, 'more';
    is show(JGraft->new($owned->undo)->apply($kept)), show($big), '... and undoes the output as the run gave it';

    my $doc = JGraft::JSON->parse('{"a": [1.0, 2],  "b": {"k": 1e1}}');
    my $mut = graft([ COPY => 5, [ 'NODE', 'a', 1 ] ])->apply($doc->data, mutable => 1);
    push @{ $mut->{a} }, 6;
    is $doc->write($mut), '{"a": [1.0, 5, 6],  "b": {"k": 1e1}}', 'a text is still written back as it was read, where the caller has not changed it';
};

subtest 'repeated edits happen in place' => sub {
    my $clones = 0;
    my $clone  = \&JGraft::Exec::clone;
    no warnings 'redefine';
    local *JGraft::Exec::clone = sub { $clones++; goto &$clone };
    my $out = graft(map { [ SPLICE => $_, 1, "new $_" ] } 0 .. 199)->apply([ 0 .. 999 ]);
    is $clones, 1, 'an array edited 200 times is copied once';
    is "@$out[0, 199, 200]", 'new 0 new 199 200', 'and edited correctly';
};

subtest 'compile-time decisions' => sub {
    my $c   = JGraft::Compiler->new;
    my $ctx = { scope => { exprs => {}, cells => {} } };
    ok !$c->match($ctx, { a => [ ALL => 'a', ['STR'] ] })->{throws}, 'a pattern of literals needs no error trap';
    ok $c->match($ctx, { a => [ ALL => 'a', ['NODE', 'x'] ] })->{throws}, 'a pattern that reads the data does';
    ok !$c->match($ctx, [ ANY => 'a', ['NODE', 'x'] ])->{throws},    'ANY has already trapped its alternatives';
    ok exists $c->match($ctx, { a => [ [ 1, { b => undef } ] ] })->{lit}, 'pure data collapses to one comparison';
    my $costly = [ IS => [ LENGTH => [ CONCAT => ['NODE'], ['NODE'] ] ], 2000 ];        # 2,000 operations to find out
    my $choose = graft([ COPY => [ CASE => { a => $costly, b => [ NUM => 5 ], c => 1 }, 'y', 'n' ], ['NODE'] ]);
    is $choose->run({ a => [ 1 .. 1000 ], b => 5, c => 0 }, limits => { ops => 100 })->output, 'n',
        'the members of an object pattern are tried cheapest first: a plain value';
    is $choose->run({ a => [ 1 .. 1000 ], b => 4, c => 1 }, limits => { ops => 100 })->output, 'n', 'then the patterns with least in them';
    is scalar JGraft->new([ JGRAFT => {}, [ COPY => ['NOPE'], 'a' ] ], strict => 0)->faults, 1, 'faults are collected';
    ok !eval { JGraft->new([ JGRAFT => {}, [ COPY => ['NOPE'], 'a' ] ]) }, 'and thrown at once when strict';
    is $@->code, 'INVALID_GRAFT', 'as INVALID_GRAFT';
};

subtest 'constant folding' => sub {
    my $c     = JGraft::Compiler->new;
    my %exprs = (limit => 100, sum => [ ADD => 1, 2 ], inc => [ ADD => ['NODE'], 1 ], big => [ NUM => 2 ],
                 bad => [ DIV => 1, 0 ], loop => [ EXPR => 'loop' ]);
    my $ctx    = { scope => { exprs => \%exprs, cells => {}, known => { tbl => { a => 1, b => 2 } } } };
    my $folded = sub ($s) { my $n = $c->value($ctx, $s); $n->{const} ? show($n->{value}) : 'not folded' };

    # An expression that reads nothing from the run is evaluated when compiled.
    my @constant = (
        [ 'arithmetic'                   => [ ADD => 1, 2 ],                                            '3' ],
        [ 'nested operations'            => [ CONCAT => 'n=', [ CASTSTR => [ MUL => 2, [ ADD => 1, 2 ] ] ] ], '"n=6"' ],
        [ 'dates'                        => [ LESS => [ CASTDATE => '2024-01-01' ], [ CASTDATE => '2024-06-15' ] ], 'true' ],
        [ 'a result that is an array'    => [ CONCAT => [ [1] ], [ [ { a => 2 } ] ] ],                  '[1,{"a":2}]' ],
        [ 'SLICE of a string'            => [ SLICE => 'abcdef', 1, 2 ],                                '"bc"' ],
        [ 'SLICE of an array'            => [ SLICE => [ [ 1, 2, 3 ] ], 1 ],                            '[2,3]' ],
        [ 'MKOBJ'                        => [ MKOBJ => 'a', 1, 'b', 2 ],                                '{"a":1,"b":2}' ],
        [ 'PROPS'                        => [ PROPS => { a => 1, b => 2 } ],                            '["a","b"]' ],
        [ 'ROUND'                        => [ ROUND => { at => 1 }, '2.25' ],                           '"2.3"' ],
        [ 'SPLIT'                        => [ SPLIT => ',', 'a,b' ],                                    '["a","b"]' ],
        [ 'JOIN'                         => [ JOIN => ',', [ [ 'a', 'b' ] ] ],                          '"a,b"' ],
        [ 'a match of two values'        => [ IS => [ [ 1, 2 ] ], [ ARRAY => 2 ] ],                     'true' ],
        [ 'a regex on a literal'         => [ IS => 'abc', [ STR => [ SEQ => 'b', ['END'] ] ] ],        'false' ],
        [ 'an object of constants'       => { n => [ ADD => 1, 2 ], s => [ SLICE => 'abcdef', 1, 2 ] }, '{"n":3,"s":"bc"}' ],
        # an operation supplies what the expression inside it reads
        [ 'MAP over a literal'           => [ MAP => [ ADD => ['NODE'], 1 ], [ [ 1, 2, 3 ] ] ],         '[2,3,4]' ],
        [ 'MAP, by position'             => [ MAP => [ [ ['CURPROP'], ['LENGTH'] ] ], [ [ 'ab', 'c' ] ] ], '[[0,2],[1,1]]' ],
        [ 'FILTER a literal'             => [ FILTER => [ NUM => 2 ], [ [ 1, 2, 3 ] ] ],                '[2,3]' ],
        [ 'REDUCE a literal'             => [ REDUCE => [ ADD => [ 'TEMP', 'a' ], ['NODE'] ], 'a', 0, [ [ 1, 2, 3 ] ] ], '6' ],
        [ 'LOCAL'                        => [ LOCAL => 'x', 2, 'y', [ ADD => [ 'TEMP', 'x' ], 1 ], [ MUL => [ 'TEMP', 'x' ], [ 'TEMP', 'y' ] ] ], '6' ],
        [ 'CASE, on a node from LOCAL'   => [ LOCAL => undef, 5, [ CASE => [ NUM => 0, 9 ], 'small', 'big' ] ], '"small"' ],
        [ 'one inside another'           => [ MAP => [ LOCAL => 'n', ['NODE'], [ REDUCE => [ ADD => [ 'TEMP', 'a' ], [ 'TEMP', 'n' ] ], 'a', 0, [ [ 1, 1 ] ] ] ], [ [ 1, 2 ] ] ], '[2,4]' ],
        # named constants
        [ 'EXPR, a literal'              => [ EXPR => 'limit' ],                                        '100' ],
        [ 'EXPR, a constant expression'  => [ EXPR => 'sum' ],                                          '3' ],
        [ 'EXPR that reads the node'     => [ MAP => [ EXPR => 'inc' ], [ [ 1, 2, 3 ] ] ],              '[2,3,4]' ],
        [ 'EXPR that is a match'         => [ FILTER => [ EXPR => 'big' ], [ [ 1, 2, 3 ] ] ],           '[2,3]' ],
        [ 'CONST'                        => [ ADD => [ 'CONST', 'tbl', 'b' ], 1 ],                      '3' ],
        [ 'CONST, by a computed key'     => [ MAP => [ 'CONST', 'tbl', ['NODE'] ], [ [ 'a', 'b' ] ] ],  '[1,2]' ],
    );
    is $folded->($_->[1]), $_->[2], $_->[0] for @constant;

    my @not = (
        [ 'an operand reads the document'    => [ ADD => 1, ['NODE'] ] ],
        (map { [ "the current node is implied ($_->[0])" => $_ ] } ['LENGTH'], [ POW => 2 ], [ LESS => 5 ], [ ROUND => 2 ],
            ['CASTNUM'], ['CURPROP'], [ SLICE => { ofs => 1 } ], [ CASE => [ NUM => 0, 9 ], 'small', 'big' ]),
        [ 'a value comes from the stash'     => [ MAP => [ ADD => ['NODE'], [ 'STASH', 'n' ] ], [ [ 1, 2 ] ] ] ],
        [ 'a TEMP name is supplied by nothing' => [ LOCAL => 'x', 2, [ MUL => [ 'TEMP', 'y' ], 3 ] ] ],
        [ 'a LOCAL name is computed'         => [ LOCAL => ['NODE'], 2, [ 'TEMP', 'x' ] ] ],
        [ 'a constant is not known yet'      => [ 'CONST', 'other' ] ],
        [ 'a common expression is recursive' => [ EXPR => 'loop' ] ],
        [ 'it fails'                         => [ DIV => 1, 0 ] ],
        [ 'a common expression fails'        => [ EXPR => 'bad' ] ],
        [ 'a SPLIT hides separators'         => [ SPLIT => { sep => [ ANY => ',', ';' ], default => ',' }, 'a,b;c' ] ],
    );
    is $folded->($_->[1]), 'not folded', "but not when $_->[0]" for @not;

    ok exists $c->match($ctx, { a => [ CONCAT => 'a', [ CASTSTR => [ EXPR => 'limit' ] ] ] })->{lit},
        'a folded value is a literal to a pattern';
    ok !$c->match($ctx, [ ANY => [ 'CONST', 'tbl', 'a' ], [ EXPR => 'sum' ] ])->{throws}, 'and so are named constants';

    # A match that does not depend on what it is matched against is decided when compiled.
    my $decided = sub ($s) {
        my $n = $c->match($ctx, $s);
        return 'not decided' if $n->{throws};
        my %answer = map { ($n->{code}->(undef, $_) ? 'yes' : 'no') => 1 } 5, 7, 'anything', { a => 1 };
        return keys %answer == 1 ? (keys %answer)[0] : 'not decided';
    };
    is $decided->([ IS => 5, 5 ]),                                           'yes', 'a match of two values, as a pattern';
    is $decided->([ HAS => { a => 1, b => 2 }, { a => [ ADD => 1, 1 ] } ]),   'no',  'with a computed pattern';
    is $decided->([ ANY => [ IS => 1, 2 ], [ ALL => [ IS => 'abc', ['STR'] ], [ NONE => [ IS => 1, 2 ] ] ] ]), 'yes',
        'combinations of them';
    is $decided->([ WITH => 'x', 3, [ IS => [ 'TEMP', 'x' ], [ NUM => 1, 5 ] ] ]), 'yes', 'under WITH';
    is $decided->(['NONE']),                                                 'yes', 'NONE of nothing';
    is $decided->([ IS => ['NODE'], 5 ]),          'not decided', 'but not one that looks at the document';
    is $decided->([ ANY => [ IS => 1, 2 ], 7 ]),   'not decided', 'nor a combination in which anything does';
    is $decided->([ IS => [ DIV => 1, 0 ], 1 ]),   'not decided', 'nor one that fails';
    is show(graft([ COPY => [ CAPTURE => [ ALL => [ IS => [ [ 1, 2 ] ], [ [ 1, [ SEQMAX => 'x', ['REP'] ] ] ] ] ] ], ['NODE'] ])
        ->apply(0)), '{"x":{"len":1,"lim":2,"ofs":1,"path":[]}}', 'nor one whose captures are wanted';
    ok !@{ $c->{faults} }, 'none of which is a fault';

    # What a run sees is the same either way.
    my %same = (
        'a constant redefined by a computed one, further in' => [
            [ JGRAFT => { const => [ n => 1 ] },
                [ JGRAFT => { const => [ n => [ 'NODE', 'v' ] ] }, [ COPY => [ ADD => [ 'CONST', 'n' ], 1 ], 'inner' ] ],
                [ COPY => [ ADD => [ 'CONST', 'n' ], 1 ], 'outer' ] ],
            { v => 10 }, '{"inner":11,"outer":2,"v":10}' ],
        'a constant defined from an earlier one, and then again' => [
            [ JGRAFT => { const => [ a => 2, b => [ MUL => [ 'CONST', 'a' ], 3 ], a => 10 ] },
                [ COPY => [ [ [ 'CONST', 'a' ], [ 'CONST', 'b' ] ] ], ['NODE'] ] ], 0, '[10,6]' ],
        'the whole CONST namespace' => [
            [ JGRAFT => { const => [ a => 1, b => ['NODE'] ] }, [ COPY => ['CONST'], ['NODE'] ] ], 7, '{"a":1,"b":7}' ],
        'a constant used as a pattern' => [
            [ JGRAFT => { const => [ want => { a => [ [ 1, 2 ] ] } ] },
                [ MATCH => [ IS => [ 'CONST', 'want' ] ] ], [ COPY => 'yes', ['NODE'] ] ], { a => [ 1, 2 ] }, '"yes"' ],
        'a common expression that recurses' => [
            [ JGRAFT => { expr => [ down => [ CASE => 0, [ [] ],
                    [ CONCAT => [ [ ['NODE'] ] ], [ LOCAL => undef, [ SUB => ['NODE'], 1 ], [ EXPR => 'down' ] ] ] ] ] },
                [ COPY => [ LOCAL => undef, 3, [ EXPR => 'down' ] ], ['NODE'] ] ], 0, '[3,2,1]' ],
        'a failing common expression that is never reached' => [
            [ JGRAFT => { expr => [ bad => [ DIV => 1, 0 ] ] },
                [ COPY => [ CASE => ['NUM'], 'n', [ EXPR => 'bad' ] ], ['NODE'] ] ], 3, '"n"' ],
        'TEMP supplied to the run' => [
            [ JGRAFT => {}, [ COPY => [ ADD => [ 'TEMP', 'ext' ], 1 ], ['NODE'] ] ], 0, '42' ],
    );
    for my $name (sort keys %same) {
        my ($struct, $in, $want) = @{ $same{$name} };
        is show(JGraft->new($struct)->apply($in, temp => { ext => 41 })), $want, "a run is unaffected: $name";
    }

    my $r = graft([ COPY => [ DIV => 1, 0 ], 'a' ])->run({});
    is $r->error->code, 'INVALID_TARGET', 'a failure is raised by the run that reaches it';
    is show(graft([ COPY => [ ANY => [ DIV => 1, 0 ], [ IS => [ DIV => 4, 2 ], 2 ] ], ['NODE'] ])->apply(0)), 'true',
        'and is still only a failed probe inside a match';

    # Folding is work done by `new`, so the limits given to `new` govern it.
    my $long    = [ ROUND => { as => 'STR', at => 1e6 }, '1' ];     # a million digits
    my $six     = [ ADD => [ [ 1 .. 6 ] ] ];                        # six operations
    my $compile = sub (%limits) {
        my $k = JGraft::Compiler->new(limits => {%limits});
        sub ($s) { $k->value($ctx, $s)->{const} ? 'folded' : 'left' };
    };
    is $compile->()->($long),           'folded', 'with no limits, every constant is folded';
    is $compile->(mem => 1e5)->($long), 'left',   'with limits, not one that would exceed them';
    my $ten = $compile->(ops => 10);
    is join(' ', map { $ten->($six) } 1 .. 3), 'folded left left', 'and the limits are for the graft as a whole';

    my @limits = (limits => { mem => 1e5 });
    my $either = JGraft->new([ JGRAFT => {}, [ IF => ['NUM'], [ COPY => 'short', ['NODE'] ], [ COPY => $long, ['NODE'] ] ] ], @limits);
    is $either->run(1, @limits)->output, 'short', 'what was left costs nothing in a run that does not reach it';
    is $either->run('x', @limits)->error->code, 'RESOURCE_LIMIT', 'and is subject to the limits of one that does';
    my $date = graft([ COPY => [ CASTDATE => '2024-02-29' ], 'd', [ CASTDATE => '2024-02-29' ], [ 'STASH', 'd' ] ],
        [ COPY => [ 'STASH', 'd', 'month' ], 'm' ], [ COPY => { in => [ [ [ CASTDATE => '2024-03-01' ] ] ] }, 'deep' ]);
    is show($date->apply({})), '{"d":"2024-02-29","deep":{"in":["2024-03-01"]},"m":2}',
        'a folded date is still a date inside, and a string outside';
};

subtest 'what always fails is found when the graft is compiled' => sub {
    my $warned = sub (@actions) { join ' | ', map { $_->code . ' ' . show($_->expr) } graft(@actions)->warnings };
    my $div    = [ DIV => 1, 0 ];

    # INVALID_TARGET may be what the graft is for, so it is only worth a warning.
    is $warned->([ COPY => { a => [ ADD => 1, $div ] }, 'x' ]), 'INVALID_TARGET ["DIV",1,0]',
        'the innermost expression that fails is reported, once';
    my ($warning) = graft([ COPY => $div, 'x' ])->warnings;
    ok $warning->expr == $div, 'as the very expression in the graft';
    like "$warning", qr/^INVALID_TARGET: division by zero/, 'with the error it would raise';
    is $warned->([ COPY => $div, 'a', [ DIV => 2, 0 ], 'b' ]), 'INVALID_TARGET ["DIV",1,0] | INVALID_TARGET ["DIV",2,0]',
        'each such expression has its own';
    is $warned->([ IF => [ ANY => [ IS => $div, 1 ], 5 ], [ COPY => 1, 'a' ] ]), 'INVALID_TARGET ["DIV",1,0]',
        'even where a match will take it for a failed probe';
    is $warned->([ MATCH => { a => [ IS => [ SUB => 1, 1 ], [ NUM => $div ] ] } ]), 'INVALID_TARGET ["DIV",1,0]',
        'or it is part of a pattern';
    my $twice = JGraft->new([ JGRAFT => { expr => [ bad => $div ] }, [ COPY => [ EXPR => 'bad' ], 'a', [ ADD => 1, [ EXPR => 'bad' ] ], 'b' ] ]);
    is scalar $twice->warnings, 1, 'a common expression is reported once, however often it is used';
    my $outer = [ DIV => [ CASE => [ ANY => [ IS => $div, 1 ] ], 1, 2 ], 0 ];
    is $warned->([ COPY => $outer, 'a' ]), 'INVALID_TARGET ["DIV",1,0] | INVALID_TARGET ' . show($outer),
        'an expression that fails on its own account is reported too';
    is $warned->([ COPY => ['FAIL'], 'a', [ CASE => [ IS => 1, 2 ], 3 ], 'b', [ ADD => 1, ['FAIL'] ], 'c' ]), '',
        'but not a failure that the graft asks for';
    is $warned->([ COPY => [ DIV => 1, ['NODE'] ], 'a' ]), '', 'nor one that depends on the data';

    my $r = graft([ IF => ['NUM'], [ COPY => $div, ['NODE'] ] ])->run('x');
    ok $r->ok, 'the graft is still valid, and works where the expression is not reached';
    $r = graft([ COPY => [ ADD => 1, $div ], 'a' ])->run({});
    is "@{[ $r->error ]}", 'INVALID_TARGET: division by zero in COPY at /2', 'and fails as it always did where it is';
    is show(graft([ COPY => [ FILTER => [ ANY => [ IS => $div ], ['NUM'] ], ['NODE'] ], ['NODE'] ])->apply([ 1, 'a', 2 ])),
        '[1,2]', 'or does not match';

    # INVALID_OPERAND means an expression was given what it can never accept: the graft is wrong.
    my $slice  = [ SLICE => 'abc', 'x' ];
    my @faulty = (
        [ 'in a value'                          => [ COPY => { a => [ CONCAT => 'a', $slice ] }, 'x' ] ],
        [ 'in a match, where it would be a failed probe' => [ IF => [ ANY => [ IS => $slice, 1 ], 5 ], [ COPY => 1, 'a' ] ] ],
        [ 'in a branch that a run may not take' => [ IF => ['NUM'], [ COPY => $slice, ['NODE'] ] ] ],
    );
    for (@faulty) {
        my ($where, $action) = @$_;
        ok !eval { graft($action) }, "an expression that is always invalid is a fault $where";
        is $@->code, 'INVALID_GRAFT', '... INVALID_GRAFT';
        ok $@->expr == $slice, '... naming the expression';
        my $lazy = JGraft->new([ JGRAFT => {}, $action ], strict => 0);
        is scalar $lazy->faults, 1, '... reported once';
    }
    my $lazy = JGraft->new([ JGRAFT => {}, $faulty[2][1] ], strict => 0);
    ok $lazy->run('x')->ok, 'when not strict, it is a fault only in a run that reaches it';
    is $lazy->run(1)->error->code, 'INVALID_GRAFT', 'and INVALID_GRAFT then';
    ok eval { graft([ COPY => [ SLICE => 'abc', ['NODE'] ], 'a' ]) }, 'what depends on the data is no fault';
};

subtest 'dates are replaced where they leave the engine' => sub {
    my $on = [ CASTDATE => '2024-02-29' ];
    is show(graft([ COPY => $on, 'd', [ LENGTH => [ 'NODE', 'd' ] ], 'n' ])->apply({})), '{"d":"2024-02-29","n":10}',
        'a date stored in the document is a string from then on';
    is show(graft([ COPY => $on, [ 'STASH', 'd' ], [ 'STASH', 'd', 'year' ], 'y' ])->apply({})), '{"y":2024}',
        'but stays a date in the stash';
    is show(graft([ COPY => { at => [ [ 1, $on ] ] }, [ 'STASH', 's' ] ], [ MOVE => [ 'STASH', 's' ], 'moved' ],
        [ SPLICE => [ 'NODE', 'moved', 'at', 0 ], 1, { on => $on } ])->apply({})),
        '{"moved":{"at":[{"on":"2024-02-29"},"2024-02-29"]}}', 'whichever action brings it, and however deep it lies';
    is show(JGraft->new([ JGRAFT => { expr => [ day => [ CASTDATE => [ 'NODE', 'd' ] ] ] },
        [ COPY => { when => [ EXPR => 'day' ] }, 'out' ] ])->apply({ d => '2024-02-29' })->{out}),
        '{"when":"2024-02-29"}', 'even one made by an expression that is compiled only when first used';
    is show(graft([ RAISE => 'info', 'see', { on => $on } ])->run({})->logs->[0]{data}), '{"on":"2024-02-29"}',
        'and in the log';

    # However a date reaches a stored value, it is found.
    my %route = (
        'an array built around it'  => [ [ $on ] ],
        'an object built around it' => [ MKOBJ => 'on', $on ],
        'LOCAL'                     => [ LOCAL => 't', $on, [ [ [ 'TEMP', 't' ] ] ] ],
        'LOCAL as the current node' => [ LOCAL => undef, $on, [ [ ['NODE'] ] ] ],
        'MAP'                       => [ MAP => [ CASTDATE => ['NODE'] ], [ ['2024-02-29'] ] ],
        'REDUCE'                    => [ REDUCE => [ CONCAT => [ 'TEMP', 'a' ], [ [ [ CASTDATE => ['NODE'] ] ] ] ], 'a', [ [] ], [ ['2024-02-29'] ] ],
        'CASE'                      => [ CASE => 1, 'no', [ [ $on ] ] ],
        'FILTER'                    => [ FILTER => ['EXISTS'], [ 'STASH', 'kept' ] ],
        'SLICE'                     => [ SLICE => [ 'STASH', 'kept' ], 0 ],
        'CONCAT'                    => [ CONCAT => [ [] ], [ 'STASH', 'kept' ] ],
        'PROPS'                     => [ SLICE => [ PROPS => { on => $on }, 2 ], 1, 1 ],
        'a constant'                => [ 'CONST', 'made' ],
    );
    for my $name (sort keys %route) {
        my $got = JGraft->new([ JGRAFT => { const => [ made => [ [ $on ] ] ] },
            [ COPY => [ [ $on ] ], [ 'STASH', 'kept' ] ], [ COPY => $route{$name}, 'out' ] ])->apply({})->{out};
        like eval { show($got) } // "a raw date: $@", qr/^[\[{"on:]*"2024-02-29"[\]}]*$/, "by way of $name";
    }

    # Only values that could hold a date are examined, and never the document itself.
    my $looked = 0;
    my $export = \&JGraft::Exec::export;
    no warnings 'redefine';
    local *JGraft::Exec::export = sub { $looked++; goto &$export };
    my $doc = { d => '2024-01-01', list => [ map { { id => $_ } } 1 .. 1000 ] };
    my $out = graft([ COPY => [ LESS => [ CASTDATE => [ 'NODE', 'd' ] ], [ CASTDATE => '2024-06-15' ] ], 'old',
        [ 'NODE', 'list' ], 'backup', [ SLICE => [ 'NODE', 'list' ], 1 ], 'rest' ])->apply($doc);
    ok $out->{old} && @{ $out->{backup} } == 1000 && @{ $out->{rest} } == 999,
        'a graft that compares dates, and copies parts of the document';
    cmp_ok $looked, '<=', 1, 'looks only at the result of the comparison';
    $looked = 0;
    graft([ COPY => [ 'STASH', 'x' ], 'copy' ])->run($doc);
    graft([ COPY => [ MAP => ['NODE'], [ 'NODE', 'list' ] ], 'copy' ])->apply($doc);
    is $looked, 0, 'and a graft that makes no dates looks at nothing at all';
};

subtest 'limits on the arrays and objects a run creates' => sub {
    # The smallest limit of one kind under which a run succeeds: what the run used.
    my $least = sub ($which, $in, @actions) {
        my $g = graft(@actions);
        for my $n (0 .. 20) {
            my $r = $g->run($in, limits => { $which => $n });
            return $n if $r->ok;
            return 'failed: ' . $r->error unless $r->error->code eq 'RESOURCE_LIMIT' && $r->error->message =~ /^$which /;
        }
        return 'more than 20';
    };
    my $N = ['NODE'];

    # new_obj: each array or object made as a value counts one.
    my @new = (
        [ 1, 'an object written with a computed member'  => 5, [ COPY => { a => $N }, $N ] ],
        [ 1, 'an array written with a computed element'  => 5, [ COPY => [ [ $N, 1 ] ], $N ] ],
        [ 2, 'each of them, when nested'                 => 5, [ COPY => { a => { b => $N } }, $N ] ],
        [ 2, 'each object made on the way to a new path' => {}, [ COPY => 1, [ 'NODE', 'a', 'b', 'c' ] ] ],
        [ 2, 'and each array'                            => {}, [ COPY => 1, [ 'NODE', 'list', 0, 'x' ] ] ],
        [ 1, 'the result of MAP'                         => [ 1, 2, 3 ], [ COPY => [ MAP => [ ADD => $N, 1 ] ], $N ] ],
        [ 4, 'and whatever it makes for each element'    => [ 1, 2, 3 ], [ COPY => [ MAP => { v => $N } ], $N ] ],
        [ 1, 'the result of FILTER'                      => [ 1, 2, 3 ], [ COPY => [ FILTER => [ NUM => 2 ] ], $N ] ],
        [ 1, 'of CONCAT on arrays'                       => [ 1, 2, 3 ], [ COPY => [ CONCAT => $N, $N ], $N ] ],
        [ 1, 'of SLICE on an array'                      => [ 1, 2, 3 ], [ COPY => [ SLICE => $N, 1 ], $N ] ],
        [ 1, 'of SPLIT'                                  => 'a,b', [ COPY => [ SPLIT => ',' ], $N ] ],
        [ 1, 'the pieces that ATSPLIT works on'          => 'a,b', [ ATSPLIT => $N, ',', [ COPY => 'c', 0 ] ] ],
        [ 1, 'the names from PROPS'                      => { a => 1, b => 2 }, [ COPY => ['PROPS'], $N ] ],
        [ 3, 'its pairs, and the array of them'          => { a => 1, b => 2 }, [ COPY => [ PROPS => $N, 1 ], $N ] ],
        [ 3, 'its names and values, and the array of both' => { a => 1, b => 2 }, [ COPY => [ PROPS => $N, 2 ], $N ] ],
        [ 1, 'the result of MKOBJ'                       => 5, [ COPY => [ MKOBJ => 'a', $N ], $N ] ],
        [ 2, 'a capture and its path'                    => [ 1, 2 ], [ MATCH => [ [ [ SEQMAX => 'x', ['REP'] ] ] ] ] ],
        [ 3, 'and the object that CAPTURE returns'       => [ 1, 2 ], [ COPY => [ CAPTURE => [ [ [ SEQMAX => 'x', ['REP'] ] ] ] ], $N ] ],
    );
    is $least->(new_obj => @$_[ 2 .. $#$_ ]), $_->[0], "new_obj counts $_->[1]" for @new;

    my @free = (
        [ 'a constant, which is part of the graft' => 5, [ COPY => { a => { b => [ [ 1 ] ] } }, $N ] ],
        [ 'a string'                => 'abc', [ COPY => [ CONCAT => $N, [ SLICE => $N, 1 ] ], $N ] ],
        [ 'a change to what exists' => { a => [ 1, 2 ], b => { c => 1 } }, [ COPY => 9, [ 'NODE', 'b', 'c' ] ],
            [ SPLICE => [ 'NODE', 'a', 0 ], 1, 7, 8 ], [ MOVE => [ 'NODE', 'a', 0 ], [ 'NODE', 'b', 'd' ] ] ],
        [ 'a copy of what exists'   => { a => [ 1, { b => 2 } ] },
            [ COPY => [ 'NODE', 'a' ], 'again', [ 'NODE', 'a', 1 ], [ 'STASH', 's' ] ] ],
        [ 'a property added'        => {}, [ COPY => 1, 'a', 2, 'b', 3, 'c' ] ],
    );
    is $least->(new_obj => @$_[ 1 .. $#$_ ]), 0, "but not $_->[0]" for @free;

    # prop_per_obj: an object may not be made with more properties, nor be given more.
    my $two = { a => 1, b => 2 };
    my @wide = (
        [ 3, 'an object written with computed members' => 5, [ COPY => { a => $N, b => 1, c => 2 }, $N ] ],
        [ 2, 'the result of MKOBJ'                     => 5, [ COPY => [ MKOBJ => 'a', $N, 'b', 1 ], $N ] ],
        [ 3, 'an object given a property'              => $two, [ COPY => 3, 'c' ] ],
        [ 3, 'or given one on the way to a new path'   => $two, [ COPY => 3, [ 'NODE', 'c', 'd' ] ] ],
        [ 3, 'or by MOVE'                              => { a => { x => 1 }, b => 2 }, [ MOVE => [ 'NODE', 'a', 'x' ], 'c' ] ],
        [ 2, 'even in place of one it lost'            => $two, [ MOVE => 'a', 'c' ] ],
        [ 2, 'a namespace, which is an object too'     => 5, [ COPY => 1, [ 'STASH', 's' ], 2, [ 'STASH', 't' ] ] ],
    );
    is $least->(prop_per_obj => @$_[ 2 .. $#$_ ]), $_->[0], "prop_per_obj limits $_->[1]" for @wide;
    my @narrow = (
        [ 'an array, however long'       => 5,    [ COPY => [ [ $N, $N, $N ] ], $N ] ],
        [ 'a property that is replaced'  => $two, [ COPY => 3, 'b' ] ],
        [ 'a property that is removed'   => $two, [ MOVE => 'a', undef ] ],
        [ 'an object that is only read'  => $two, [ MATCH => { a => 1 } ], [ COPY => ['PROPS'], 'a' ] ],
    );
    is $least->(prop_per_obj => @$_[ 1 .. $#$_ ]), 0, "but not $_->[0]" for @narrow;

    is graft([ COPY => [ MAP => { v => $N } ], $N ])->run([ 1 .. 500 ])->ok, 1, 'neither is limited unless asked';

    # As with the other limits, constants are made by `new`, under the limits given to it.
    my $compile = sub (%limits) {
        my $k = JGraft::Compiler->new(limits => {%limits});
        sub ($s) { $k->value({ scope => { exprs => {}, cells => {} } }, $s)->{const} ? 'folded' : 'left' };
    };
    my $one = $compile->(new_obj => 1);
    is join(' ', map { $one->([ MAP => [ ADD => $N, 1 ], [ [ 1, 2 ] ] ]) } 1, 2), 'folded left',
        'new_obj given to new is an allowance for the constants of the graft';
    is $compile->(prop_per_obj => 1)->([ MKOBJ => 'a', 1, 'b', 2 ]), 'left', 'and prop_per_obj applies to each of them';
    my @limits = (limits => { prop_per_obj => 1 });
    is JGraft->new([ JGRAFT => {}, [ COPY => [ MKOBJ => 'a', 1, 'b', 2 ], $N ] ], @limits)->run(0, @limits)->error->code,
        'RESOURCE_LIMIT', 'so a constant too wide for both is refused by the run';
};

subtest 'an error says where in the graft it arose' => sub {
    # `where` is a JSON Pointer into the structure given to `new`.
    my $struct = [ JGRAFT => {},
        [ COPY => 1, 'x' ],
        [ AT => 'a',
            [ COPY => 2, 'c' ],
            [ IF => ['NUM'], [ COPY => 1, 'n' ], { b => 1 }, [ MATCH => { b => [ 'NODE', 'limit' ] } ], [ COPY => [ DIV => 1, ['NODE', 'b'] ], 'd' ] ] ],
        [ ATSPLIT => 's', ',', [ COPY => 5, 0 ] ] ];
    my $g       = JGraft->new($struct);
    my $pointed = sub ($e) { my $at = $struct; $at = $at->[$_] for grep { length } split m{/}, $e->where; $at };
    my $r       = $g->run({ a => { b => 1 } });
    is "@{[ $r->error ]}", 'NO_MATCH: the data does not match in MATCH at /3/3/4, on /a', 'an action inside others';
    is $r->error->action, 'MATCH', 'the action is named';
    ok $pointed->($r->error) == $struct->[3][3][4], 'and the pointer leads to it';
    is show($r->partial), '{"a":{"b":1,"c":2},"x":1}', 'the partial document has what was done before it';
    $r = $g->run({ a => { b => 0 } });
    is "@{[ $r->error ]}", 'INVALID_TARGET: division by zero in COPY at /3/3/5, on /a', 'the last, unconditional action of an IF';
    $r = $g->run({ a => { b => 2 }, s => 'p,q' });
    is "@{[ $r->error ]}", 'INVALID_TARGET: JOIN needs an array of strings in ATSPLIT at /4, on /s',
        'an action that fails after the actions inside it have run';
    $r = JGraft->new([ JGRAFT => {}, [ JGRAFT => { const => [ k => [ DIV => 1, ['NODE'] ] ] } ] ])->run(0);
    is "@{[ $r->error ]}", 'INVALID_TARGET: division by zero in JGRAFT at /2', 'an inner graft';
    $r = JGraft->new([ JGRAFT => { const => [ k => [ DIV => 1, ['NODE'] ] ] } ])->run(0);
    is "@{[ $r->error ]}", 'INVALID_TARGET: division by zero in JGRAFT', 'the graft itself, whose pointer is empty';
    is $r->error->where, '', '... but defined';

    # What is found when compiling is placed in the same way.
    ok !eval { graft([ MATCH => 1, ['NOPE'] ]) }, 'an unknown action is a fault';
    is "$@", 'INVALID_GRAFT: unknown action at /2/2', 'placed, though it has no name';
    ok !eval { graft([ MATCH => 1, [ COPY => [ SLICE => 'abc', 'x' ], 'a' ] ]) }, 'so is an expression that is always invalid';
    like "$@", qr/^INVALID_GRAFT: an expression always fails: .* in COPY at \/2\/2$/, 'placed by the action it is in';
    my ($warning) = graft([ IF => 1, [ COPY => [ DIV => 1, 0 ], 'a' ] ])->warnings;
    is "$warning", 'INVALID_TARGET: division by zero in COPY at /2/2', 'and so is a warning';
    my $lazy = JGraft->new([ JGRAFT => { expr => [ f => [ CONCAT => 'a', [ SLICE => 'abc', 'x' ] ] ] },
        [ COPY => 1, 'a' ], [ COPY => [ EXPR => ['NODE', 'name'] ], 'b' ] ], strict => 0);
    is "@{[ $lazy->run({ name => 'f' })->error ]}",
        'INVALID_GRAFT: an expression always fails: SLICE offset and length must be integers in COPY at /3',
        'even a fault in an expression that is compiled only when a run first uses it';
    ok !eval { JGraft->new([ COPY => 1, 2 ]) } && "$@" eq 'INVALID_GRAFT: a graft must be a JGRAFT action',
        'what is not a graft at all has no place to report';

    # A failure leaves data behind, never the engine's own markers.
    my @vacated = (
        [ { a => 1, b => 2 }, '{"a":null,"b":2}', [ AT => 'a', [ MOVE => ['NODE'], [ 'STASH', 'x' ] ] ] ],
        [ [ 1, 2 ],           '[null,2]',         [ AT => 0,   [ MOVE => ['NODE'], [ 'STASH', 'x' ] ] ] ],
        [ [ 1 ],              'null',             [ MOVE => ['NODE'], [ 'STASH', 'x' ] ] ],
    );
    is show(graft($_->[2])->run($_->[0])->partial), $_->[1], "a node moved away and not replaced is left as null: $_->[1]"
        for @vacated;

    my $fault = JGraft->new([ JGRAFT => {}, [ COPY => 1, 'a' ], ['NOPE'] ], strict => 0);
    my ($one, $two) = map { $fault->run($_) } {}, { z => 1 };
    is show([ $one->error->partial, $two->error->partial ]), '[{"a":1},{"a":1,"z":1}]',
        'the error of each run is its own, though the fault is one';
    is(($fault->faults)[0]->partial, undef, 'and the fault itself is left alone');
};

subtest 'an error says where in the document the current node is' => sub {
    # `node` has the form of a capture, and leads to the node in the partial document.
    my $found = sub ($r) {
        my ($node, $v) = ($r->error->node, $r->partial);
        $v = ref $v eq 'HASH' ? $v->{$_} : $v->[$_] for @{ $node->{path} };
        return defined $node->{ofs} ? substr $v, $node->{ofs}, $node->{len} : $v;
    };
    my $fails = [ MATCH => 'no such thing' ];

    my $r = graft([ AT => [ 'NODE', 'a', 1 ], $fails ])->run({ a => [ 1, { b => 2 } ] });
    is show($r->error->node), '{"path":["a",1]}', 'the path to the node that the action was working on';
    is show($found->($r)), '{"b":2}', 'which leads to it';
    like "@{[ $r->error ]}", qr{ in MATCH at /2/2, on /a/1$}, 'and is part of the message';
    is show(graft($fails)->run(5)->error->node), '{"path":[]}', 'the document itself has the empty path';
    like "@{[ graft([ AT => 'x/y~z', $fails ])->run({ 'x/y~z' => 1 })->error ]}", qr{, on /x~1y~0z$},
        'the message gives the path as a JSON Pointer';
    is show(graft([ COPY => [ MAP => [ DIV => 1, ['NODE'] ] ], 'out' ])->run([ 1, 0 ])->error->node), '{"path":[]}',
        'it is the node of the action, not one that an expression is looking at';

    # Inside ATSPLIT the nodes are pieces of a string, and the string is where the path leads.
    my $text = join "\n", map { "line $_ has words" } 1 .. 5;
    my $doc  = sub { { doc => { text => $text } } };
    my $at   = [ 'NODE', 'doc', 'text' ];
    $r = graft([ ATSPLIT => $at, "\n", [ COPY => 'FIRST', 0 ], [ MATCH => [ ARRAY => 2, 'nope' ] ] ])->run($doc->());
    is show($r->error->node), '{"path":["doc","text"]}', 'all the pieces together are the string';
    is $r->partial->{doc}{text}, $text =~ s/line 1 has words/FIRST/r, 'which the failure leaves as its pieces stood';

    $r = graft([ ATSPLIT => $at, "\n", [ SPLICE => 0, 1, 'a new and longer first line', 'and another' ], [ AT => 3, $fails ] ])
        ->run($doc->());
    is show($r->error->node), '{"len":16,"lim":73,"ofs":57,"path":["doc","text"]}', 'one piece is a span of it';
    is $found->($r), 'line 3 has words', 'placed in the string as the failure left it';
    like "@{[ $r->error ]}", qr{, on /doc/text \(ofs 57, len 16\)$}, 'and described in the message';

    $r = graft([ ATSPLIT => $at, "\n", [ COPY => 'FIRST', 0 ],
        [ ATSPLIT => 2, ' ', [ COPY => 'LINE', 0 ], [ AT => 2, $fails ] ] ])->run($doc->());
    is $found->($r), 'has', 'a piece of a piece is a span of the same string';
    is $r->partial->{doc}{text}, "FIRST\nline 2 has words\nLINE 3 has words\nline 4 has words\nline 5 has words",
        'with the changes made at each level';
    $r = graft([ ATSPLIT => $at, "\n", [ ATSPLIT => 2, ' ', [ COPY => 'A', 0 ], [ MATCH => [ ARRAY => 9 ] ] ] ])->run($doc->());
    is $found->($r), 'A 3 has words', 'all the pieces of a piece are that piece, as it has become';

    $r = graft([ ATSPLIT => ['NODE'], { sep => [ ANY => ',', ';' ], trim => [ REP => 0, -1, ' ' ], default => ',' },
        [ COPY => 'BB', 1 ], [ AT => 2, $fails ] ])->run('a ,  b ;  c');
    is show([ $r->partial, $found->($r) ]), '["a ,  BB ;  c","c"]', 'whatever is between the pieces is allowed for';
    like "@{[ $r->error ]}", qr{, on the document \(ofs 11, len 1\)$}, 'and the document may itself be the string';

    $r = graft([ ATSPLIT => 't', ',', [ COPY => 5, 1 ], [ AT => 2, $fails ] ])->run({ t => 'a,b,c' });
    is show([ $r->error->node, $r->partial ]), '[{"path":["t"]},{"t":"a,b,c"}]',
        'pieces that no longer make a string leave the string as it was, and only the path';

    # Finding this out must not change the failure.
    my $costly = graft([ ATSPLIT => 't', ',', [ COPY => [ CONCAT => [ 'NODE', 0 ], [ 'NODE', 0 ] ], 0 ], [ AT => 1, $fails ] ]);
    my $run    = sub ($ops) { $costly->run({ t => join ',', ('abcdefghij') x 10 }, limits => { ops => $ops }) };
    my ($just) = grep { $run->($_)->error->code eq 'NO_MATCH' } 1 .. 500;      # enough to reach the failure, and no more
    is $run->($just - 1)->error->code, 'RESOURCE_LIMIT', 'a run can use up its limits before it fails';
    is length $run->($just)->partial->{t}, 119, 'and its pieces are still joined again, which is work, for the partial document';
    is show($run->($just)->error->node), '{"len":10,"lim":31,"ofs":21,"path":["t"]}', 'and to say where the node is';

    my ($warning) = graft([ COPY => [ DIV => 1, 0 ], 'a' ])->warnings;
    is $warning->node, undef, 'what is found when compiling has no node';
};

subtest 'a run can be undone' => sub {
    # `undo` is a graft that turns what a run left into what it was given.
    my $doc  = sub { { name => 'x', tags => [ 'a', 'b', 'c', 'd' ], user => { id => 7, roles => [ [ 1, 2 ], { k => 'v' } ] }, text => "one\ntwo\nthree" } };
    my $undo = sub ($in, @actions) {
        my $r    = graft(@actions)->run($in);
        my $back = JGraft->new($json->decode($json->encode($r->undo)))->apply($r->ok ? $r->output : $r->partial);
        return 'does not restore the input: ' . show($back) if show($back) ne show($in);
        my (undef, undef, @do) = @{ $r->undo };
        return join ' ', map { show($_) } @do;
    };
    my @case = (
        [ 'nothing, if nothing was done' => '', [ MATCH => { name => 'x' } ] ],
        [ 'what was added is removed, and what was replaced put back' =>
            '["MOVE",["NODE","new"],null] ["COPY","x",["NODE","name"],"v",["NODE","user","roles",1,"k"]]',
            [ COPY => 1, 'new', 'y', 'name', 9, [ 'NODE', 'user', 'roles', 1, 'k' ] ] ],
        [ 'a path that was created is removed where it began' => '["MOVE",["NODE","a"],null]', [ COPY => 1, [ 'NODE', 'a', 'b', 0, 'c' ] ] ],
        [ 'a splice is undone by a splice' => '["SPLICE",["NODE","tags",1],3,"b","c"]', [ SPLICE => [ 'NODE', 'tags', 1 ], 2, 'X', 'Y', 'Z' ] ],
        [ 'and so is an element added at the end' => '["SPLICE",["NODE","tags",4],1]', [ COPY => 'e', [ 'NODE', 'tags', 4 ] ] ],
        [ 'an element that moved goes back' => '["SPLICE",["NODE","tags",3],1] ["SPLICE",["NODE","tags",0],0,"a"]',
            [ MOVE => [ 'NODE', 'tags', 0 ], [ 'NODE', 'tags', 3.5 ] ] ],
        [ 'in a string of several lines, the lines that changed are put back' =>
            '["ATSPLIT",["NODE","text"],"\\n",["COPY","two",["NODE",1]]]', [ ATSPLIT => 'text', "\n", [ SPLICE => 1, 1, '2' ] ] ],
        [ 'however the string came to change' => '["ATSPLIT",["NODE","text"],"\\n",["SPLICE",["NODE",3],1]]',
            [ COPY => [ CONCAT => [ 'NODE', 'text' ], "\nfour" ], 'text' ] ],
        [ 'a string with no line in common is put back whole' => '["COPY","one\\ntwo\\nthree",["NODE","text"]]',
            [ COPY => "1\n2", 'text' ] ],
        [ 'and so is one of a single line' => '["COPY","x",["NODE","name"]]', [ COPY => 'y', 'name' ] ],
        [ 'arrays in what is put back are written as a graft writes them' => '["COPY",[["a","b","c","d"]],["NODE","tags"]]',
            [ COPY => 'none', 'tags' ] ],
        [ 'several changes to one array are undone one by one, the last first' =>
            '["COPY","",["NODE",29]] ["SPLICE",["NODE",20],0,"line 20"] ["SPLICE",["NODE",6],1] ["COPY","line 5",["NODE",4]]',
            [ SPLICE => 4, 2, 'new', '', 'newer' ], [ SPLICE => 20, 1 ], [ COPY => 'end', 29 ] ],
    );
    for (@case) {
        my ($name, $want, @actions) = @$_;
        is $undo->($actions[0][0] eq 'SPLICE' && !ref $actions[0][1] ? [ map { $_ % 3 ? "line $_" : '' } 1 .. 30 ] : $doc->(), @actions),
            $want, $name;
    }

    # However much there is, only what changed is put back.
    my $records = sub { { list => [ map { { id => $_, tags => [ 'a', 'b' ] } } 1 .. 2000 ], other => [ 1 .. 2000 ] } };
    is $undo->($records->(), [ COPY => 'changed', [ 'NODE', 'list', 1500, 'tags', 1 ] ], [ SPLICE => [ 'NODE', 'list', 10 ], 2 ]),
        '["COPY","b",["NODE","list",1498,"tags",1]] ["SPLICE",["NODE","list",10],0,{"id":11,"tags":[["a","b"]]},{"id":12,"tags":[["a","b"]]}]',
        'two changes far apart in a long array are two small actions';
    my $wide = { a => [ { id => 1 }, { id => 2 } ], big => [ 1 .. 5000 ], more => { map { ("k$_" => [ 1 .. 10 ]) } 1 .. 500 } };
    my ($looked, $alike) = (0, \&JGraft::Undo::alike);
    {
        no warnings 'redefine';
        local *JGraft::Undo::alike = sub { $looked++; goto &$alike };
        graft([ COPY => 0, [ 'NODE', 'a', 1, 'id' ] ])->run($wide)->undo;
    }
    cmp_ok $looked, '<', 10, "and an array or object that a run left alone is not looked into ($looked comparisons, beside 10,000 values)";
    is $undo->([ 1 .. 500 ], [ COPY => [ MAP => [ ADD => ['NODE'], 0.5 ] ], ['NODE'] ]),
        '["SPLICE",["NODE",0],500,' . join(',', 1 .. 500) . ']', 'an array that changed throughout is put back in one action';

    my $text  = join "\n", map { $_ % 7 ? "line $_ of the text" : '' } 1 .. 10_000;
    my $lines = $undo->({ doc => $text }, [ ATSPLIT => 'doc', "\n", [ SPLICE => 9000, 2, 'new' ], [ SPLICE => 5000, 0, 'inserted', '' ],
        [ COPY => 'CHANGED', 12 ], [ SPLICE => 3, 1 ] ]);
    is $lines, '["ATSPLIT",["NODE","doc"],"\\n",["SPLICE",["NODE",9001],1,"line 9001 of the text",""],["SPLICE",["NODE",4999],2],'
        . '["COPY","line 13 of the text",["NODE",11]],["SPLICE",["NODE",3],0,"line 4 of the text"]]',
        'a handful of changes among 10,000 lines are undone by as many actions';

    # Arrays are compared for the least change there can be: checked here against the textbook
    # table for the longest common subsequence.
    my $common = sub ($a, $b) {
        my @t = map { [ (0) x (@$b + 1) ] } 0 .. @$a;
        for my $i (1 .. @$a) {
            for my $j (1 .. @$b) {
                my ($up, $left) = ($t[ $i - 1 ][$j], $t[$i][ $j - 1 ]);
                $t[$i][$j] = $a->[ $i - 1 ] eq $b->[ $j - 1 ] ? $t[ $i - 1 ][ $j - 1 ] + 1 : $up > $left ? $up : $left;
            }
        }
        $t[-1][-1];
    };
    my $marked = sub ($flags) { scalar grep { $_ } @$flags };
    my $sound  = sub ($new, $old, $come, $gone) {       # what is left of each must be the same, in the same order
        join(' ', map { $new->[$_] } grep { !$come->[$_] } 0 .. $#$new) eq join(' ', map { $old->[$_] } grep { !$gone->[$_] } 0 .. $#$old);
    };
    srand 11;
    my %bad = (least => 0, 'not the least' => 0, roughly => 0);
    for (1 .. 1500) {
        my $letters = 1 + int rand(rand() < .5 ? 3 : 30);
        my @old = map { int rand $letters } 1 .. rand 14;
        my @new = rand() < .5 ? (map { int rand $letters } 1 .. rand 14) : @old;
        if (@new == @old) { rand() < .5 ? splice(@new, rand(@new + 1), 1) : splice(@new, rand(@new + 1), 0, int rand $letters) for 1 .. rand 5 }
        my ($come, $gone) = JGraft::Undo::least(\@new, \@old, 1e9);
        $bad{least}++ unless $sound->(\@new, \@old, $come, $gone);
        $bad{'not the least'}++ unless $marked->($come) + $marked->($gone) == @new + @old - 2 * $common->(\@new, \@old);
        $bad{roughly}++ unless $sound->(\@new, \@old, JGraft::Undo::roughly(\@new, \@old));
    }
    is show(\%bad), '{"least":0,"not the least":0,"roughly":0}', 'the change found between two arrays is sound, and is the least there can be';

    # When too much has changed for the least to be worth finding, it is found roughly, but
    # still without disturbing what did not change.
    is scalar(() = JGraft::Undo::least([ 1 .. 300 ], [ reverse 1 .. 300 ], 1000 + 4 * 600)), 0, 'a large change is given up on';
    my @was = ((0) x 3000, (map { $_ % 2 } 1 .. 3000), (0) x 3000);
    my @now = ((0) x 3000, (map { $_ * 7 % 3 ? 1 : 0 } 1 .. 2900), 5, (0) x 3000);
    my $much = graft([ COPY => [ \@now ], ['NODE'] ])->run(\@was);
    my (undef, undef, @do)   = @{ $much->undo };
    my ($removed, $restored) = (0, 0);
    ($removed += $_->[2], $restored += @$_ - 3) for grep { $_->[0] eq 'SPLICE' } @do;
    $restored += (@$_ - 1) / 2 for grep { $_->[0] eq 'COPY' } @do;
    cmp_ok $removed + $restored, '<', 3000, "and touches only where the change is ($removed removed, $restored put back, of 9,000)";
    is show(JGraft->new($much->undo)->apply($much->output)), show(\@was), 'and is undone all the same';
    my @from = ('A', (map { "x$_" } 1 .. 1000), '', 'y');
    my @to   = ('', @from[ 1 .. $#from ]);
    my @keys = map { [ map { JGraft::Undo::key($_) } @$_ ] } \@to, \@from;
    is join(' ', map { $marked->($_) } JGraft::Undo::roughly(@keys)), '1 1',
        'an element that only looks like one far away is not taken for it';

    # A failure can be undone too: from the partial document.
    my $fails = graft([ COPY => 1, 'new' ], [ SPLICE => [ 'NODE', 'tags', 0 ], 1 ], [ MATCH => 0 ]);
    my $r     = $fails->run($doc->());
    is show($r->partial->{tags}), '["b","c","d"]', 'a run that fails has made changes';
    is show([ @{ $r->undo }[ 2, 3 ] ]), '[["MOVE",["NODE","new"],null],["SPLICE",["NODE","tags",0],0,"a"]]', 'and says how to undo them';
    is show(JGraft->new($r->undo)->apply($r->partial)), show($doc->()), 'which gives back the input';
    ok !eval { $fails->apply($doc->()); 1 }, 'apply dies';
    is show(JGraft->new($@->undo)->apply($@->partial)), show($doc->()), 'and its error has the same';
    ok $r->undo == $r->undo, 'it is worked out once';
    my ($fault) = JGraft->new([ JGRAFT => {}, ['NOPE'] ], strict => 0)->faults;
    is $fault->undo, undef, 'a fault found when compiling has nothing to undo';

    # Dates, where a document keeps them, are written as the expressions that make them.
    my @keep  = (date_export => sub ($d) { $d });
    my $dated = graft([ COPY => [ CASTDATE => '2024-02-29' ], 'd', [ CASTDATE => '2024-02-29T10:00:00+0100' ], 't' ])->apply({}, @keep);
    $r = graft([ COPY => 1, 'd' ], [ MOVE => 't', undef ])->run($dated, @keep);
    is show($r->undo->[2]), '["COPY",["CASTDATE","2024-02-29"],["NODE","d"],["CASTDATE","2024-02-29T10:00:00+0100"],["NODE","t"]]',
        'a date is put back by CASTDATE';
    my $back = JGraft->new($r->undo)->apply($r->output, @keep);
    is join(' ', map { ref($back->{$_}) . ' ' . $back->{$_}->str } 'd', 't'), 'JGraft::Date 2024-02-29 JGraft::Date 2024-02-29T10:00:00+0100',
        'and is a date again';
};

subtest 'trimming is quick' => sub {
    # A trim that is a run of characters from one set is found by Perl's own matcher.
    my $c    = JGraft::Compiler->new;
    my $kind = sub ($pattern) {
        my $n = $c->match({ scope => { exprs => { ws => [ CHARS => " \t" ] }, cells => {} }, regex => 1, seq => 1, top => 1 }, $pattern);
        $n->{run} && JGraft::Ops::Split::native(@{ $n->{run} }) ? 'Perl' : 'pattern';
    };
    my $ws = [ expr => [ ws => [ CHARS => " \t" ] ] ];      # a set, to be referred to by name
    my ($T, $F) = (JSON::PP::true, JSON::PP::false);
    is $kind->($_->[1]), 'Perl', "Perl is given $_->[0]" for
        [ 'a run of one character'           => [ REP => 0, -1, ' ' ] ],
        [ 'one given by its code point'      => [ REP => 0, -1, 32 ] ],
        [ 'a run of a set, with limits'      => [ REP => 1, 3, [ CHARS => " \t" ] ] ],
        [ 'a set made by taking away'        => [ REP => 0, -1, [ CHARS => $F, 'a', 'z', $T, 'q' ] ] ],
        [ 'a choice of single characters'    => [ REP => 0, -1, [ ANY => ' ', "\t", [ CHARS => '0', '9' ] ] ] ];
    is $kind->($_->[1]), 'pattern', "but not $_->[0]" for
        [ 'a set that refers to another'     => [ REP => 0, -1, [ CHARS => [ EXPR => 'ws' ] ] ] ],
        [ 'a choice that is not of single characters' => [ REP => 0, -1, [ ANY => ' ', "\t\t" ] ] ],
        [ 'a run inside something else'      => [ SEQ => [ REP => 0, -1, ' ' ] ] ],
        [ 'a run whose limits depend on the data' => [ REP => 0, [ 'NODE' ], ' ' ] ],
        [ 'a run of nothing'                 => [ REP => 0, -1, ['CHARS'] ] ];

    # Whoever does it, the result is the same.
    my $native = \&JGraft::Ops::Split::native;
    my $both   = sub ($spec, $text) {
        my $g = sub { show(graft([ COPY => [ SPLIT => $spec ], [ 'STASH', 's' ] ],
            [ COPY => { pieces => [ 'STASH', 's' ], joined => [ JOIN => $spec, [ 'STASH', 's' ] ] }, ['NODE'] ])->apply($text)) };
        no warnings 'redefine';
        my $by_perl = $g->();
        local *JGraft::Ops::Split::native = sub { undef };
        return ($by_perl, $g->());
    };
    my ($by_perl, $by_pattern) = $both->({ sep => ',', trim => [ REP => 0, -1, ' ' ] }, '  a b ,c,   ,  ,d   ');
    is $by_perl, '{"joined":"  a b ,c,   ,  ,d   ","pieces":["a b","c","","","d"]}', 'pieces are trimmed, and joined as they were';
    is $by_perl, $by_pattern, 'as they are when Perl is not asked';
    is show(graft([ ATSPLIT => 't', { sep => ',', trim => [ REP => 0, -1, ' ' ] }, [ COPY => { was => [ 'NODE', 0 ] }, [ 'STASH', 'o' ] ] ],
        [ COPY => [ 'STASH', 'o' ], 'o' ])->apply({ t => ' a , b ' })), '{"o":{"was":"a"},"t":" a , b "}',
        'and an object can be built while trimmings are being kept (it used to crash)';
    srand 5;
    my @chars = (' ', "\t", 'a', '-', "\x{e9}", "\x{1F600}");
    my $differ = 0;
    for (1 .. 400) {
        my $body = (' ', '-', 32, [ CHARS => " \t" ], [ CHARS => $F, 'a', 'z' ], [ CHARS => 'a', "\x{e9}", $F, 'b' ])[ rand 6 ];
        my $run  = [ REP => @{ ([ 0, -1 ], [ 1, -1 ], [ 0, 2 ], [ 2, 3 ], [ 0, 0 ])[ rand 5 ] }, $body ];
        my %spec = (sep => ',', (rand() < .5 ? (trim => $run) : (map { rand() < .7 ? ($_ => $run) : () } qw(ltrim rtrim))));
        my $text = join ',', map { join '', map { $chars[ rand @chars ] } 1 .. rand 9 } 1 .. 1 + rand 4;
        my ($a, $b) = $both->(\%spec, $text);
        $differ++ if $a ne $b;
    }
    is $differ, 0, 'for any run, limits and text';

    # A trim that Perl cannot be given still costs in proportion to what it trims.
    my $long = 'x' . ' ' x 2000;
    for ([ 'by Perl' => ' ' ], [ 'by the pattern' => [ CHARS => [ EXPR => 'ws' ] ] ]) {
        my ($who, $body) = @$_;
        my $r = JGraft->new([ JGRAFT => { @$ws }, [ COPY => [ SPLIT => { sep => ',', rtrim => [ REP => 0, -1, $body ] } ], ['NODE'] ] ])
            ->run($long, limits => { ops => 12_000 });
        is show($r->output), '["x"]', "2,000 trailing characters are trimmed $who with about as many steps, not their square";
    }
};

subtest 'Perl matches the characters of strings where it can' => sub {
    my ($T, $F) = (JSON::PP::true, JSON::PP::false);
    my $c    = JGraft::Compiler->new;
    my $node = sub ($pattern) { $c->match({ scope => { exprs => {}, cells => {} }, regex => 1, seq => 1, top => 1 }, $pattern) };
    my $re   = sub ($pattern) { $node->($pattern)->{re} // 'none' };

    # A pattern has a regex only if the regex matches just what the pattern does.
    is $re->($_->[1]), $_->[2], "as a regex: $_->[0]" for
        [ 'a string'                       => 'ab',                                  '\x{61}\x{62}' ],
        [ 'a set'                          => [ CHARS => '0', '9' ],                 '[\x{30}-\x{39}]' ],
        [ 'a set with nothing in it'       => ['CHARS'],                             '(?!)' ],
        [ 'a run of a set'                 => [ REP => 1, -1, [ CHARS => '0', '9' ] ], '[\x{30}-\x{39}]{1,}' ],
        [ 'a run of anything'              => [ REP => 2, 3 ],                       '(?s:.){2,3}' ],
        [ 'a sequence, and the ends'       => [ SEQ => ['START'], 'a', ['END'] ],    '\A\x{61}\z' ],
        [ 'a choice, longest first'        => [ ANY => "\n", "\r\n" ],              '(?:\x{D}\x{A}|\x{A})' ],
        [ 'a refusal'                      => [ NONE => 'a', 'b' ],                  '(?!\x{61}|\x{62})' ];
    is $re->($_->[1]), 'none', "but there is none for $_->[0]" for
        [ 'a run of more than single characters' => [ REP => 0, -1, 'ab' ] ],
        [ 'a run with limits that depend on the data' => [ REP => 0, ['NODE'], 'a' ] ],
        [ 'ALL, which is not a meeting of matches' => [ ALL => 'a', [ CHARS => 'a', 'z' ] ] ],
        [ 'a character that depends on the data' => [ SEQ => 'a', [ 'TEMP', 'c' ] ] ],
        [ 'one element tested by a pattern of its own' => [ SEQ => [ IS => [ REP => 0, -1, 'a' ] ] ] ];

    # STR, asking only whether there is a match, puts the question to Perl.
    my $found = sub ($pattern, $text, @opt) {
        my $r = graft([ COPY => [ STR => $pattern ], ['NODE'] ])->run($text, @opt);
        $r->ok ? ($r->output ? 'yes' : 'no') : $r->error->code;
    };
    my $number = [ SEQ => 'needle ', [ REP => 1, -1, [ CHARS => '0', '9' ] ], ' end', ['END'] ];
    my $hay    = ('lorem ipsum dolor sit amet ' x 400) . 'needle 42 end';
    is $found->($number, $hay),        'yes', 'a match is found';
    is $found->($number, $hay . '.'),  'no',  'or not';
    is $found->($number, $hay, limits => { ops => 1e9 }),  'yes',            'as it is when operations are counted,';
    is $found->($number, $hay, limits => { ops => 1000 }), 'RESOURCE_LIMIT', 'which Perl is then not asked, so that the count is kept';
    is show(graft([ COPY => [ CAPTURE => [ STR => [ SEQMAX => 'n', [ REP => 1, -1, [ CHARS => '0', '9' ] ] ] ] ], ['NODE'] ])
        ->apply('xa42')), '{"n":{"len":2,"lim":4,"ofs":2,"path":[]}}', 'nor is it asked when captures are wanted';

    # A separator is found by Perl when its first match at a place is surely the longest, and not empty.
    my $by_perl = sub ($pattern) { JGraft::Ops::Split::separator($node->($pattern)) ? 'Perl' : 'pattern' };
    is $by_perl->($_->[1]), 'Perl', "Perl finds a separator that is $_->[0]" for
        [ 'a choice of strings'            => [ ANY => "\n", "\r\n" ] ],
        [ 'a choice of strings and sets'   => [ ANY => ', ', [ CHARS => ';', '|' ], ',' ] ],
        [ 'a run of one or more'           => [ REP => 1, -1, ' ' ] ];
    is $by_perl->($_->[1]), 'pattern', "but not one that is $_->[0]" for
        [ 'a sequence'                     => [ SEQ => [ REP => 0, -1, ' ' ], ',' ] ],
        [ 'a choice that may be empty'     => [ ANY => ',', '' ] ],
        [ 'a run that may be empty'        => [ REP => 0, -1, ' ' ] ];
    my $crlf = { sep => [ ANY => "\n", "\r\n" ], default => "\n" };
    is show(graft([ COPY => [ SPLIT => $crlf ], [ 'STASH', 's' ] ],
        [ COPY => { pieces => [ 'STASH', 's' ], joined => [ JOIN => $crlf, [ 'STASH', 's' ] ] }, ['NODE'] ])->apply("a\r\nb\nc")),
        '{"joined":"a\\r\\nb\\nc","pieces":["a","b","c"]}', 'the longer of two that match is the separator, and each is kept for the join';

    # Whoever does the matching, the answers are the same.
    no warnings qw(surrogate nonchar utf8);
    srand 3;
    my @letters = ('a', 'b', 'c', ' ', "\n", "\x{e9}", "\x{1F600}", chr 0xD800);
    my $pick    = sub { $letters[ rand @letters ] };
    my $text    = sub ($n) { join '', map { $letters[ rand(rand() < .7 ? 3 : @letters) ] } 1 .. rand $n };
    my $pattern;
    $pattern = sub ($depth) {
        my $k = rand;
        return $pick->()                                                 if $k < .2 || $depth > 3;
        return $text->(4)                                                if $k < .3;
        return [ CHARS => $F, $pick->(), $T, 'c' ]                       if $k < .4;
        return [ ('START', 'END')[ rand 2 ] ]                            if $k < .5;
        return [ REP => int rand 3, (-1, 0, 2)[ rand 3 ], (rand() < .2 ? () : rand() < .5 ? $pick->() : [ CHARS => 'a', 'b' ]) ] if $k < .64;
        return [ SEQ => map { $pattern->($depth + 1) } 1 .. rand 4 ]     if $k < .8;
        return [ ANY => map { $pattern->($depth + 1) } 1 .. 1 + rand 3 ] if $k < .9;
        return [ NONE => map { $pattern->($depth + 1) } 1 .. rand 3 ]    if $k < .96;
        return [ ALL => $pattern->($depth + 1), $pattern->($depth + 1) ];
    };
    my ($differ, $asked) = (0, 0);
    for (1 .. 1500) {
        my $p = $pattern->(0);
        $asked++ if $re->($p) ne 'none';
        my $s = $text->(12);
        $differ++ if $found->($p, $s) ne $found->($p, $s, limits => { ops => 1e12 });
    }
    is $differ, 0, "STR gives the same answer either way, for 1,500 patterns ($asked of them put to Perl)";
    my $separator = \&JGraft::Ops::Split::separator;
    $differ = 0;
    for (1 .. 1500) {
        my @alt  = map { rand() < .6 ? $text->(3) : rand() < .5 ? $pick->() : [ CHARS => 'a', 'b' ] } 1 .. 1 + rand 4;
        my %spec = (sep => [ ANY => @alt ], default => ',', (rand() < .3 ? (keep => (qw(< > @))[ rand 3 ]) : ()),
            (rand() < .2 ? (element => [ REP => 0, -1, [ CHARS => 'a', 'c' ] ]) : ()));
        my $s = $text->(16);
        my @out;
        for my $perl (1, 0) {
            no warnings 'redefine';
            local *JGraft::Ops::Split::separator = sub { undef } unless $perl;
            push @out, eval { show(graft([ COPY => [ SPLIT => \%spec ], [ 'STASH', 's' ] ],
                [ COPY => { pieces => [ 'STASH', 's' ], joined => [ JOIN => \%spec, [ 'STASH', 's' ] ] }, ['NODE'] ])->run($s)->output) } // "died: $@";
        }
        $differ++ if $out[0] ne $out[1];
    }
    is $differ, 0, 'and SPLIT gives the same pieces either way, for 1,500 separators';
};

subtest 'corners of moving, matching and counting' => sub {
    my ($T, $F) = (JSON::PP::true, JSON::PP::false);
    my $N = ['NODE'];
    my $run = sub ($meta, $in, $actions, @opt) {
        my $g = eval { JGraft->new([ JGRAFT => { v => 1, %$meta }, @$actions ]) } or return 'new: ' . $@->code;
        my $r = $g->run($in, @opt);
        $r->ok ? show($r->output) : $r->error->code;
    };
    my $yes = sub ($pattern) { [ COPY => [ CASE => $pattern, $T, $F ], $N ] };

    # MOVE
    is $run->({}, { n => { q => 1 } }, [ [ AT => 'n', [ MOVE => $N, [ 'STASH', 'a' ], $N, 'x', [ 'STASH', 'a' ], 'y' ] ] ]), 'INVALID_TARGET',
        'a node that has been moved away cannot be moved again';
    my $twice = graft([ MOVE => $N, [ 'STASH', 'a' ], $N, [ 'STASH', 'b' ], [ 'STASH', 'a' ], $N ])->run({ q => 1 });
    is $twice->error->code, 'INVALID_TARGET', 'nor can the document itself';
    is show($twice->partial), 'null', '... and what is left holds only data';
    is $run->({}, { a => 1 }, [ [ MOVE => $N, 'x' ] ]), '{"x":{"a":1}}', 'the document can be moved into itself, as any node can';
    my $s = { sep => [ ANY => ',', ';' ], default => '|' };
    is $run->({}, { t => 'a;b;c' }, [ [ COPY => [ SPLIT => $s, 'x,y,z' ], [ 'STASH', 's' ] ], [ ATSPLIT => 't', $s, [ MOVE => [ 'STASH', 's', 0 ], -0.5 ] ] ]),
        '{"t":"x;a;b;c"}', 'an element moved in from another SPLIT does not bring its separators';
    my $kept = graft([ MOVE => 'a', [ 'NODE', 'b', 'x' ] ])->run({ a => 1, b => 2, c => 3 }, limits => { prop_per_obj => 2 });
    is show([ $kept->error->code, $kept->partial ]), '["INVALID_TARGET",{"a":1,"b":2,"c":3}]',
        'a pair that fails takes nothing away, whatever the limits';
    is $run->({}, { arr => [ { a => 1 } ] }, [ [ AT => [ 'NODE', 'arr', 0 ], [ SPLICE => $N, 1 ] ] ]), 'INVALID_TARGET',
        'SPLICE cannot remove the node it is working in';

    # common expressions whose names are computed
    my $p = { expr => [ p => [ HAS => [ [ [ SEQMAX => 'x', ['NUM'] ] ] ] ], d => [ 'NODE', 'b' ] ] };
    my $named = sub ($name) { [ COPY => $name, [ 'STASH', 'n' ] ] };
    is $run->($p, { a => [ 1, 2 ] }, [ $named->('p'), [ MATCH => { a => [ EXPR => [ 'STASH', 'n' ] ] }, [ COPY => ['CAP'], $N ] ] ]),
        '{"x":{"len":1,"lim":1,"ofs":0,"path":["a"]}}', 'one that captures does so by a computed name as by a literal one';
    is $run->($p, { a => [ [1], [2], [9] ] }, [ $named->('p'),
        [ MATCH => { a => [ [ [ SEQ => [ REP => 0, -1 ] ], [ EXPR => [ 'STASH', 'n' ] ], [ [9] ] ] ] }, [ COPY => [ 'CAP', 'x', 'path' ], $N ] ] ]),
        '["a",1]', 'and once only, where the match settles';
    is $run->($p, { a => 5, b => 5 }, [ $named->('d'), [ COPY => [ IS => [ 'NODE', 'a' ], [ EXPR => [ 'STASH', 'n' ] ] ], $N ] ]), 'true',
        'one that is a value is compared with, seen from the current node';
    is $run->({ expr => [ s => [ WITH => 'p', 'x', [ SEQMAX => [ CONCAT => [ 'TEMP', 'p' ], '1' ], ['REP'] ] ] ] }, [ 1, 2, 3 ],
        [ [ COPY => [ CAPTURE => [ [ [ EXPR => 's' ], [ SEQ => ['REP'] ] ] ] ], $N ] ]), '{"x1":{"len":3,"lim":3,"ofs":0,"path":[]}}',
        'a length preference is seen through WITH inside a definition';
    {
        local $SIG{ALRM} = sub { die "it did not finish\n" };
        alarm 20;
        is eval { $run->({ expr => [ a => [ WITH => 't', 1, [ EXPR => 'a' ] ] ] }, 1, [ [ MATCH => [ [ [ EXPR => 'a' ] ] ] ] ]) } // $@, 'NO_MATCH',
            'a definition that leads back to itself through WITH can be compiled';
        alarm 0;
    }
    is $run->({ expr => [ num => ['NUM'] ] }, 5000000, [ $yes->([ WITH => 'n', 'num', [ CHARS => [ EXPR => [ 'TEMP', 'n' ] ] ] ]) ]), 'false',
        'CHARS takes only another set by a computed name';

    # A sequence among the items of an array pattern does not change what the other items are.
    my $in = sub ($data, @items) { $run->({}, $data, [ $yes->([ \@items ]) ]) };
    is $in->([ 1, 2 ], [ NONE => 5 ], 2), 'true', 'NONE, as an item, is matched against one element';
    is $in->([ 1, 2 ], [ NONE => 5 ], 2, ['SEQ']), 'true', '... and is still, beside a sequence';
    is $in->([ 1, 2 ], [ NONE => 1 ], 2, ['SEQ']), 'false', '... which it has to match';
    is $in->([ 1, 2, 3 ], [ ANY => 1, 7 ], [ SEQ => ['REP'] ]), 'true', 'ANY, as an item, is one element that is any of them';
    is $in->([ 1, 2, 3 ], [ SEQ => ['REP'] ], [ ALL => ['NUM'], 3 ]), 'true', 'and ALL one element that is all of them';
    is $in->([ 1, 2 ], [ SEQ => [ NONE => 5 ], 1, 2 ]), 'true', 'inside the sequence, NONE takes no element, as before';
    is $in->([ 1, 2 ], [ SEQ => 1, 2 ], ['END']), 'true', 'an item is matched against the element that is not there at the end, as [END] is';
    is $in->([ 1, 2 ], [ SEQ => 1 ], ['END']), 'false', '... but only there';
    is $in->([1], 1, [ NONE => 5 ], ['SEQ']), 'true', 'what follows that can take no element, and may be a sequence of none';
    is $in->([1], 1, [ NONE => 5 ], [ SEQ => ['REP'] ]), 'true', '... or of any number, which is none';
    is $in->([1], 1, [ NONE => 5 ], [ NONE => 6 ], ['SEQ']), 'false', '... but not another item';
    is $run->({}, [ 1, 2 ], [ [ MATCH => [ IS => [ [ [ SEQ => 1 ], 2 ] ] ] ] ]), '[1,2]', 'IS wants every element used';
    is $run->({}, [ 1, 2, 3 ], [ [ MATCH => [ IS => [ [ [ SEQ => 1 ], 2 ] ] ] ] ]), 'NO_MATCH', '... and no more';
    is $run->({}, [ 1, 2 ], [ [ MATCH => [ IS => [ [ [ SEQ => 1 ], 2, [ NONE => 5 ] ] ] ] ] ]), '[1,2]', '... the place past the end being none of them';
    is $in->([ 1, 2 ], ['SEQ'], [ REP => 0, -1 ]), 'new: INVALID_GRAFT', 'REP belongs inside a sequence, not beside one';
    is $in->([ 1, 2 ], ['SEQ'], [ ANY => [ SEQ => 1, 2 ], 3 ]), 'new: INVALID_GRAFT', 'and a sequence cannot begin inside an item that is not one';
    is $run->({}, [ [ 9, 1 ], 5 ], [ [ MATCH => [ [ ['SEQ'], [ [ [ SEQMAX => 'x', 9 ], 1 ] ], 5 ] ], [ COPY => [ 'CAP', 'x', 'path' ], $N ] ] ]), '[0]',
        'captures inside such an item are found where it matched';

    # characters and sets
    is join(' ', map { $run->({}, $_, [ $yes->([ CHARS => $F ]) ]) } 65, 65.5, -5, 1e10), 'true false false false', 'only a code point is a character';
    is join(' ', map { $run->({}, 'axb', [ [ COPY => [ SPLIT => { sep => 'x', element => [ SEQ => ['REP'], [ NONE => $_ ] ] } ], $N ] ]) } 'x', 120, [ CHARS => 'x' ]),
        '["a","b"] ["a","b"] ["a","b"]', 'a character is the same however it is written';
    is join(' ', map { $run->({}, 'a,b,c', [ [ COPY => [ SPLIT => { sep => ',', element => $_ } ], $N ] ]) } [ SEQ => ['REP'], ['END'] ], [ SEQ => ['START'], ['REP'] ]),
        '["a","b","c"] ["a","b","c"]', 'START and END in the pattern for an element are its own ends';
    is $run->({}, 'a,b', [ [ COPY => [ SPLIT => { sep => ',', keep => "<\n" } ], $N ] ]), 'new: INVALID_GRAFT', 'keep is one of three characters exactly';

    # the same answer from Perl and from the closures
    my $both = sub ($in, $action) { join ' ', map { $run->({}, $in, [$action], @$_) } [], [ limits => { ops => 1e12 } ] };
    is $both->('x', $yes->([ STR => [ WITH => 'a', [ 'NODE', 'k' ], 'x' ] ])), 'false false', 'WITH fails if its value cannot be had, whatever its pattern';
    is $both->('aaa', $yes->([ STR => [ SEQ => ['START'], [ REP => 0, 1e20, 'a' ], ['END'] ] ])), 'true true', 'a limit too large for a regex is not written into one';
    is $run->({}, '  a,  b', [ [ COPY => [ SPLIT => { sep => ',', ltrim => [ REP => 0, 1e20, ' ' ], discard => $T } ], $N ] ]), '["a","b"]', 'nor into a trim';

    # limits and faults
    is $run->({}, [1e19], [ [ MATCH => [ [ [ SEQ => [ REP => $N ] ] ] ] ] ]), 'NO_MATCH', 'a count beyond any integer is only more than there are';
    is $run->({}, [1], [ [ MATCH => [ [ [ SEQ => [ REP => 3, 2 ] ] ] ] ] ]), 'new: INVALID_GRAFT', 'limits that are written wrongly are a fault';
    is $run->({}, {}, [ [ IF => [ 'NODE', 'go' ], [ COPY => 1, [ 'NODE', $T, [ 'NODE', 'k' ] ] ] ] ]), 'new: INVALID_GRAFT',
        'a path element that is written wrongly is a fault, though another beside it is computed';
    is $run->({}, { big => [ 1 .. 3000 ], list => [ 1 .. 300 ] }, [ [ COPY => [ 'NODE', 'big' ], [ 'STASH', 'big' ] ],
        [ COPY => [ LENGTH => [ FILTER => [ IS => [ 'STASH', 'big' ], [ 'STASH', 'big' ] ], [ 'NODE', 'list' ] ] ], $N ] ], limits => { ops => 5000 }),
        'RESOURCE_LIMIT', 'comparing data with data is counted';
    is $run->({}, [ (1) x 3000 ], [ $yes->([ IS => [ [ [ SEQ => ['REP'], ['NUM'], ['REP'] ] ] ] ]) ], limits => { ops => 40_000 }), 'true',
        '"anything, then this, then anything" costs in proportion to the array';
    is $run->({}, [ (0) x 3000 ], [ $yes->([ [ [ SEQ => ['REP'], ['REP'], ['REP'], 'no' ] ] ]) ], limits => { ops => 3000 }), 'RESOURCE_LIMIT',
        'and what it costs is counted';
    is $run->({}, 'a' x 3000, [ $yes->([ STR => [ REP => 1, -1, [ NUM => 97, 122 ] ] ]) ], limits => { ops => 20_000 }), 'true',
        'a search that only asks whether there is a match stops at the first';
    my $shared = JGraft->new([ JGRAFT => {}, [ COPY => [ LENGTH => [ REDUCE => [ [ [ 'TEMP', 'a' ], [ 'TEMP', 'a' ] ] ], 'a', 0, [ [ 1 .. 60 ] ] ] ], $N ] ]);
    is $shared->apply(0), 2, 'a constant that holds the same value in many places is made in proportion to what it holds';
};

subtest 'numbers and dates at their edges' => sub {
    # Each operand is read from the document, so that the run does the work.
    my $of = sub ($expr, $in, @opt) {
        my $r = graft([ COPY => $expr, ['NODE'] ])->run($in, @opt);
        $r->ok ? show($r->output) : $r->error->code;
    };
    my $two = sub ($op) { [ $op, [ 'NODE', 0 ], [ 'NODE', 1 ] ] };

    is $of->($two->('MOD'), $_->[0]), $_->[1], "MOD of @{ $_->[0] }" for
        [ [ 9007199254740995,     3 ]          => '2' ],              # a quotient no float can hold
        [ [ 9223372036854775807,  10 ]         => '7' ],
        [ [ -1000000000000000001, 1000000000 ] => '999999999' ],
        [ [ 1e22, 3 ]                          => '1' ],
        [ [ -7,   3 ]                          => '2' ],              # the sign is the divisor's
        [ [ 7,    -3 ]                         => '-2' ],
        [ [ -7.5, 2 ]                          => '0.5' ],
        [ [ 7.5,  -2 ]                         => '-0.5' ];
    isnt $of->($two->('MOD'), [ 1e308, 1e-308 ]), 'UNSUPPORTED_GRAFT', 'MOD does not overflow on the way to a small answer';

    is $of->([ CASTSTR => $two->('POW') ], $_->[0]), $_->[1], "POW of @{ $_->[0] } is exact" for
        [ [ 3,  34 ] => '"16677181699666569"' ],                      # past 2**53
        [ [ 7,  22 ] => '"3909821048582988049"' ],
        [ [ 2,  62 ] => '"4611686018427387904"' ],
        [ [ 10, 19 ] => '"10000000000000000000"' ],
        [ [ 2,  10 ] => '"1024"' ];
    is $of->([ MUL => [ 'NODE', 0 ], [ 'NODE', 1 ], [ 'NODE', 2 ] ], [ 1e200, 1e200, 0 ]), 'UNSUPPORTED_GRAFT',
        'a product that overflows on the way is out of range, whatever comes after';
    is $of->([ ADD => [ 'NODE', 0 ], [ 'NODE', 1 ], [ 'NODE', 2 ] ], [ 1e308, 1e308, -1e308 ]), 'UNSUPPORTED_GRAFT', 'and so is a sum';

    is $of->([ ROUND => { shift => 1e20 }, ['NODE'] ], 5), 'UNSUPPORTED_GRAFT', 'ROUND refuses a shift too large to count with';
    is $of->([ ROUND => { as => 'INT' } ], 18446744073709551615), '18446744073709551615', 'ROUND gives the widest integer as an integer';
    is $of->([ ROUND => { as => 'INT' } ], '18446744073709551616'), 'UNSUPPORTED_GRAFT', 'and refuses one wider';
    is $of->([ CASTSTR => ['ROUND'] ], 9223372036854775807), '"9223372036854775807"', 'an integer rounded to an integer is unchanged';
    is $of->([ LENGTH => [ ROUND => { as => $_, at => 3e7 }, ['NODE'] ] ], '1e-30000001', limits => { mem => 1000 }), 'RESOURCE_LIMIT',
        "ROUND as $_ is charged for the zeros it writes" for qw(STR SIG);

    my $date = sub ($v) { $of->([ CASTSTR => [ CASTDATE => ['NODE'] ] ], $v) };
    is $date->('2024-01-01T10:20:00.00001234'),  '"2024-01-01 10:20:00.00001234"', 'small fractions of a second are written out';
    is $date->('2024-01-01T10:20:00.0000001'),   '"2024-01-01 10:20:00.0000001"',  'however small';
    is $date->('2024-01-01T10:20:30.5Z'),        '"2024-01-01T10:20:30.5Z"',       'and others as before';
    is $date->('-0044-03-15'),                   '"-0044-03-15"',                  'a year before zero keeps its four digits';
    is $date->($date->('-0044-03-15') =~ s/"//gr), '"-0044-03-15"',                '... and can be read back';
    is $date->("2024-01-01T10:20:3\x{661}"),      'INVALID_TARGET',                 'only the digits 0 to 9 are digits';
    is $date->({ year => 1e300 }),               'INVALID_TARGET',                 'a year too large to count days from is no date';

    my @keep  = (date_export => sub ($d) { $d });
    my $dated = graft([ COPY => [ CASTDATE => '2024-01-01T10:00:00+01:00' ], 0 ])->apply([0], @keep);
    my $r     = graft([ COPY => [ CASTDATE => '2024-01-01T09:00:00Z' ], 0 ])->run($dated, @keep);
    is JGraft->new($r->undo)->apply($r->output, @keep)->[0]->str, '2024-01-01T10:00:00+0100',
        'undo puts back a timestamp that was replaced by the same moment in another zone';
    $dated = graft([ COPY => [ CASTDATE => '2024-01-01T10:20:00.00001234' ], 0 ])->apply([0], @keep);
    $r     = graft([ COPY => 1, 0 ])->run($dated, @keep);
    is JGraft->new($r->undo)->apply($r->output, @keep)->[0]->str, '2024-01-01 10:20:00.00001234', 'and one with a small fraction of a second';

    my $deep = my $at = {};
    $at = $at->{d} = {} for 1 .. 150;
    $at->{v} = 1;
    my @warned;
    {
        local $SIG{__WARN__} = sub { push @warned, @_ };
        my $run = graft([ COPY => 2, [ 'NODE', ('d') x 150, 'v' ] ])->run($deep);
        is show(JGraft->new($run->undo)->apply($run->output)), show($deep), 'undo reaches 150 levels down';
    }
    is "@warned", '', '... without a warning';
};

subtest 'JSON is written back as it was read' => sub {
    require JGraft::JSON;
    # The text after a run: of what it left, if it failed.
    my $edit = sub ($text, @actions) {
        my $doc = JGraft::JSON->parse($text);
        my $r   = graft(@actions)->run($doc->data);
        $doc->write($r->ok ? $r->output : $r->partial);
    };
    my $text = join "\n", '{', '  "name": "caf\u00e9",', '  "price": 1e1, "qty" : -0,  "big": 12345678901234567890123,',
        qq(  "tags": [ "a",\t"b\\/c" , 1.50 ],), '  "dup": 1, "nested": { "z": [1, 2.0, 3], "y": null }, "dup": 2,',
        qq{  "bad": "x\xffy\xc3(",}, '  "text": "line one\nline tw\u006f\nline three\n"', '}', '';
    my $doc = JGraft::JSON->parse($text);
    is $doc->write, $text, 'a text that is read and written is the same text';
    is $edit->($text, [ MATCH => { price => 10 } ]), $text, 'and so it is after a graft that changes nothing';
    is show([ keys %{ $doc->data } ]), '["name","price","qty","big","tags","dup","nested","bad","text"]', 'properties are in the order written';
    is $doc->data->{dup}, 2, 'a property written twice has the value given last';
    is length $doc->data->{bad}, 5, 'a byte that is not UTF-8 is one character';

    # What is written differs from what was read only where the data does.
    my $changes = sub ($name, $from, $to, @actions) {
        index($text, $from) >= 0 or die "the text has no '$from'";
        is $edit->($text, @actions), $text =~ s/\Q$from\E/$to/r, $name;
    };
    $changes->('a value changed', '1e1,', '11,', [ COPY => 11, 'price' ]);
    $changes->('a property added, as its neighbours are laid out', qq("\n}), qq(",\n  "added": "new"\n}), [ COPY => 'new', 'added' ]);
    $changes->('one removed', ' "qty" : -0, ', '', [ MOVE => 'qty', undef ]);
    $changes->('one renamed, where it was', '"qty" :', '"quantity" :', [ MOVE => 'qty', 'quantity' ]);
    $changes->('an element put in', qq("a",\t), qq("a",\t"in",\t), [ SPLICE => [ 'NODE', 'tags', 1 ], 0, 'in' ]);
    $changes->('an element taken out', ' , 1.50 ]', ' ]', [ SPLICE => [ 'NODE', 'tags', 2 ], 1 ]);
    $changes->('a change deep inside', '2.0', '5', [ COPY => 5, [ 'NODE', 'nested', 'z', 1 ] ]);
    $changes->('the value of a property written twice', '"dup": 2', '"dup": 3', [ COPY => 3, 'dup' ]);
    $changes->('one line of a string', 'line tw\u006f', 'LINE 2', [ ATSPLIT => 'text', "\n", [ COPY => 'LINE 2', 1 ] ]);
    $changes->('a string with bytes that are not UTF-8, added to', "\xc3(", "\xc3(!", [ COPY => [ CONCAT => [ 'NODE', 'bad' ], '!' ], 'bad' ]);
    $changes->('a value written over with its equal', '1e1', '1e1', [ COPY => 10, 'price' ]);
    is $edit->($text, [ MOVE => 'dup', undef ]), $text =~ s/"dup": 1, //r =~ s/, "dup": 2//r, 'a property written twice is removed twice';
    is $edit->($text, [ COPY => 11, 'price' ], [ MATCH => 0 ]), $text =~ s/1e1/11/r, 'after a failure, the text of what was left';

    # The order of properties is what the graft made of it.
    is $edit->('{"b":1,"a":2}', [ COPY => 1, 'z', 2, 'c', 3, 'a' ]), '{"b":1,"a":3,"z":1,"c":2}', 'new properties come last, in the order they were added';
    is $edit->('{"b":1,"a":2,"c":3}', [ MOVE => 'b', [ 'STASH', 's' ] ], [ MOVE => [ 'STASH', 's' ], 'b' ]), '{"a":2,"c":3,"b":1}',
        'one taken away and put back comes last';
    is $edit->('{"b":1, "a" : 2,"c":3}', [ MOVE => 'a', 'A' ]), '{"b":1, "A" : 2,"c":3}', 'one renamed stays where it was';
    is $edit->('{"b":1,"a":2}', [ MOVE => 'a', 't', 'b', 'a', 't', 'b' ]), '{"a":1,"b":2}', 'two that exchange names exchange them where they are';
    is $edit->('{"b":1,"a":2,"c":3}', [ MOVE => 'a', 'c' ]), '{"b":1,"c":2}', 'a name that is taken keeps its own place';
    is $edit->('{"x":1}', [ COPY => 1, [ 'NODE', 'p', 'z' ], 2, [ 'NODE', 'p', 'a' ] ]), '{"x":1,"p":{"z":1,"a":2}}', 'an object made on the way keeps order too';
    is $edit->('{"x":1}', [ COPY => [ MKOBJ => 'z', [ 'NODE', 'x' ], 'a', 2 ], 'o' ]), '{"x":1,"o":{"z":1,"a":2}}', 'MKOBJ gives the order of its arguments';
    my $ordered = JGraft::JSON->parse('["JGRAFT", {"v": 1}, ["COPY", {"z": 1, "a": ["NODE", "x"]}, "o"]]')->data;
    my $target  = JGraft::JSON->parse('{"x": 1e1}');
    is $target->write(JGraft->new($ordered)->apply($target->data)), '{"x": 1e1,"o": {"z":1,"a":1e1}}',
        'an object written in a graft that was itself read from text has the order written there';

    is $edit->('{"x":1}', [ COPY => [ MKOBJ => 'z', 1, 'a', 2 ], 'o' ]), '{"x":1,"o":{"z":1,"a":2}}', '... when they are all constants, too';
    is $edit->('{"b": 1, "a": 2}', [ COPY => [ CASTDATE => '2024-02-29' ], [ 'NODE', 'when' ] ], [ COPY => { z => [ CASTDATE => '2024-03-01' ], a => 1 }, 'o' ]),
        '{"b": 1, "a": 2, "when": "2024-02-29", "o": {"a":1,"z":"2024-03-01"}}', 'dates on their way out do not disturb it';
    my $undone = JGraft::JSON->parse('{"b": 1.0, "a": [1, 2]}');
    my $run    = graft([ MOVE => 'b', 'c' ], [ SPLICE => [ 'NODE', 'a', 0 ], 1 ])->run($undone->data);
    is $undone->write(JGraft->new($run->undo)->apply($run->output)), '{"a": [1, 2], "b": 1.0}',
        'an undo graft applies to such a document as to any other (what it puts back it writes anew, a number with the places it had)';
    my $plainly = JGraft::JSON->parse('{"b": 1.0, "a": [1, 2]}', exact => 0);
    $run = graft([ MOVE => 'b', 'c' ], [ SPLICE => [ 'NODE', 'a', 0 ], 1 ])->run($plainly->data);
    is $plainly->write(JGraft->new($run->undo)->apply($run->output)), '{"a": [1, 2], "b": 1}', '... which are not known if the text was read as Perl reads numbers';

    # A value that moves takes its spelling with it.
    is $edit->('{"x":1.50,"y":[]}', [ MOVE => 'x', [ 'NODE', 'y', 0 ] ]), '{"y":[1.50]}', 'a number moved';
    is $edit->('{"x":"\u0041\/","y":[]}', [ MOVE => 'x', [ 'STASH', 's' ] ], [ MOVE => [ 'STASH', 's' ], [ 'NODE', 'y', 0 ] ]), '{"y":["\u0041\/"]}',
        'a string moved by way of the stash';
    is $edit->('{"x":1.50,"y":[]}', [ COPY => [ 'NODE', 'x' ], [ 'NODE', 'y', 0 ], [ 'NODE', 'x' ], 'z' ]), '{"x":1.50,"y":[1.50],"z":1.50}', 'one copied by reference';
    is $edit->('[1.0, 2.00, "\u0041"]', [ SPLICE => 0, 0, [ 'NODE', 2 ], [ 'NODE', 1 ] ]), '["\u0041", 2.00, 1.0, 2.00, "\u0041"]', 'elements spliced in by reference';
    is $edit->('{"a":[1.0, 2e0, "x", 3.0]}', [ COPY => [ FILTER => ['NUM'], [ 'NODE', 'a' ] ], 'a' ]), '{"a":[1.0,2e0,3.0]}', 'what FILTER lets through';
    is $edit->('{"a":[1.0, 2e0, "\u0041"]}', [ COPY => [ CONCAT => [ SLICE => [ 'NODE', 'a' ], 1 ], [ 'NODE', 'a' ] ], 'b' ]),
        '{"a":[1.0, 2e0, "\u0041"],"b":[2e0,"\u0041",1.0,2e0,"\u0041"]}', 'what SLICE and CONCAT pass on';
    is $edit->('{"x":1.0}', [ COPY => { z => [ 'NODE', 'x' ], a => 2 }, 'o' ]), '{"x":1.0,"o":{"a":2,"z":1.0}}', 'a member of an object that is built';
    is $edit->('{"a": {"k": [1.0, 2]}}', [ MOVE => 'a', 'b' ], [ COPY => 3, [ 'NODE', 'b', 'k', 1 ] ]), '{"b": {"k": [1.0, 3]}}',
        'and what is moved and then changed keeps the rest of itself';
    is $edit->('{"a":1.0}', [ COPY => [ ADD => [ 'NODE', 'a' ], 1 ], 'a' ]), '{"a":2.0}', 'a value that is worked out is written to the places it is known to';
    is $edit->('{"a":1.0}', [ COPY => [ LENGTH => 'abc' ], 'a' ]), '{"a":3}', '... and plainly, if it has none';
    my ($one, $two) = map { JGraft::JSON->parse($_) } '{"from": [1.50, "\u0041"]}', '{"to": []}';
    is $two->write(graft([ COPY => [ 'TEMP', 'other', 'from', 0 ], [ 'NODE', 'to', 0 ], [ 'TEMP', 'other', 'from', 1 ], [ 'NODE', 'to', 1 ] ])
        ->apply($two->data, temp => { other => $one->data })), '{"to": [1.50,"\u0041"]}', 'even from one text to another';

    # Of a string that has changed, the parts that have not are as they were.
    is $edit->('{"t":"caf\u00e9 au lait\nsecond\/line"}', [ ATSPLIT => 't', ' ', [ COPY => 'AU', 1 ] ]), '{"t":"caf\u00e9 AU lait\nsecond\/line"}',
        'a word within a line';
    is $edit->('{"t":"\u0041bc"}', [ COPY => [ CONCAT => '<', [ 'NODE', 't' ], '>' ], 't' ]), '{"t":"<\u0041bc>"}', 'a string added to at both ends';
    is $edit->('{"t":"\u0041\nb\nc\/c\nd"}', [ ATSPLIT => 't', "\n", [ SPLICE => 1, 1 ], [ SPLICE => 2, 0, 'new' ] ]), '{"t":"\u0041\nc\/c\nnew\nd"}',
        'lines taken out and put in';
    is $edit->('["\ud83d\ude00 \ud800 x"]', [ COPY => [ CONCAT => [ 'NODE', 0 ], '!' ], 0 ]), '["\ud83d\ude00 \ud800 x!"]', 'escapes for one character and for half of one';
    is JGraft::JSON->encode("\x{1F600} \x{D800} \x{e9}\n\"\x01" . chr 0x1100FF), qq("\xF0\x9F\x98\x80 \\ud800 \xC3\xA9\\n\\"\\u0001\xFF"),
        'what is written anew is UTF-8, with escapes only where JSON needs them';

    # ... however long the string, and wherever in a line the changes are.
    my $long   = join ' ', map { "w\\u006frd$_" } 1 .. 20_000;         # 240,000 characters in one line, an escape in every word
    my $edited = $edit->(qq({"t":"$long"}), [ COPY => [ CONCAT => '<', [ SLICE => [ 'NODE', 't' ], 0, 100_000 ], '#', [ SLICE => [ 'NODE', 't' ], 100_001 ], '>' ], 't' ]);
    is length($edited), length($long) + 10, 'three changes to a long line change three places in it';
    is scalar(() = $edited =~ /\\u006f/g), 20_000, 'and every escape in the rest of it is still there';
    # The comparison itself, against the textbook table for the longest common subsequence.
    my $longest = sub ($a, $b) {
        my @t = map { [ (0) x (length($b) + 1) ] } 0 .. length $a;
        for my $i (1 .. length $a) {
            for my $j (1 .. length $b) {
                my ($up, $left) = ($t[ $i - 1 ][$j], $t[$i][ $j - 1 ]);
                $t[$i][$j] = substr($a, $i - 1, 1) eq substr($b, $j - 1, 1) ? $t[ $i - 1 ][ $j - 1 ] + 1 : $up > $left ? $up : $left;
            }
        }
        $t[-1][-1];
    };
    srand 4;
    my @letter = ('a', 'b', "\n", "\x{e9}", "\x{1F600}", chr 0x1100FF);
    my %bad    = (unsound => 0, 'not the least' => 0, agree => 0);
    for (1 .. 1500) {
        my $letters = 1 + int rand(rand() < .5 ? 2 : 6);
        my $was     = join '', map { $letter[ rand $letters ] } 1 .. rand 14;
        my $now     = rand() < .5 ? join('', map { $letter[ rand $letters ] } 1 .. rand 14) : $was;
        if ($now eq $was) { rand() < .5 ? substr($now, rand(length($now) + 1), 1, '') : substr($now, rand(length($now) + 1), 0, $letter[ rand $letters ]) for 1 .. rand 4 }
        my @part = JGraft::JSON::differences($now, $was);
        my ($built, $done, $size) = ('', 0, 0);
        for (@part) {
            my ($i, $n, $j, $m) = @$_;
            $built .= substr($was, $done, $j - $done) . substr($now, $i, $n);
            ($done, $size) = ($j + $m, $size + $n + $m);
        }
        $bad{unsound}++ if $built . substr($was, $done) ne $now;
        $bad{'not the least'}++ if $size != length($now) + length($was) - 2 * $longest->($now, $was);
        my ($x, $y, $want) = (int rand(length($now) + 1), int rand(length($was) + 1), 0);
        $want++ while $x + $want < length $now && $y + $want < length $was && substr($now, $x + $want, 1) eq substr($was, $y + $want, 1);
        $bad{agree}++ if JGraft::JSON::agree($now, $x, $was, $y) != $want;
    }
    is show(\%bad), '{"agree":0,"not the least":0,"unsound":0}', 'two strings are compared soundly, and for the least change between them';

    # Bytes that are not UTF-8 are kept, each as a character of its own beyond Unicode.  The
    # characters used for that are reserved: bytes that spell one of them, or any code point
    # past the last of Unicode, are not UTF-8 either, so no text can be mistaken for another.
    my %stray = (
        'a code point in the reserved range (U+110081)' => "\xF4\x90\x82\x81",
        'the last of the reserved range (U+1100FF)'     => "\xF4\x90\x83\xBF",
        'one just past it'                              => "\xF4\x90\x84\x80",
        'a five-byte form'                              => "\xF8\x88\x80\x80\x80",
        'the long form that only Perl has'              => "\xFF\x80\x80\x80\x80\x80\x80\x81\x80\x80\x80\x80\x80",
        'a surrogate'                                   => "\xED\xA0\x80",
        'an overlong form'                              => "\xC0\x80",
        'a continuation byte with nothing to continue'  => "\x80",
        'a character cut short'                         => "\xE2\x82",
    );
    for my $what (sort keys %stray) {
        my $bytes = $stray{$what};
        my $text  = qq({"s":"a${bytes}b"});
        my $read  = JGraft::JSON->parse($text);
        is join(' ', map { sprintf '%X', ord } split //, substr $read->data->{s}, 1, -1), join(' ', map { sprintf '%X', 0x110000 + ord } split //, $bytes),
            "bytes that spell $what are read one by one";
        is $read->write, $text, '... and written back';
        is $edit->($text, [ COPY => [ CONCAT => [ SLICE => [ 'NODE', 's' ], 1 ], [ SLICE => [ 'NODE', 's' ], 0, 1 ] ], 's' ]), qq({"s":"${bytes}ba"}),
            '... wherever a graft puts them';
    }
    is JGraft::JSON->encode('a' . chr(0x110080) . chr(0x1100FF)), qq("a\x80\xFF"), 'a reserved character is written as its byte';
    ok !eval { JGraft::JSON->encode('a' . chr $_); 1 } && $@ =~ /which JSON cannot say/, sprintf 'any other character past Unicode (0x%X) cannot be written', $_
        for 0x110000, 0x110041, 0x11007F, 0x110100, 0x7FFFFFFF;

    # Stray bytes that a graft brings together are the character they then spell: as when
    # the two halves of a character that something had cut in two are joined again.
    my $rejoin = sub ($text, @actions) {
        my $read = JGraft::JSON->parse($text);
        my $left = graft(@actions)->apply($read->data);
        my $out  = $read->write($left);
        return 'what is written is not what the run left' if show(JGraft::JSON->parse($out)->data) ne show($left);
        return join ' ', map { sprintf '%X', ord } split //, $left->{c};
    };
    my $concat = [ COPY => [ CONCAT => [ 'NODE', 'a' ], [ 'NODE', 'b' ] ], 'c' ];
    is $rejoin->(qq({"a":"x\xC3","b":"\xA9y"}), $concat), '78 E9 79', 'two bytes of one character';
    is $rejoin->(qq({"a":"\xE2\x82","b":"\xAC"}), $concat), '20AC', 'three, cut after the second';
    is $rejoin->(qq({"a":"\xF0","b":"\x9F\x98\x80"}), $concat), '1F600', 'four, cut after the first';
    is $rejoin->(qq({"a":"\xF0\x9F","b":"\x98","z":"\x80"}), [ COPY => [ CONCAT => [ 'NODE', 'a' ], [ 'NODE', 'b' ], [ 'NODE', 'z' ] ], 'c' ]), '1F600',
        'four, in three pieces';
    is $rejoin->(qq({"a":"\xC3","b":"\xA9\xA9"}), $concat), 'E9 1100A9', 'with a byte left over';
    is $rejoin->(qq({"a":"\x80\xFF\xC3","b":"\xA9\xFE\x80"}), $concat), '110080 1100FF E9 1100FE 110080', 'with stray bytes before and after that stay as they are';
    is $rejoin->(qq({"a":"\xE2\x82\xC3","b":"\xA9"}), $concat), '1100E2 110082 E9', 'after a character that is still cut short';
    is $rejoin->(qq({"a":"\xC3","b":"\xA9\x80\xF0\x9F","z":"\x98\x80\xBF"}), [ COPY => [ CONCAT => [ 'NODE', 'a' ], [ 'NODE', 'b' ], [ 'NODE', 'z' ] ], 'c' ]),
        'E9 110080 1F600 1100BF', 'two characters in one run of bytes, and the bytes between and after';
    is $rejoin->(qq({"a":"\xC3\xC3","b":"\xA9"}), $concat), '1100C3 E9', 'a lead byte takes only its own continuation';
    is $rejoin->(qq({"a":"\xC3","b":"\xFF"}), $concat), '1100C3 1100FF', 'but not bytes that spell nothing';
    is $rejoin->(qq({"a":"\xE2\x82","b":"y"}), $concat), '1100E2 110082 79', 'nor a character still cut short';
    is $rejoin->(qq({"a":"\xC0","b":"\x80"}), $concat), '1100C0 110080', 'nor an overlong form';
    is $rejoin->(qq({"a":"x\xC3,\xA9y"}), [ COPY => [ JOIN => ',', [ SPLIT => ',', [ 'NODE', 'a' ] ] ], 'c' ]),
        '78 1100C3 2C 1100A9 79', 'a JOIN that puts back what was between them leaves them apart';
    is $rejoin->(qq({"a":"x\xC3,\xA9y"}), [ COPY => [ JOIN => '', [ SPLIT => ',', [ 'NODE', 'a' ] ] ], 'c' ]), '78 E9 79', 'and one that does not brings them together';
    is $rejoin->(qq({"c":"x\xC3,\xA9y"}), [ ATSPLIT => 'c', { sep => [ ANY => ',' ], default => '' }, [ COPY => [ [ ['NODE', 0], ['NODE', 1] ] ], [ 'STASH', 'p' ] ] ],
        [ COPY => [ CONCAT => [ 'STASH', 'p', 0 ], [ 'STASH', 'p', 1 ] ], 'c' ]), '78 E9 79', 'pieces taken from an ATSPLIT and joined';

    # Containers that are emptied, or were empty; and documents that are not containers.
    is $edit->('{"a":[ ],"b":{ }}', [ COPY => 1, [ 'NODE', 'a', 0 ], 2, [ 'NODE', 'b', 'k' ] ]), '{"a":[1],"b":{"k":2}}', 'empty containers filled';
    is $edit->('{"a":[ 1 ],"b":{ "k": 1 }}', [ SPLICE => [ 'NODE', 'a', 0 ], 1 ], [ MOVE => [ 'NODE', 'b', 'k' ], undef ]), '{"a":[],"b":{}}', 'and full ones emptied';
    is $edit->(" 1e1\n", [ MATCH => 10 ]), " 1e1\n", 'a document that is one number';
    is $edit->(" 1e1\n", [ COPY => [ ADD => ['NODE'], 1 ], ['NODE'] ]), " 11\n", '... changed';
    is $edit->(' [1.0] ', [ COPY => { was => ['NODE'] }, ['NODE'] ]), ' {"was":[1.0]} ', 'a document replaced by one that holds it';

    # What cannot be read is refused, with the place.
    for ([ '{"a":1,}' => 'expected the name of a property at byte 7' ], [ '[1 2]' => 'expected , or ] at byte 3' ], [ '"\q"' => 'an escape that means nothing' ],
         [ '{"a":1} x' => 'something after the value at byte 8' ], [ '' => 'expected a value at byte 0' ]) {
        my ($bad, $why) = @$_;
        ok !eval { JGraft::JSON->parse($bad); 1 } && $@ =~ /\Q$why\E/, "'$bad' is not JSON: $why";
    }

    # Random texts, laid out at random, and a random change to each.
    srand 9;
    my @space  = ('', '', ' ', "\n  ", "\t");
    my $sp     = sub { $space[ rand @space ] };
    my @scalar = ('1', '1.0', '1e0', '-0', '1e1', '0.5', '"a"', '"\u0061"', '"b\/c"', '"line\none\n"', '"\ud83d\ude00"', qq("x\xff"), 'true', 'null', '""');
    my $random;
    $random = sub ($depth) {
        my $kind = rand;
        return $scalar[ rand @scalar ] if $depth > 2 || $kind < .5;
        return '[' . $sp->() . join($sp->() . ',' . $sp->(), map { $random->($depth + 1) } 1 .. rand 5) . $sp->() . ']' if $kind < .75;
        return '{' . $sp->() . join($sp->() . ',' . $sp->(), map { '"' . ('a' .. 'f', 'a')[ rand 7 ] . '"' . $sp->() . ':' . $sp->() . $random->($depth + 1) } 1 .. rand 5) . $sp->() . '}';
    };
    my %count = (identical => 0, written => 0, wrong => 0);
    for (1 .. 2000) {
        my $source = $sp->() . $random->(0) . $sp->();
        my $read   = JGraft::JSON->parse($source);
        $count{identical}++ if $read->write eq $source;
        my ($at, @path) = ($read->data);
        while ((ref $at eq 'ARRAY' || ref $at eq 'HASH') && rand() < .7) {
            my @key = ref $at eq 'ARRAY' ? 0 .. $#$at : keys %$at or last;
            push @path, ref $at eq 'ARRAY' ? 0 + $key[ rand @key ] : $key[ rand @key ];
            $at = ref $at eq 'ARRAY' ? $at->[ $path[-1] ] : $at->{ $path[-1] };
        }
        next unless ref $read->data eq 'ARRAY' || ref $read->data eq 'HASH';
        my $new    = (7, 'new', [ [ 1, 'x' ] ], { k => 1 }, undef)[ rand 5 ];
        my $action = ([ COPY => $new, [ NODE => @path, 'zz' ] ], [ COPY => $new, [ NODE => @path ] ], [ MOVE => [ NODE => @path ], 'moved' ],
            [ MOVE => [ NODE => @path ], undef ], [ SPLICE => [ NODE => @path, 0 ], 0, 'in' ], [ MOVE => [ NODE => @path ], [ NODE => @path[ 0 .. $#path - 1 ], 'renamed' ] ],
            [ COPY => [ NODE => @path ], 'copy' ])[ rand 7 ];
        my $r    = graft($action)->run($read->data);
        my $left = $r->ok ? $r->output : $r->partial;
        $count{written}++;
        my $again = eval { JGraft::JSON->parse($read->write($left))->data };
        $count{wrong}++ unless !$@ && JGraft::Util::match_lit($again, $left, 1) && JGraft::Util::match_lit($left, $again, 1)
            && JGraft::JSON->encode($again) eq JGraft::JSON->encode($left);
    }
    is $count{identical}, 2000, 'every one of 2,000 random texts is written as it was read';
    is $count{wrong}, 0, "and after a random change each says what the run left ($count{written} of them)";
};

subtest 'numbers that are exact' => sub {
    require Math::BigInt;
    require Math::BigFloat;
    # A graft applied to a text read with its numbers exact, and the text written back.
    my $on = sub ($text, @actions) {
        my $doc = JGraft::JSON->parse($text, exact => 1);
        my $r   = JGraft->new([ JGRAFT => {}, @actions ])->run($doc->data);
        return $r->ok ? $doc->write($r->output) : $r->error->code;
    };
    my ($A, $B) = ([ NODE => 'a' ], [ NODE => 'b' ]);
    my $calc = sub ($a, $b, $expr) { $on->(qq({"a":$a,"b":$b}), [ COPY => $expr, ['NODE'] ]) };

    is $calc->('0.1', '0.2', [ ADD => $A, $B ]), '0.3', 'a tenth and two tenths are three tenths';
    ok JGraft->new([ JGRAFT => {}, [ COPY => [ ADD => $A, $B ], ['NODE'] ] ])->apply({ a => 0.1, b => 0.2 }) != 0.3, '... which they are not, in arithmetic that is not exact';
    is $calc->('19.99', '3', [ MUL => $A, $B ]), '59.97', 'a price three times';
    is $calc->('0.10', '0.20', [ ADD => $A, $B ]), '0.30', 'a sum is known to as many places as its terms';
    is $calc->('0.10', '0.2', [ ADD => $A, $B ]), '0.30', '... as the finer of them';
    is $calc->('0.30', '0.30', [ SUB => $A, $B ]), '0.00', '... even if it is nothing';
    is $calc->('1.50', '2.0', [ MUL => $A, $B ]), '3.000', 'a product to as many as its factors together';
    is $calc->('6.0', '2', [ DIV => $A, $B ]), '3.0', 'a quotient that ends keeps the places of what was divided';
    is $calc->('1', '4', [ DIV => $A, $B ]), '0.25', '... and has those it needs';
    is $calc->('1', '1024', [ DIV => $A, $B ]), '0.0009765625', '... all of them';
    is $calc->('1', '3', [ DIV => $A, $B ]), '0.' . '3' x 34, 'one that does not end is written with thirty-four digits';
    is $calc->('2', '-3', [ DIV => $A, $B ]), '-0.' . '6' x 33 . '7', '... the last of them rounded';
    {
        local $JGraft::Number::DIGITS = 10;
        is $calc->('1', '7', [ DIV => $A, $B ]), '0.1428571429', '... or with as many as are asked for';
    }
    # But it is not those digits.  It is the fraction, until it is written.
    is $calc->('1', '3', [ MUL => [ DIV => $A, $B ], $B ]), '1', 'a third, three times, is one';
    is $calc->('1.00', '3', [ MUL => [ DIV => $A, $B ], $B ]), '1.00', '... to the places it started with';
    is $calc->('10', '3', [ MUL => [ DIV => $A, $B ], 0.9 ]), '3.0', 'ten thirds of nine tenths are three';
    is $calc->('1', '3', [ ADD => [ DIV => $A, $B ], [ DIV => 1, 6 ] ]), '0.5', 'a third and a sixth are a half';
    is $calc->('1', '3', [ SUB => [ DIV => $A, $B ], [ DIV => 2, 6 ] ]), '0', 'a third less two sixths is nothing';
    is $calc->('1', '3', [ DIV => [ DIV => $A, $B ], [ DIV => 2, 3 ] ]), '0.5', 'a third of two thirds... is a half of it';
    is $calc->('1', '3', [ POW => [ DIV => $A, $B ], -2 ]), '9', 'a third to the power -2 is nine';
    is $calc->('7', '3', [ MOD => $A, [ DIV => 1, $B ] ]), '0', 'seven is a whole number of thirds';
    is $calc->('1', '3', [ MOD => [ DIV => $A, $B ], 0.25 ]), '0.08' . '3' x 33, 'and a third leaves a twelfth over a quarter';
    is $calc->('1', '3', [ CASE => [ IS => [ DIV => $A, $B ], [ DIV => 2, 6 ] ], 'equal', 'not' ]), '"equal"', 'a third is two sixths';
    is $calc->('1', '3', [ CASE => [ IS => [ DIV => $A, $B ], [ CASTNUM => '0.' . '3' x 34 ] ], 'equal', 'not' ]), '"not"', '... and is not the digits it is written with';
    is $calc->('1', '3', [ CASE => [ IS => [ LESS => 0.3333, [ DIV => $A, $B ] ], $JGraft::Util::TRUE ], 'more', 'not' ]), '"more"', '... but more than any fewer of them';
    is $calc->('1e400', '3', [ MUL => [ DIV => $A, $B ], $B ]), '1e+400', 'a third of a number beyond Perl\'s range, and back';
    is $calc->('1e1000000000000', '3', [ DIV => $A, $B ]), 'UNSUPPORTED_GRAFT', '... unless there are more zeros to it than can be written';
    is $calc->('1', '3', [ CASTSTR => [ DIV => $A, $B ] ]), '"0.' . '3' x 34 . '"', 'CASTSTR writes what would be written';
    is $calc->('2', '3', [ ROUND => { at => 2 }, [ DIV => $A, $B ] ]), '0.67', 'and ROUND rounds it';
    # As it is written in school.
    my $school = sub ($a, $b) { JGraft->new([ JGRAFT => {}, [ COPY => [ DIV => $a, $b ], ['NODE'] ] ])->apply(undef, exact => 1)->repeating };
    is join(' ', map { $school->(@$_) } [ 1, 3 ], [ 1, 6 ], [ 1, 7 ], [ -22, 7 ], [ 1, 12 ], [ 100, 3 ], [ 1, 300 ]), '0.(3) 0.1(6) 0.(142857) -3.(142857) 0.08(3) 33.(3) 0.00(3)',
        'a fraction can be had with the digits that repeat marked';
    is length $school->(1, 97), length('0.()') + 96, '... all ninety-six of them, for a ninety-seventh';
    is $school->(1, 65537), undef, '... but not sixty-five thousand';
    is JGraft::Number::read('0.30')->repeating, '0.30', 'a number that ends is written as ever';
    is $calc->('7', '0', [ DIV => $A, $B ]), 'INVALID_TARGET', 'nothing is divided by zero';
    is $calc->('7.5', '-2', [ MOD => $A, $B ]), '-0.5', 'a remainder takes the sign of the divisor';
    is $calc->('1e30', '7', [ MOD => $A, $B ]), '1', '... and is right however large the number';
    is $calc->('12345678901234567890123', '1', [ ADD => $A, $B ]), '12345678901234567890124', 'an integer longer than Perl holds is added to';
    is $calc->('123456789012', '123456789012', [ MUL => $A, $B ]), '15241578753153483936144', 'and a product that outgrows Perl is whole';
    is $calc->('9223372036854775807', '1', [ ADD => $A, $B ]), '9223372036854775808', 'as is a sum that only just does';
    is $calc->('2', '100', [ POW => $A, $B ]), '1267650600228229401496703205376', 'a power is exact';
    is $calc->('0.5', '3', [ POW => $A, $B ]), '0.125', '... of a fraction too';
    is $calc->('2', '-2', [ POW => $A, $B ]), '0.25', '... and a negative one is its inverse';
    is $calc->('10', '1000000000000', [ POW => $A, $B ]), '1e+1000000000000', 'a power of ten costs nothing, however great';
    is $calc->('7', '1000000000000', [ POW => $A, $B ]), 'UNSUPPORTED_GRAFT', '... but a number of a billion digits is not attempted';
    is $calc->('1e400', '2', [ MUL => $A, $B ]), '2e+400', 'a number beyond the range of Perl is one like any other';
    is $calc->('1e-400', '1e-400', [ ADD => $A, $B ]), '2e-400', '... a small one too';
    is length $calc->('1e400', '1', [ ADD => $A, $B ]), 401, '... and adding one to it writes every digit';
    is $calc->('1e1000000000000', '1', [ ADD => $A, $B ]), 'UNSUPPORTED_GRAFT', '... unless there are too many to write';
    is $calc->('2', '0.5', [ POW => $A, $B ]) =~ /^1\.41421356\d+$/ ? 'a float' : 'not', 'a float', 'a root is no more exact than Perl makes it';
    is $calc->('1000', '10', [ LOG => $B, $A ]), '3', 'nor a logarithm, though it is whole where it should be';

    # The result is a number of Perl's own wherever that says as much, and an object only where it would not.
    my $made = sub ($expr, %opt) { JGraft->new([ JGRAFT => {}, [ COPY => $expr, ['NODE'] ] ])->apply(undef, exact => 1, %opt) };
    ok !ref $made->([ ADD => 0.1, 0.2 ]) && $made->([ ADD => 0.1, 0.2 ]) == 0.3, 'three tenths is a number of Perl\'s own';
    ok !ref $made->([ ADD => 2, 3 ]) && !ref $made->([ MUL => 1.5, 1.5 ]) && !ref $made->([ DIV => 7, 2 ]), 'so is what Perl would have got right';
    my $third = $made->([ DIV => 1, 3 ]);
    is ref $third, 'JGraft::Number', 'a third is not: it is an object';
    is "$third", '0.' . '3' x 34, '... which reads as the number';
    ok $third < 0.34 && $third > 0.33 && abs($third * 3 - 1) < 1e-15 && $third == $made->([ DIV => 2, 6 ]), '... and can be compared and calculated with, as Perl does';
    is ref $made->([ POW => 2, 64 ]), 'JGraft::Number', 'an integer that Perl does not hold is one';
    ok !ref $made->([ SUB => [ POW => 2, 64 ], 1 ]), 'and the widest that it does is not';
    is ref $made->([ CASTNUM => '1.50' ]), 'JGraft::Number', 'a number known to a place that Perl would drop is one';
    is $made->([ CASTSTR => [ ADD => [ CASTNUM => '1.50' ], 1 ] ]), '2.50', '... and the place is kept';
    ok !ref $made->([ CASTNUM => '1.5' ]), 'one that Perl says as well is not';
    is JGraft->new([ JGRAFT => {}, [ COPY => [ CASTNUM => '1.50' ], ['NODE'] ] ])->apply(undef), 1.5, 'unless asked, CASTNUM gives Perl\'s number';
    is JGraft->new([ JGRAFT => {}, [ COPY => [ CASTNUM => '1e400' ], ['NODE'] ] ])->run(undef)->error->code, 'UNSUPPORTED_GRAFT', '... and refuses what Perl cannot hold';
    is $made->([ CASTSTR => [ CASTNUM => '1e400' ] ]), '1e+400', 'which an exact run does not';

    # It is Perl's own number if and only if Perl writes that number as the same digits; and
    # then nothing is lost by it, for an exact run reads the number back as those digits.
    for my $text (qw(0.3 12345678901234.5 1e25 1.5e300 1e-300 1e-7 18446744073709551615 -2.5 100)) {
        my $n = JGraft::Number::read($text);
        ok !ref $n && join('e', JGraft::Number::scan("$n")) eq join('e', JGraft::Number::scan($text))
            && join('e', JGraft::Number::scan(JSON::PP->new->allow_nonref->encode($n))) eq join('e', JGraft::Number::scan($text)),
            "$text is Perl's own number, which Perl and JSON::PP write as the same";
    }
    is ref JGraft::Number::read($_), 'JGraft::Number', "$_ is not, for Perl would write it otherwise"
        for qw(0.30 0.30000000000000004 123456789012345.6 18446744073709551616 5e-324 1e400 100e-2);
    my $chain = sub ($expr, %opt) { JGraft->new([ JGRAFT => {}, [ COPY => $expr, ['NODE'] ] ])->apply([ 0.1, 0.2, 0.3 ], %opt) };
    my $tenths  = [ ADD => [ NODE => 0 ], [ NODE => 1 ] ];
    ok $chain->([ IS => $tenths, [ NODE => 2 ] ], exact => 1), 'a tenth and two tenths, exact, are the three tenths in the data';
    ok !$chain->([ IS => $tenths, [ NODE => 2 ] ]), '... which in Perl\'s arithmetic they are not';
    my $ten = $chain->([ ADD => (0.1) x 10 ], exact => 1);
    ok $ten == 1 && "$ten" eq '1.0', 'ten tenths are one (known to the tenth, and so 1.0)';
    ok $chain->([ ADD => (0.1) x 10 ]) != 1, '... which in Perl\'s arithmetic they are not either';
    my $went = $chain->([ SUB => [ MUL => [ ADD => $tenths, 0.61 ], 3 ], 0.01 ], exact => 1);
    ok !ref $went && "$went" eq '2.72', 'a calculation that goes on from a number of Perl\'s own goes on exactly';
    my $first = JGraft->new([ JGRAFT => {}, [ COPY => $tenths, 2 ] ])->apply([ 0.1, 0.2, 0 ], exact => 1);
    ok !ref $first->[2] && JGraft->new([ JGRAFT => {}, [ COPY => [ IS => [ ADD => [ NODE => 2 ], 0.6 ], 0.9 ], ['NODE'] ] ])->apply($first, exact => 1),
        '... in another run too, to which it was handed as plain data';
    is ref $chain->([ ADD => [ CASTNUM => '0.30000000000000004' ], 0 ], exact => 1), 'JGraft::Number', 'more digits than Perl writes are kept as they are';

    # One of Perl's numbers is, in exact arithmetic, the decimal that Perl writes: never the
    # binary number that Perl holds, whose error would otherwise be part of the result.
    my ($near3, $near03) = (1.5 + 1.5000000000000004, 0.1 + 0.2);
    ok $near3 != 3 && "$near3" eq '3' && $near03 != 0.3 && "$near03" eq '0.3', '(two numbers that are not what Perl writes them as)';
    my $from = sub ($expr) {
        my $v = JGraft->new([ JGRAFT => {}, [ COPY => $expr, ['NODE'] ] ])->apply([ $near3, $near03 ], exact => 1);
        return (ref $v ? 'object ' : '') . sprintf '%s, held as %.17g', $v, $v;
    };
    my ($N3, $N03) = ([ NODE => 0 ], [ NODE => 1 ]);
    is $from->([ ADD => $N03, 0.6 ]), sprintf('0.9, held as %.17g', 0.9), 'a sum takes a number for what Perl writes';
    is $from->([ ADD => $N03 ]), sprintf('0.3, held as %.17g', 0.3), '... even a sum of the one number';
    is $from->([ ADD => $N3, $N3 ]), '6, held as 6', 'so do whole numbers, which go a shorter way';
    is $from->([ MUL => $N3, 1e15 ]), '3000000000000000, held as 3000000000000000', '... in a product';
    is $from->([ MOD => 7, $N3 ]), '1, held as 1', '... a remainder';
    is $from->([ POW => 2, $N3 ]), '8, held as 8', '... and a power';
    is $from->([ DIV => 1e15, 3 ]), 'object 333333333333333.' . '3' x 19 . ', held as 333333333333333.31', 'a quotient that Perl would write as whole, and is not, is not taken for whole';
    ok JGraft->new([ JGRAFT => {}, [ COPY => [ IS => [ CASTNUM => '0.30' ], ['NODE'] ], ['NODE'] ] ])->apply($near03, exact => 1),
        'and an exact number is compared with what Perl writes';

    # And so two of Perl's numbers are compared, in an exact run, as what Perl writes them as:
    # though neither is an exact number, each stands for one.
    my @held = ($near03, 0.3, $near03 + $near03, 0.6);
    ok $held[0] != $held[1] && $held[2] != $held[3], '(two pairs of numbers that Perl holds to be different, and writes the same)';
    my $asks = sub ($expr, %opt) {
        my $v = JGraft->new([ JGRAFT => {}, [ COPY => $expr, ['NODE'] ] ])->apply(\@held, %opt);
        return ref $v eq 'JSON::PP::Boolean' ? ($v ? 'true' : 'false') : $v;
    };
    my @n = map { [ NODE => $_ ] } 0 .. 3;
    for (
        [ 'a number that binary arithmetic left near 0.3 is 0.3',      [ IS => $n[0], $n[1] ],                              'true',  'false' ],
        [ '... matched against one written in the graft',              [ IS => $n[0], 0.3 ],                                'true',  'false' ],
        [ '... or inside a pattern',                                   [ CASE => [ [ 0.3, 0.3 ] ], 'yes', 'no' ],           'yes',   'no' ],
        [ '... or inside a value that is compared whole',              [ IS => [ SLICE => ['NODE'], 0, 2 ], [ [ 0.3, 0.3 ] ] ], 'true', 'false' ],
        [ 'two of them added are the 0.6 in the data',                 [ IS => [ ADD => $n[0], $n[0] ], $n[3] ],            'true',  'false' ],
        [ '... as is the sum that Perl had made of them',              [ IS => $n[2], $n[3] ],                              'true',  'false' ],
        [ 'it is not more than 0.3',                                   [ LESS => $n[1], $n[0] ],                            'false', 'true' ],
        [ '... but no less',                                           [ LESSEQ => $n[0], $n[1] ],                          'true',  'false' ],
        [ '... and within a bound of 0.3',                             [ CASE => [ [ [ NUM => 0, 0.3 ] ] ], 'in', 'out' ], 'in',    'out' ],
        [ 'what was different is different still',                     [ IS => $n[1], $n[3] ],                              'false', 'false' ],
    ) {
        my ($name, $expr, $exact, $not) = @$_;
        is $asks->($expr, exact => 1), $exact, $name;
        is $asks->($expr), $not, '    (and not so in a run that is not exact)';
    }
    my $either = JGraft->new([ JGRAFT => {}, [ COPY => [ IS => 0.30000000000000004, 0.3 ], ['NODE'] ] ]);
    is join(' ', map { $_ ? 'true' : 'false' } $either->apply(undef, exact => 1), $either->apply(undef), $either->apply(undef, exact => 1)), 'true false true',
        'a comparison written in the graft is each run\'s own to make';
    ok !$JGraft::Number::EXACT, 'and when no run is under way, numbers are compared as Perl compares them';

    # An index or a count may be the result of arithmetic, and is as whole as that arithmetic is exact.
    my $at = sub ($index, %opt) {
        my $r = JGraft->new([ JGRAFT => {}, [ COPY => [ NODE => 'list', $index ], ['NODE'] ] ])->run({ list => [ 'a' .. 'h' ], n => 10 }, %opt);
        return $r->ok ? $r->output : $r->error->code;
    };
    is $at->([ MUL => [ ADD => 0.1, 0.2 ], 10 ], exact => 1), 'd', 'three tenths ten times is the index 3';
    is $at->([ MUL => [ ADD => 0.1, 0.2 ], 10 ]), 'INVALID_OPERAND', '... which in Perl\'s arithmetic it is not quite';
    is $at->([ MUL => [ DIV => [ NODE => 'n' ], 4 ], 2 ], exact => 1), 'f', 'so is a quotient that ends, multiplied up again';
    is $at->([ SUB => [ LENGTH => [ NODE => 'list' ] ], 1 ], exact => 1), 'h', 'and whole-number arithmetic, as ever';
    is $at->([ POW => 27, [ DIV => 1, 3 ] ], exact => 1), 'd', 'a root that Perl writes as whole is whole';
    is $at->([ MUL => [ DIV => [ NODE => 'n' ], 3 ], 0.9 ], exact => 1), 'd', 'and one that does not end, for it is a fraction until it is written';
    is $at->([ DIV => [ NODE => 'n' ], 3 ], exact => 1), 'INVALID_OPERAND', '... though a fraction is itself no index';

    # And one that binary arithmetic has left a hair away from whole is, to an exact run, the whole number Perl writes.
    my $hair = sub ($data, $opt, @actions) {
        my $r = JGraft->new([ JGRAFT => {}, @actions ])->run($data, temp => { n => $near3, h => 2.5000000000000004, c => 65.00000000000001 }, %$opt);
        return $r->ok ? show($r->output) : $r->error->code;
    };
    my @list = ('a' .. 'f');
    for (
        [ 'an index',                 [ COPY => [ NODE => [ TEMP => 'n' ] ], ['NODE'] ],                                        '"d"' ],
        [ 'an index written to',      [ COPY => 'X', [ NODE => [ TEMP => 'n' ] ] ],                                             '["a","b","c","X","e","f"]' ],
        [ 'a place between two',      [ MOVE => 0, [ NODE => [ TEMP => 'h' ] ] ],                                               '["b","c","a","d","e","f"]' ],
        [ 'where a SLICE begins',     [ COPY => [ SLICE => ['NODE'], [ TEMP => 'n' ] ], ['NODE'] ],                             '["d","e","f"]' ],
        [ '... and how long it is',   [ COPY => [ SLICE => ['NODE'], 0, [ TEMP => 'n' ] ], ['NODE'] ],                          '["a","b","c"]' ],
        [ '... given as a capture',   [ COPY => [ SLICE => { ofs => [ TEMP => 'n' ] } ], ['NODE'] ],                            '["d","e","f"]' ],
        [ 'how many a SPLICE takes',  [ SPLICE => 0, [ TEMP => 'n' ] ],                                                         '["d","e","f"]' ],
        [ 'the length of an array',   [ COPY => [ CASE => [ IS => [ ARRAY => [ ADD => [ TEMP => 'n' ], [ TEMP => 'n' ] ] ] ], 'six', 'not' ], ['NODE'] ], '"six"' ],
        [ 'an offset into one',       [ COPY => [ CASE => [ ARRAY => [ TEMP => 'n' ], 'd', 'e' ], 'there', 'not' ], ['NODE'] ], '"there"' ],
        [ 'how often a REP repeats',  [ COPY => [ CASE => [ [ [ SEQ => [ REP => [ TEMP => 'n' ], [ TEMP => 'n' ], ['STR'] ] ], 'd', 'e', 'f' ] ], 'thrice', 'not' ], ['NODE'] ], '"thrice"' ],
        [ 'where ROUND rounds',       [ COPY => [ ROUND => { at => [ TEMP => 'n' ], as => 'STR' }, 1.23456 ], ['NODE'] ],       '"1.235"' ],
    ) {
        my ($name, $action, $want) = @$_;
        is $hair->([@list], { exact => 1 }, $action), $want, "$name may be a number that Perl writes as whole";
        like $hair->([@list], {}, $action), qr/^(?:INVALID_OPERAND|"not")$/, '    (and not in a run that is not exact)';
    }
    is $hair->('xAy', { exact => 1 }, [ COPY => [ CASE => [ STR => [ SEQ => ['START'], 'x', [ TEMP => 'c' ], 'y', ['END'] ] ], 'A', 'not' ], ['NODE'] ]), '"A"', 'and so may a character be, given as its code';

    # One graft, compiled once, is exact or not as each run is.
    my $both = JGraft->new([ JGRAFT => {}, [ COPY => [ [ [ ADD => 0.1, 0.2 ], [ ADD => 1, 2 ], [ ROUND => { at => 25, as => 'NUM' }, '0.1234567890123456789012345' ] ] ], ['NODE'] ] ]);
    is JGraft::JSON->encode($both->apply(undef, exact => 1)), '[0.3,3,0.1234567890123456789012345]', 'arithmetic written in the graft is exact in a run that is';
    is JGraft::JSON->encode($both->apply(undef)), '[0.30000000000000004,3,0.12345678901234568]', '... and not in one that is not';
    is JGraft::JSON->encode($both->apply(undef, exact => 1)), '[0.3,3,0.1234567890123456789012345]', '... whichever came first';
    is scalar(() = graft([ COPY => [ DIV => 1, 0 ], ['NODE'] ])->warnings), 1, 'what always fails is still seen when the graft is compiled';

    # A document read exactly is run exactly, unless it is said otherwise; one that was not is not.
    my $doc = JGraft::JSON->parse('{"a":0.1,"b":0.2}', exact => 1);
    my $sum = JGraft->new([ JGRAFT => {}, [ COPY => [ ADD => $A, $B ], 'c' ] ]);
    is $doc->write($sum->apply($doc->data)), '{"a":0.1,"b":0.2,"c":0.3}', 'a document read exactly is run exactly';
    is $doc->write($sum->apply($sum->apply($doc->data))), '{"a":0.1,"b":0.2,"c":0.3}', '... and so is what a run made of it';
    is $doc->write($sum->apply($doc->data, exact => 0)), '{"a":0.1,"b":0.2,"c":0.30000000000000004}', '... unless the run is told not to be';
    my $usual = JGraft::JSON->parse('{"a":0.1,"b":0.2}');
    is $usual->write($sum->apply($usual->data)), '{"a":0.1,"b":0.2,"c":0.3}', 'a document is read exactly unless it is asked otherwise';
    my $binary = JGraft::JSON->parse('{"a":0.1,"b":0.2}', exact => 0);
    is $binary->write($sum->apply($binary->data)), '{"a":0.1,"b":0.2,"c":0.30000000000000004}', '... and one read as Perl reads numbers is run with Perl\'s arithmetic';
    is $binary->write($sum->apply($binary->data, exact => 1)), '{"a":0.1,"b":0.2,"c":0.3}', '... unless the run is told to be exact';
    my $longer = '{"n":12345678901234567890123,"m":1.50}';
    is ref JGraft::JSON->parse($longer)->data->{n}, 'JGraft::Number', 'read exactly, a number that Perl does not hold is an object';
    ok !ref JGraft::JSON->parse($longer, exact => 0)->data->{n} && !ref JGraft::JSON->parse($longer, exact => 0)->data->{m}, '... and otherwise the nearest that Perl has';
    is JGraft::JSON->parse($longer, exact => 0)->write, $longer, '... though either way what is not touched is written as it was';
    ok !eval { JGraft::JSON->parse('1', exactly => 1); 1 } && $@ =~ /unknown option exactly/, 'parse refuses an option it does not know';
    is $doc->write($sum->apply($doc->data, exact => 0)), '{"a":0.1,"b":0.2,"c":0.30000000000000004}', 'the document is none the worse';

    # What is not touched is written as it was; what is, with the digits it has.
    my $kept = '{"big":123456789012345678901234567890, "sci":1e1, "zero":-0.0, "places":1.50, "huge":1e400, "tiny":12e-30}';
    is $on->($kept, [ COPY => 1, 'n' ]), $kept =~ s/\}$/, "n":1}/r, 'numbers of every kind are written back as they were';
    is $on->('{"a":1.50,"b":1e1}', [ MOVE => 'a', 'c', 'b', 'd' ]), '{"c":1.50,"d":1e1}', 'and go where they are moved to as they were';
    is $on->('{"a":1.50}', [ COPY => [ ADD => $A, 0 ], 'a' ]), '{"a":1.50}', 'a number that comes out as it went in is left as it was';
    is $on->('{"a":1.5}', [ COPY => [ CASTNUM => '1.50' ], 'a' ]), '{"a":1.50}', 'but one known to another place is written so, though it is equal';
    is $on->('{"a":1e1}', [ COPY => [ ADD => $A, 0 ], 'a' ]), '{"a":1e1}', 'a whole number has no places to differ in';

    # Numbers are compared by what they are worth.
    my $test = sub ($text, $pattern) { $on->($text, [ COPY => [ CASE => $pattern, 'yes', 'no' ], ['NODE'] ]) };
    is $test->('{"a":0.30}', { a => 0.3 }), '"yes"', 'thirty hundredths match three tenths';
    is $test->('{"a":0.30,"b":0.3}', [ IS => $A, $B ]), '"yes"', '... and are it, compared as values';
    is $test->('{"a":12345678901234567890123,"b":12345678901234567890124}', [ IS => $A, $B ]), '"no"', 'two long integers that differ in the last digit are not one';
    is $test->('{"a":12345678901234567890123,"b":12345678901234567890124}', [ IS => [ LESS => $A, $B ], $JGraft::Util::TRUE ]), '"yes"', '... and the lesser is less';
    is $test->('{"a":12345678901234567890123}', { a => [ NUM => 1e22, 1e23 ] }), '"yes"', 'NUM knows a long number for one, and where it lies';
    is $test->('{"a":0.30}', { a => [ NUM => 0.31 ] }), '"no"', '... and where it does not';
    is $test->('{"a":1e400}', { a => [ NUM => [ CASTNUM => '9e399' ], [ CASTNUM => '1.1e400' ] ] }), '"yes"', '... with bounds as long';
    is $on->('{"i":1.0,"list":[5,6,7]}', [ COPY => [ NODE => 'list', [ NODE => 'i' ] ], ['NODE'] ]), '6', 'a whole number, however written, is an index';

    # ROUND and the casts know the digits.
    is $on->('{"a":1.50}', [ COPY => [ CASTSTR => $A ], ['NODE'] ]), '"1.50"', 'CASTSTR writes the places';
    is $on->('{"a":1.50}', [ COPY => [ ROUND => { as => 'SIG', at => 5 }, $A ], ['NODE'] ]), '"1.50"', 'ROUND knows how many are significant';
    is $on->('{"a":2.345}', [ COPY => [ ROUND => { at => 2, mode => 'HALF_EVEN' }, $A ], ['NODE'] ]), '2.34', 'and rounds the digits there are';
    is $on->('{"a":1.5}', [ COPY => [ ROUND => { as => 'INT', shift => 30 }, $A ], ['NODE'] ]), '1.5e+30', 'an integer too long for Perl is kept whole';
    is $on->('{"a":123456789012345678901234567890.5}', [ COPY => [ ROUND => { as => 'INT', mode => 'DOWN' }, $A ], ['NODE'] ]), '123456789012345678901234567890',
        '... every digit of it';
    is JGraft->new([ JGRAFT => {}, [ COPY => [ ROUND => { as => 'INT', shift => 30 }, ['NODE'] ], ['NODE'] ] ])->run(1.5)->error->code, 'UNSUPPORTED_GRAFT',
        'which arithmetic that is not exact cannot do';

    # Numbers of the modules that Perl has for the purpose are numbers too.
    my $foreign = { a => Math::BigInt->new(2)->bpow(70), b => Math::BigFloat->new('2.5') };
    my $r = JGraft->new([ JGRAFT => {}, [ MATCH => { a => ['NUM'], b => 2.5 } ], [ COPY => [ ADD => $A, 1 ], 'c', [ MUL => $B, $B ], 'd' ] ])->run($foreign);
    is JGraft::JSON->encode([ @{ $r->output }{qw(a c d)} ]), '[1180591620717411303424,1180591620717411303425,6.25]', 'Math::BigInt and Math::BigFloat are read as numbers, in any run';
    is ref $r->output->{c}, 'JGraft::Number', '... and calculated with exactly';

    # What it costs is counted.
    my $limited = sub ($expr, %limits) { my $r = JGraft->new([ JGRAFT => {}, [ COPY => $expr, ['NODE'] ] ])->run(undef, exact => 1, limits => \%limits); $r->ok ? 'ok' : $r->error->code };
    is $limited->([ POW => 3, 100000 ], mem => 5000), 'RESOURCE_LIMIT', 'a number of many digits is memory';
    is $limited->([ POW => 3, 100000 ], ops => 5000), 'RESOURCE_LIMIT', '... and work';
    is $limited->([ ADD => [ POW => 10, 1e6 ], 1 ], mem => 1e5), 'RESOURCE_LIMIT', 'as are the zeros between two numbers far apart';
    is $limited->([ POW => 3, 100 ], mem => 5000, ops => 5000), 'ok', 'a number of few is little';

    # A run that is exact can be undone exactly.
    my $before = JGraft::JSON->parse('{"a":0.3,"b":[1,2]}', exact => 1);
    my $change = JGraft->new([ JGRAFT => {}, [ COPY => [ CASTNUM => '0.30' ], 'a', [ POW => 2, 80 ], [ 'NODE', 'b', 0 ] ] ])->run($before->data);
    is $before->write($change->output), '{"a":0.30,"b":[1208925819614629174706176,2]}', 'a change that is only of places, and one to a long number';
    is $before->write(JGraft->new($change->undo)->apply($change->output)), '{"a":0.3,"b":[1,2]}', 'are both undone';
    my $long  = JGraft::JSON->parse('[12345678901234567890123]', exact => 1);
    my $drop  = JGraft->new([ JGRAFT => {}, [ COPY => 5, 0 ] ])->run($long->data);
    is $long->write(JGraft->new($drop->undo)->apply($drop->output)), '[12345678901234567890123]', 'and a long number that was lost is put back, digit for digit';
};

subtest 'the public interface' => sub {
    my @seen;
    my $g = graft([ RAISE => 'warn', 'careful', ['NODE'] ], [ MATCH => 1 ], [ COPY => 2, ['NODE'] ]);
    my $r = $g->run(1, on_raise => sub ($record) { push @seen, $record->{message} });
    ok $r->ok, 'run succeeds';
    is $r->output, 2, 'with the output';
    is show($r->logs), '[{"data":1,"level":1,"message":"careful"}]', 'and the log';
    is "@seen", 'careful', 'on_raise is called';

    $r = $g->run(5);
    ok !$r->ok, 'run reports a failure';
    is $r->error->code, 'NO_MATCH', 'with its code';
    is "" . $r->error, 'NO_MATCH: the data does not match in MATCH at /3', 'which reads sensibly';
    is $r->output, undef, 'and there is no output';
    is $r->partial, 5, 'only the document as the failure left it';
    is show($r->logs), '[{"data":5,"level":1,"message":"careful"}]', 'and the log';
    ok !eval { $g->apply(5); 1 }, 'apply dies instead';
    is ref $@, 'JGraft::Error', 'with the error object';
    is show([ $@->partial, $@->logs ]), '[5,[{"data":5,"level":1,"message":"careful"}]]', 'which has both of those';
    is $g->run(1)->partial, undef, 'a run that succeeds leaves nothing partial';

    my $dates = graft([ COPY => { on => [ CASTDATE => '2024-02-29T12:00:00+0130' ] }, 'when' ]);
    is show($dates->apply({})), '{"when":{"on":"2024-02-29T12:00:00+0130"}}', 'dates leave as strings';
    is show($dates->apply({}, date_export => sub ($d) { $d->prop('year') })), '{"when":{"on":2024}}', 'or as asked';

    is graft()->struct->[0], 'JGRAFT', 'struct returns the graft';
    ok !eval { graft([ RAISE => 'info', 'x' ])->run(1, on_raise => sub { die { mine => 1 } }); 1 } && ref $@ eq 'HASH' && $@->{mine},
        "an exception of the caller's own passes through, whatever it is";
    my $spliced = graft([ SPLICE => [ 'TEMP', 't', 0 ], 1 ], [ COPY => 5, [ 'TEMP', 'z' ] ], [ COPY => [ 'TEMP', 'z' ], ['NODE'] ])
        ->run(0, temp => { t => [ 1, 2, 3 ] });
    is $spliced->error && $spliced->error->code, 'INVALID_TARGET', 'TEMP is new for each action, after a SPLICE as after any other';
    is graft()->run(1, limits => { ops => 0 })->ok, 1, 'limits only count real work';
    is JGraft->new([ JGRAFT => { expr => [ loop => [ EXPR => 'loop' ] ] }, [ COPY => [ EXPR => 'loop' ], ['NODE'] ] ])
        ->run(1, limits => { depth => 50 })->error->code, 'RESOURCE_LIMIT', 'runaway recursion is stopped';

    # A name that is not known is a mistake, and is said to be: most of all a limit, which misspelt would not limit.
    my $croaks = sub ($what, $code) { my $at = __LINE__; eval { $code->(); 1 } ? 'accepted' : $@ =~ /^JGraft->\w+: (.*) at \S*design\.t line/ ? $1 : "died: $@" };
    is $croaks->(new => sub { JGraft->new([ JGRAFT => {} ], strick => 0) }), 'unknown option strick', 'new refuses an option it does not know';
    is $croaks->(new => sub { JGraft->new([ JGRAFT => {} ], limits => { opps => 5 }) }), 'unknown limit opps', '... and a limit';
    is $croaks->(new => sub { JGraft->new([ JGRAFT => {} ], limits => [ ops => 5 ]) }), 'limits must be a hash', '... and limits that are not a hash';
    is $croaks->(run => sub { graft()->run(1, on_rase => sub { }, tmp => {}) }), 'unknown options on_rase tmp', 'run refuses them too';
    is $croaks->(run => sub { graft()->apply(1, limits => { mem => -1 }) }), 'limit mem must be a number that is not negative', '... and a limit that is not one';
    is $croaks->(run => sub { graft()->apply(1, limits => { mem => 'lots' }) }), 'limit mem must be a number that is not negative', '... or not a number';
    is $croaks->(run => sub { graft()->apply(1, limits => { ops => '1e6', mem => undef }, temp => {}, on_raise => undef, date_export => undef) }), 'accepted',
        'what is known is accepted, and a limit that is not defined is none';

    # The limits given to new are those of each run, unless the run is given its own.
    my @work  = ([ JGRAFT => {}, [ COPY => [ MAP => 1, ['NODE'] ], ['NODE'] ] ], [ 1 .. 50 ]);
    my $bound = JGraft->new($work[0], limits => { ops => 10, mem => 1e9 });
    is $bound->run($work[1])->error->code, 'RESOURCE_LIMIT', 'a run is under the limits given to new';
    is $bound->run($work[1])->error->code, 'RESOURCE_LIMIT', '... each run under all of them, not what the last left';
    ok $bound->run($work[1], limits => { ops => 1000 })->ok, '... unless given its own';
    ok $bound->run($work[1], limits => { ops => undef })->ok, '... or none';
    is $bound->run($work[1], limits => { ops => 1000, mem => 10 })->error->code, 'RESOURCE_LIMIT', 'a limit the run does not mention stays, and one it does replaces';
    ok JGraft->new($work[0])->run($work[1])->ok, 'with no limits there are none';

    # The graft is what the structure was when it was compiled.
    my $later = [ JGRAFT => { expr => [ f => [ ADD => 1, 1 ], g => [ [ 1, 2 ] ] ] }, [ COPY => [ EXPR => [ NODE => 'n' ] ], 'a' ] ];
    my $fixed = JGraft->new($later);
    $later->[1]{expr}[1][1] = 5;                # a definition not yet used, changed where it stands
    push @{ $later->[1]{expr}[3][0] }, 3;
    $later->[2][2] = 'b';
    is show($fixed->apply({ n => 'f' })), '{"a":2,"n":"f"}', 'a change to the structure after new does not reach the graft';
    is show($fixed->apply({ n => 'g' })), '{"a":[1,2],"n":"g"}', '... in any part of it';
    is show($fixed->struct), '["JGRAFT",{"expr":["f",["ADD",1,1],"g",[[1,2]]]},["COPY",["EXPR",["NODE","n"]],"a"]]', 'struct is the graft as it was compiled';
    my $shared = [ ADD => 1, 2 ];
    is show(JGraft->new([ JGRAFT => {}, [ COPY => $shared, 'a', $shared, 'b' ] ])->apply({})), '{"a":3,"b":3}', 'a structure that uses one array twice is no trouble';
};

done_testing;
