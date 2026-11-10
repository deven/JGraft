package JGraft::Ops::Match;

# Match expressions.

use v5.36;
use builtin qw(created_as_number);
no warnings qw(experimental::builtin recursion);
use List::Util qw(min max);
use JGraft::Util;
use JGraft::Seq;
use JGraft::Compiler qw(defop node trap row %EXPR);

use constant INF => 9**9**9;

#---------------------------------------------------------------------------
# Structure

# [HAS, spec] and [IS, spec] set how strictly the structure below is matched.
# With a value first, they match that value instead of the current node.
for my $exact (0, 1) {
    defop +($exact ? 'IS' : 'HAS'), 1 + $exact, 'match', 'XX?', sub ($c, $ctx, @arg) {
        my $spec = pop @arg;
        my $in   = { %$ctx, exact => $exact, top => 0 };
        if (!@arg) {
            my %n = %{ $c->match($in, $spec) };
            delete $n{lit};        # the mode chosen here must survive in an enclosing pattern
            return \%n unless $ctx->{seq};
            # In a sequence the spec is tested from here, however far it
            # reaches, and then exactly one element is consumed.
            my ($test, $resolve) = @n{qw(code resolve)};
            delete @n{qw(re fixed longest least chars run tails)};     # which were true of the spec, not of this
            return { %n, code => sub { $_[2] < $_[3] && (() = &$test) ? $_[2] + 1 : () },
                resolve => sub ($x, $s, $from, $to, $len) {
                    my @end = do { local $x->{capturing} = 0; $test->($x, $s, $from, $len) };
                    $resolve->($x, $s, $from, min(@end), $len) if $resolve;
                } };
        }
        $ctx = { %$ctx, seq => 0, top => 0 };      # with a value, it tests that value and consumes nothing
        my $value = $c->value($ctx, $arg[0]);
        my $get   = $value->{code};
        my $n;
        if ($c->matches($ctx, $spec)) {     # matching begins anew, on the given value
            my $m    = $c->binding(['node'], sub { $c->match({ %$in, seq => 0, regex => 0 }, $spec) });
            my $test = $m->{code};
            $n = node(sub { my $x = $_[0]; my $v = &$get; local $x->{path} = []; $test->($x, $v, undef, undef) },
                $value, $m);
        }
        else {                              # the spec is itself a value, still seen from the current node
            my $want = $c->value($ctx, $spec)->{code};
            $n = { code => sub { match_lit(&$get, &$want, $exact) } };
        }
        return { %$n, throws => 1, zero => 1 };
    }, seq => 1, blind => 1;        # what they match looks at the node; they do not
}

defop EXISTS => 6, 'match', '', sub ($c, $ctx) {
    sub { ref $_[1] ne 'JGraft::Missing' };
}, safe => 1;

defop ARRAY => 7, 'match', 'V?X*', sub ($c, $ctx, $n = undef, @items) {
    return { code => sub { ref $_[1] eq 'ARRAY' } } unless $n;
    return { %{ $c->array($ctx, \@items, $n->{code}) }, throws => 1 } if @items;
    my ($exact, $get) = ($ctx->{exact}, $n->{code});
    return { throws => 1, code => sub {
        my $want = &$get;
        is_int($want) or $_[0]->fail_operand('array length must be an integer');
        ref $_[1] eq 'ARRAY' && ($exact ? @{ $_[1] } == $want : @{ $_[1] } >= $want);
    } };
};

defop STR => 8, 'match', 'X?', sub ($c, $ctx, @regex) {
    return { code => sub { is_str($_[1]) } } unless @regex;
    my $item = $c->match({ %$ctx, exact => 0, regex => 1, seq => 1, top => 1 }, $regex[0]);
    my $run  = JGraft::Seq::runner([$item], 1);
    # Whether there is a match at all is a question Perl can be asked, if
    # the pattern can be written as a regex and no captures are wanted.  It
    # is not asked when operations are being counted: Perl does not count.
    my $perl = !$item->{caps} && defined $item->{re} ? eval { no warnings; qr/$item->{re}/ } : undef;
    return { throws => 1, caps => $item->{caps}, code => sub {
        return 0 unless is_str($_[1]);
        return $_[1] =~ $perl ? 1 : 0 if $perl && $_[0]{ops} == INF;
        my $len = length $_[1];
        $run->($_[0], \$_[1], $len, [ 0 .. $len ], undef);      # not anchored: may start anywhere
    } };
};

defop NUM => 9, 'match', 'V?V?', sub ($c, $ctx, @bound) {
    my @get = map { $_->{code} } @bound;
    return { code => sub { created_as_number($_[1]) } } unless @get;
    return sub {
        my ($lo, $hi) = map { $_->(@_) } @get;
        my $x = $_[0];
        defined $_ && !(created_as_number($_) && $_ - $_ == 0) and $x->fail_operand('NUM bounds must be numbers')
            for $lo, $hi;
        $x->fail_operand('NUM bounds out of order') if defined $lo && defined $hi && $lo > $hi;
        created_as_number($_[1]) && (!defined $lo || $_[1] >= $lo) && (!defined $hi || $_[1] <= $hi);
    };
};

defop BOOL => 10, 'match', '', sub ($c, $ctx) {
    sub { type_of($_[1]) == T_BOOL };
}, safe => 1;

#---------------------------------------------------------------------------
# Logic.  In a sequence these combine sets of successor positions.  Like HAS
# and IS they are `blind`: only what they combine looks at the node.

# Children of ANY and NONE are trapped individually, and cannot capture.
my $alternative = sub ($c, $ctx, @spec) { map { $c->match({ %$ctx, cap => 0, top => 0 }, $_) } @spec };
my $alternatives = sub ($c, $ctx, @spec) { map { trap($_) } $alternative->($c, $ctx, @spec) };

defop NONE => 3, 'match', 'X*', sub ($c, $ctx, @spec) {
    my @kid = $alternative->($c, $ctx, @spec);
    my @try = map { trap($_) } @kid;
    return { code => sub { $_->(@_) and return 0 for @try; 1 } } unless $ctx->{seq};
    my $re = (grep { !defined $_->{re} } @kid) ? undef : @kid ? '(?!' . join('|', map { $_->{re} } @kid) . ')' : '';
    return { seq => 1, re => $re, code => sub { (() = $_->(@_)) and return for @try; $_[2] } };
}, seq => 1, blind => 1;

defop ANY => 4, 'match', 'X+', sub ($c, $ctx, @spec) {
    my @kid = $alternative->($c, $ctx, @spec);
    my @try = map { trap($_) } @kid;
    return { code => sub { $_->(@_) and return 1 for @try; 0 } } unless $ctx->{seq};
    # alternatives that each take one element take one between them, and
    # characters that each could be are the characters this could be
    my $one   = !grep { !$_->{one} } @kid;
    my $chars = (grep { !$_->{chars} } @kid) ? undef : [ map { @{ $_->{chars} } } @kid ];
    # As a regex, alternatives of known lengths are put longest first, so
    # that the first of them to match is the longest that does.
    my $sized = !grep { !defined $_->{fixed} } @kid;
    my @by    = $sized ? sort { $b->{fixed} <=> $a->{fixed} } @kid : @kid;
    my $re    = (grep { !defined $_->{re} } @kid) ? undef : '(?:' . join('|', map { $_->{re} } @by) . ')';
    my %size  = $sized ? (longest => 1, least => $by[-1]{fixed}, fixed => $by[0]{fixed} == $by[-1]{fixed} ? $by[0]{fixed} : undef) : ();
    return { seq => 1, one => $one, chars => $chars, re => $re, %size, code => sub {
        my @end = map { $_->(@_) } @try;
        return @end if @end < 2;
        my %seen;
        grep { !$seen{$_}++ } @end;
    } };
}, seq => 1, blind => 1;

defop ALL => 5, 'match', 'X+', sub ($c, $ctx, @spec) {
    my @kid  = map { $c->match({ %$ctx, top => 0 }, $_) } @spec;
    my @code = map { $_->{code} } @kid;
    return node(sub { $_->(@_) or return 0 for @code; 1 }, @kid) unless $ctx->{seq};
    # Every argument must be satisfiable from here; the match may then end
    # wherever any of them does, once all of them have been satisfied.
    my $n = node(sub {
        my (%end, $all);
        for my $code (@code) {
            my @e = $code->(@_) or return;
            $all = max $all // (), min @e;
            @end{@e} = @e;
        }
        grep { $_ >= $all } values %end;
    }, @kid);
    # Each argument's captures come from its latest ending within the span.
    my $resolve = sub ($x, $s, $from, $to, $len) {
        for my $kid (grep { $_->{caps} && $_->{resolve} } @kid) {
            my @end = do { local $x->{capturing} = 0; $kid->{code}->($x, $s, $from, $len) };
            $kid->{resolve}->($x, $s, $from, (max grep { $_ <= $to } @end), $len);
        }
    };
    return { %$n, seq => 1, resolve => $resolve };
}, seq => 1, blind => 1;

# [WITH, name, value, ..., spec]: match under extra TEMP bindings.
defop WITH => 12, 'match', 'X+', sub ($c, $ctx, @arg) {
    my $spec = pop @arg;
    @arg && @arg % 2 == 0 or return $c->fault('WITH takes name/value pairs and a pattern');
    my (@bind, @bound);     # each value, and then the pattern, sees the names before it
    while (my ($name, $value) = splice @arg, 0, 2) {
        is_str($name) || is_int($name) or return $c->fault('WITH names must be literal strings');
        my @so_far = @bound;
        push @bind, [ "$name", $c->here($ctx, $c->binding(\@so_far, sub { $c->value($ctx, $value) })->{code}) ];
        push @bound, "temp $name";
    }
    my $body  = $c->binding(\@bound, sub { $c->match($ctx, $spec) });
    my $under = sub ($code, @pick) {
        sub {
            my $x = $_[0];
            my @env = @pick ? @_[@pick] : @_;
            local $x->{temp} = { %{ $x->{temp} } };
            $x->{temp}{ $_->[0] } = $_->[1]->(@env) for @bind;
            &$code;
        };
    };
    my %n = (%$body, throws => 1, code => $under->($body->{code}));
    $n{resolve} = $under->($body->{resolve}, 0, 1, 2, 4) if $body->{resolve};
    delete $n{lit};
    return \%n;
}, seq => 1, blind => 1;

#---------------------------------------------------------------------------
# Sequences

sub sequence ($c, $ctx, @spec) {
    $ctx->{seq} or return $c->fault('a sequence can only begin as an item of an array pattern');
    my @kid  = map { $c->match({ %$ctx, top => 0 }, $_) } @spec;
    my @code = map { $_->{code} } @kid;
    my $n    = node(sub {
        my ($x, $s, $p, $len) = @_;
        my @at = ($p);
        for my $code (@code) {
            my %seen;
            @at = grep { !$seen{$_}++ } map { $code->($x, $s, $_, $len) } @at or return;
            $x->charge(scalar @at);
        }
        @at;
    }, @kid);
    my $run = JGraft::Seq::runner(\@kid);
    my $re  = (grep { !defined $_->{re} } @kid) ? undef : join '', map { $_->{re} } @kid;
    return { %$n, seq => 1, re => $re, resolve => sub ($x, $s, $from, $to, $len) { $run->($x, $s, $len, [$from], $to) } };
}

defop SEQ => 13, 'match', 'X*', \&sequence, seq => 1;

# Named sequences: a length preference, and a capture of the span matched.
for ([ SEQMAX => 14, 'max' ], [ SEQMIN => 15, 'min' ]) {
    my ($op, $id, $pref) = @$_;
    defop $op, $id, 'match', 'VX*', sub ($c, $ctx, $name, @spec) {
        $ctx->{top} or return $c->fault("$op must be an item of an array pattern");
        my $n = sequence($c, $ctx, @spec);
        return $n unless $ctx->{cap};       # unobservable: an ordinary SEQ
        my ($body, $get) = ($n->{caps} && $n->{resolve}, $name->{code});
        return { %$n, caps => 1, throws => 1, pref => $pref, resolve => sub ($x, $s, $from, $to, $len) {
            my $key = $get->($x, $MISSING, undef, undef);
            if (defined $key) {
                is_str($key) || is_int($key) or $x->fail_operand('capture name must be a string');
                exists $x->{caps}{$key} and $x->fail_operand("duplicate capture name '$key'");
                $x->charge_obj for 1, 2;        # the record and its path
                $x->{caps}{$key} = { path => [ @{ $x->{path} } ], ofs => $from, len => $to - $from, lim => $to };
            }
            $body->($x, $s, $from, $to, $len) if $body;
        } };
    }, seq => 1;
}

# [REP, min, max, spec]
defop REP => 16, 'match', 'V?V?X?', sub ($c, $ctx, @arg) {
    $ctx->{seq} or return $c->fault('REP is only meaningful in a sequence');
    my ($min, $max) = map { $_ < @arg ? $c->here($ctx, $arg[$_]{code}) : undef } 0, 1;
    my $limits = sub ($lo, $hi) {       # the range of counts, or nothing if the bounds are invalid
        return unless is_int($lo) && $lo >= 0 && is_int($hi) && $hi >= -1;
        $hi = $hi == 0 ? $lo : $hi < 0 ? INF : $hi;
        return $hi >= $lo ? ($lo, $hi) : ();
    };
    my @given = @arg[ 0 .. ($#arg < 1 ? $#arg : 1) ];
    my @fixed = (grep { !$_->{const} } @given) ? () : $limits->((map { $_->{value} } @given), (0, -1)[ @given .. 1 ]);
    my $kid    = @arg > 2 ? $c->match({ %$ctx, cap => 0, top => 0 }, $arg[2]) : undef;
    my $body   = $kid && trap($kid);        # a failed probe ends the repetition
    my $single = $kid && $kid->{one};
    # `tails`: every tail of a match is itself a match (a run with no minimum)
    # `run`: it is from $lo to $hi characters of one known set
    my $run = @fixed && $kid && $kid->{chars} ? [ $kid->{chars}, @fixed ] : undef;
    # as a regex: a run of any characters, or of those in one set, which Perl makes as long as it can
    my $unit = !$kid ? '(?s:.)' : $kid->{chars} ? JGraft::Compiler::re_set($kid->{chars}) : undef;
    my %re   = @fixed && $unit
        ? (re => "$unit\{$fixed[0]," . ($fixed[1] == INF ? '' : $fixed[1]) . '}', longest => 1, least => $fixed[0]) : ();
    return { seq => 1, throws => !@fixed, tails => @fixed && !$fixed[0] && (!$kid || $single), run => $run, %re, code => sub {
        my ($x, $s, $p, $len) = @_;
        my ($lo, $hi) = @fixed ? @fixed : $limits->($min ? &$min : 0, $max ? &$max : -1)
            or $x->fail_operand('invalid REP bounds');
        return $p + $lo .. min($len, $p + $hi) unless $body;        # any elements at all
        if ($single) {                                              # a run of single elements
            my $n = 0;
            $n++ while $n < $hi && (() = $body->($x, $s, $p + $n, $len));
            $x->charge($n);
            return $n < $lo ? () : $p + $lo .. $p + $n;
        }
        my %done;
        $done{$p} = $p if $lo == 0;
        my @at = ($p);
        for (my $count = 1; $count <= $hi && @at; $count++) {
            my ($before, %seen) = "@at";
            @at = sort { $a <=> $b } grep { !$seen{$_}++ } map { $body->($x, $s, $_, $len) } @at;
            $x->charge(scalar @at);
            $count = $lo if $count < $lo && "@at" eq $before;       # standing still: more repetitions change nothing
            # past the minimum, a position reached again leads nowhere new
            @at = grep { !exists $done{$_} and $done{$_} = $_, 1 } @at if $count >= $lo;
        }
        values %done;
    } };
}, seq => 1;

# Zero-width tests of where the current node sits in its array.
defop START => 17, 'match', '', sub ($c, $ctx) {
    +{ zero => 1, re => '\A', code => sub { ref $_[3] && ref $_[3] ne 'HASH' && $_[2] == 0 } };
};

defop END => 18, 'match', '', sub ($c, $ctx) {
    +{ zero => 1, re => '\z', code => sub {
        my $r = ref $_[3];
        $r eq 'ARRAY' ? $_[2] == @{ $_[3] } : $r eq 'SCALAR' && $_[2] == length ${ $_[3] };
    } };
};

#---------------------------------------------------------------------------
# Character sets

# [CHARS, ...]: strings list members, two single characters in a row give a
# range, true / false switch between adding and removing, and [EXPR, name]
# refers to another set.  A character is a code point or one-character string.
defop CHARS => 19, 'match', 'X*', sub ($c, $ctx, @spec) {
    my $single = sub ($e) {     # the code point of an element that denotes exactly one character
        return !defined $e ? 0x10FFFF : is_int($e) ? $e : is_str($e) && length $e == 1 ? ord $e : undef;
    };
    my $not_a_set = sub { $_[0]->fail_operand('not a character set') };
    my $adding    = 1;
    my $full   = @spec && type_of($spec[0]) == T_BOOL && !$spec[0];     # start from everything
    my @rule;                                                           # [ adding, lo, hi ] or [ adding, test ]
    while (@spec) {
        my $e = shift @spec;
        my $t = type_of($e);
        if ($t == T_BOOL) { $adding = $e ? 1 : 0 }
        elsif (defined(my $lo = $single->($e))) {
            my $hi = @spec ? $single->($spec[0]) : undef;
            defined $hi ? shift @spec : ($hi = $lo);
            $lo >= 0 && $lo <= $hi && $hi <= 0x10FFFF or return $c->fault('invalid character range');
            push @rule, [ $adding, $lo, $hi ];
        }
        elsif ($t == T_STR) { push @rule, map { [ $adding, $_, $_ ] } map { ord } split //, $e }
        elsif (((row(\%EXPR, $e) // {})->{name} // '') eq 'EXPR') {
            # a computed name is looked up when used; a literal one must name another set
            @$e == 2 or return $c->fault('wrong number of arguments to EXPR');
            my $set = ref $e->[1] || ($c->peek($ctx, $e) // '') eq 'CHARS';
            push @rule, [ $adding, $set ? $c->match({ %$ctx, seq => 0, top => 0, cap => 0 }, $e)->{code} : $not_a_set ];
        }
        else { return $c->fault('invalid member of a character set') }
    }
    # A set that refers to no other is known now, as ranges: each rule in
    # turn takes its range out of what there is, and puts it back if it adds.
    my @set = $full ? [ 0, 0x10FFFF ] : ();
    for (grep { @$_ == 3 } @rule) {
        my ($adds, $lo, $hi) = @$_;
        @set = map { my ($a, $b) = @$_; $b < $lo || $a > $hi ? $_ : (($a < $lo ? [ $a, $lo - 1 ] : ()), ($b > $hi ? [ $hi + 1, $b ] : ())) } @set;
        push @set, [ $lo, $hi ] if $adds;
    }
    my $chars = (grep { @$_ == 2 } @rule) ? undef : \@set;
    @rule = reverse @rule;      # the last rule that mentions a character decides
    my %re = $chars ? (re => JGraft::Compiler::re_set($chars), fixed => 1) : ();
    return { chars => $chars, %re, throws => !!(grep { @$_ == 2 } @rule), code => sub {
        my $cp = created_as_number($_[1]) ? $_[1] : is_str($_[1]) && length $_[1] == 1 ? ord $_[1] : return 0;
        for my $rule (@rule) {
            return $rule->[0] if @$rule == 2 ? $rule->[1]->(@_) : $rule->[1] <= $cp && $cp <= $rule->[2];
        }
        $full;
    } };
};

1;
