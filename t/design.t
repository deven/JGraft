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
    my $c   = bless { faults => [] }, 'JGraft::Compiler';
    my $ctx = { scope => { exprs => {}, cells => {} } };
    my $folded = sub ($s) { my $n = $c->value($ctx, $s); $n->{const} ? show($n->{value}) : 'not folded' };

    is $folded->([ ADD => 1, 2 ]),                                          '3',        'arithmetic on literals';
    is $folded->([ CONCAT => 'n=', [ CASTSTR => [ MUL => 2, [ ADD => 1, 2 ] ] ] ]), '"n=6"', 'nested';
    is $folded->([ LESS => [ CASTDATE => '2024-01-01' ], [ CASTDATE => '2024-06-15' ] ]), 'true', 'dates compared';
    is $folded->([ LENGTH => [ [ 1, 2, 3 ] ] ]),                            '3',        'a scalar from a literal array';
    is $folded->([ ROUND => { at => 1 }, '2.25' ]),                         '"2.3"',    'ROUND with both operands';

    is $folded->([ ADD => 1, ['NODE'] ]), 'not folded', 'not when an operand reads the data';
    is $folded->($_), 'not folded', "not when the current node is implied: $_->[0]"
        for ['LENGTH'], [ POW => 2 ], [ LESS => 5 ], [ ROUND => 2 ], ['CASTNUM'], ['CURPROP'];
    is $folded->([ CONCAT => [ [1] ], [ [ { a => 2 } ] ] ]), '[1,{"a":2}]', 'an array, too';
    is $folded->([ DIV => 1, 0 ]),                'not folded', 'not what fails';
    is $folded->([ ROUND => { as => 'STR', at => 1e7 }, '1' ]), 'not folded', 'not what costs too much';

    ok exists $c->match($ctx, { a => [ CONCAT => 'a', 'b' ] })->{lit}, 'a folded value is a literal to a pattern';
    ok !@{ $c->{faults} }, 'none of which is a fault';

    my $r = graft([ COPY => [ DIV => 1, 0 ], 'a' ])->run({});
    is $r->error->code, 'INVALID_TARGET', 'a failure is raised by the run that reaches it';
    is show(graft([ COPY => [ ANY => [ DIV => 1, 0 ], [ IS => [ DIV => 4, 2 ], 2 ] ], ['NODE'] ])->apply(0)), 'true',
        'and is still only a failed probe inside a match';
    is graft([ COPY => [ ROUND => { as => 'STR', at => 1e7 }, '1' ], 'a' ])->run({}, limits => { mem => 1e6 })
        ->error->code, 'RESOURCE_LIMIT', 'and limits still apply to what was not folded';
    my $date = graft([ COPY => [ CASTDATE => '2024-02-29' ], 'd', [ CASTDATE => '2024-02-29' ], [ 'STASH', 'd' ] ],
        [ COPY => [ 'STASH', 'd', 'month' ], 'm' ], [ COPY => { in => [ [ [ CASTDATE => '2024-03-01' ] ] ] }, 'deep' ]);
    is show($date->apply({})), '{"d":"2024-02-29","deep":{"in":["2024-03-01"]},"m":2}',
        'a folded date is still a date inside, and a string outside';
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
