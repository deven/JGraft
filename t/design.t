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
    my $c   = JGraft::Compiler->new;
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
    is graft()->run(1, limits => { ops => 0 })->ok, 1, 'limits only count real work';
    is JGraft->new([ JGRAFT => { expr => [ loop => [ EXPR => 'loop' ] ] }, [ COPY => [ EXPR => 'loop' ], ['NODE'] ] ])
        ->run(1, limits => { depth => 50 })->error->code, 'RESOURCE_LIMIT', 'runaway recursion is stopped';
};

done_testing;
