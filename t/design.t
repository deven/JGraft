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

subtest 'constants are shared, and protected where Perl can protect them' => sub {
    my $struct = [ JGRAFT => { v => 1 },
        [ COPY => { list => [ [ 1, { n => 2 } ] ], tag => 'x' }, 'made', [ CONCAT => [ [1] ], [ [2] ] ], 'folded' ] ];
    my $g = JGraft->new($struct);
    my ($one, $two) = map { $g->apply({}) } 1, 2;
    my $was = show($one);
    ok $one->{made} == $two->{made}, 'a literal is one value, however often it is produced';

    my $refused = sub ($what, $edit) { ok !eval { $edit->(); 1 } && $@ =~ /read-only/, "$what is refused" };
    $refused->('adding to its array',                  sub { push @{ $one->{made}{list} }, 3 });
    $refused->('replacing an element',                 sub { $one->{made}{list}[0] = 9 });
    $refused->('replacing a property',                 sub { $one->{made}{tag} = 'y' });
    $refused->('a change at any depth',                sub { $one->{made}{list}[1]{n} = 9 });
    $refused->('a change to a folded value',           sub { push @{ $one->{folded} }, 3 });

    ok eval { $one->{mine} = 1; push @{ $struct->[2][1]{list}[0] }, 3; 1 },
        'what a run builds, and the structure the graft was compiled from, stay writable';
    my $copy = Storable::dclone($two);
    ok eval { push @{ $copy->{made}{list} }, 3; $copy->{made}{tag} = 'y'; 1 }, 'and so does a deep copy of a result';
    is show($g->apply({})), $was, 'and none of it reaches a later run';

    my $edit = graft([ COPY => { x => [ [ 1, 2 ] ] }, 'made', 9, [ 'NODE', 'made', 'x', 0 ] ]);
    is show([ map { $edit->apply({}) } 1, 2 ]), '[{"made":{"x":[9,2]}},{"made":{"x":[9,2]}}]',
        'a graft can still change what it made: the engine copies first';
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
    my $c   = bless { faults => [] }, 'JGraft::Compiler';
    my $ctx = { scope => { exprs => {}, cells => {} } };
    ok !$c->match($ctx, { a => [ ALL => 'a', ['STR'] ] })->{throws}, 'a pattern of literals needs no error trap';
    ok $c->match($ctx, { a => [ ALL => 'a', ['NODE', 'x'] ] })->{throws}, 'a pattern that reads the data does';
    ok !$c->match($ctx, [ ANY => 'a', ['NODE', 'x'] ])->{throws},    'ANY has already trapped its alternatives';
    ok exists $c->match($ctx, { a => [ [ 1, { b => undef } ] ] })->{lit}, 'pure data collapses to one comparison';
    is scalar JGraft->new([ JGRAFT => {}, [ COPY => ['NOPE'], 'a' ] ], strict => 0)->faults, 1, 'faults are collected';
    ok !eval { JGraft->new([ JGRAFT => {}, [ COPY => ['NOPE'], 'a' ] ]) }, 'and thrown at once when strict';
    is $@->code, 'INVALID_GRAFT', 'as INVALID_GRAFT';
};

subtest 'constant folding' => sub {
    my $c     = bless { faults => [] }, 'JGraft::Compiler';
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
        my $k = bless { faults => [], limits => {%limits} }, 'JGraft::Compiler';
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
    is "@{[ $r->error ]}", 'INVALID_TARGET: division by zero in COPY', 'and fails as it always did where it is';
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
    like "" . $r->error, qr/^NO_MATCH: .* in MATCH$/, 'which reads sensibly';
    ok !eval { $g->apply(5); 1 }, 'apply dies instead';
    is ref $@, 'JGraft::Error', 'with the error object';

    my $dates = graft([ COPY => { on => [ CASTDATE => '2024-02-29T12:00:00+0130' ] }, 'when' ]);
    is show($dates->apply({})), '{"when":{"on":"2024-02-29T12:00:00+0130"}}', 'dates leave as strings';
    is show($dates->apply({}, date_export => sub ($d) { $d->prop('year') })), '{"when":{"on":2024}}', 'or as asked';

    is graft()->struct->[0], 'JGRAFT', 'struct returns the graft';
    is graft()->run(1, limits => { ops => 0 })->ok, 1, 'limits only count real work';
    is JGraft->new([ JGRAFT => { expr => [ loop => [ EXPR => 'loop' ] ] }, [ COPY => [ EXPR => 'loop' ], ['NODE'] ] ])
        ->run(1, limits => { depth => 50 })->error->code, 'RESOURCE_LIMIT', 'runaway recursion is stopped';
};

done_testing;
