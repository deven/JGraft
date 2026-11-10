package JGraft::Seq;

# Sequence matching.  A sequence item is a closure mapping a start position
# to the set of positions where it can end.  The solver decides whether a
# list of items can span a subject, and when captures are wanted, which of
# the possible ways of doing so the specification prefers.

use v5.36;
use List::Util qw(min max);

# Can the items, one after another, span the subject from one of @$starts
# (ending at $end, if that is defined)?
sub possible ($x, $items, $subject, $len, $starts, $end) {
    my @at = @$starts;
    @at = advance($x, $_, $subject, $len, \@at) or return 0 for @$items;
    return defined $end ? scalar grep { $_ == $end } @at : 1;
}

# The places where a match of $item can end, having begun at any of @$at.
sub advance ($x, $item, $subject, $len, $at) {
    $x->charge(scalar @$at);        # each place it is tried from is work, whether or not it matches there
    my $any = $item->{any} or do {
        my ($code, %seen) = $item->{code};
        return grep { !$seen{$_}++ } map { $code->($x, $subject, $_, $len) } @$at;
    };
    # Any elements at all, $lo to $hi of them ([REP] with no pattern).  From
    # each place that is a run of places, and the runs overlap: they are
    # put together, not listed one by one for each place begun from.
    my ($lo, $hi) = @$any;
    my ($next, @to) = (0);
    for my $p (sort { $a <=> $b } @$at) {
        push @to, $p and next if $p > $len && !$lo;     # past the end (see Compiler::single): none is all there can be
        my ($from, $upto) = ($p + $lo, min($len, $p + $hi));
        $from = $next if $from < $next;
        next if $from > $upto;
        push @to, $from .. $upto;
        $next = $upto + 1;
    }
    $x->charge(scalar @to);
    return @to;
}

# Choose among the ways of doing so: find boundaries b[0..m] such that item i
# spans b[i] .. b[i+1], with b[0] among @$starts and b[m] == $end (when
# defined).  Each goal in turn is made a constraint at its best achievable
# value.  A goal is [ 'at', i, 'min'|'max' ] for boundary i, or
# [ 'span', i, 'min'|'max' ] for the length of item i.  Returns the
# boundaries, or nothing if there is no match.
sub solve ($x, $items, $subject, $len, $starts, $end, $goals) {
    my (@memo, %at, %span);
    my $ends = sub ($i, $p) {
        @{ $memo[$i]{$p} //= do { $x->charge(1); [ $items->[$i]{code}->($x, $subject, $p, $len) ] } };
    };
    my $allowed = sub ($i, $p, $q) {
        (!exists $at{ $i + 1 } || $at{ $i + 1 } == $q) && (!exists $span{$i} || $span{$i} == $q - $p);
    };
    # reach->[i]: the positions boundary i can take in some complete match
    my $search = sub {
        my @reach = ({ map { $_ => $_ } grep { !exists $at{0} || $at{0} == $_ } @$starts });
        for my $i (0 .. $#$items) {
            my %to;
            for my $p (values %{ $reach[$i] }) {
                $allowed->($i, $p, $_) and $to{$_} = $_ for $ends->($i, $p);
            }
            return unless %to;
            push @reach, \%to;
        }
        if (defined $end) {
            return unless exists $reach[-1]{$end};
            $reach[-1] = { $end => $end };
        }
        for my $i (reverse 0 .. $#$items) {
            for my $p (values %{ $reach[$i] }) {
                delete $reach[$i]{$p}
                    unless grep { exists $reach[ $i + 1 ]{$_} && $allowed->($i, $p, $_) } $ends->($i, $p);
            }
        }
        return \@reach;
    };
    my $reach = $search->() or return;
    for my $goal (@$goals) {
        my ($what, $i, $prefer) = @$goal;
        my @option = $what eq 'at' ? values %{ $reach->[$i] } : map {
            my $p = $_;
            map { $_ - $p } grep { exists $reach->[ $i + 1 ]{$_} && $allowed->($i, $p, $_) } $ends->($i, $p);
        } values %{ $reach->[$i] };
        ($what eq 'at' ? $at{$i} : $span{$i}) = $prefer eq 'min' ? min @option : max @option;
        $reach = $search->();
    }
    my @b = (min values %{ $reach->[0] });
    for my $i (0 .. $#$items) {
        my $p = $b[-1];
        push @b, min grep { exists $reach->[ $i + 1 ]{$_} && $allowed->($i, $p, $_) } $ends->($i, $p);
    }
    return \@b;
}

# Code that matches the items (compiled nodes) against a subject:
#   $run->($x, $subject, $len, \@starts, $end)  →  true or false
# When captures are being collected it resolves the match the specification
# prefers and records its captures; otherwise it just tests.
sub runner ($items, $leftmost = 0) {
    my @pref  = grep { $items->[$_]{pref} } 0 .. $#$items;
    my @goals = (
        ($leftmost ? [ at => 0, 'min' ] : ()),
        (map { [ span => $_, $items->[$_]{pref} ] } @pref),
        (map { [ at => $_, 'min' ] } @pref),
        (map { [ at => $_, 'min' ] } grep { $items->[$_]{caps} && !$items->[$_]{pref} } 0 .. $#$items),
    );
    my @resolve = map { $_->{caps} ? $_->{resolve} : undef } @$items;
    my $caps    = grep { $_->{caps} } @$items;
    return sub ($x, $subject, $len, $starts, $end) {
        return possible($x, $items, $subject, $len, $starts, $end) unless $caps && $x->{capturing};
        my $b = do { local $x->{capturing} = 0; solve($x, $items, $subject, $len, $starts, $end, \@goals) }
            or return 0;
        $resolve[$_] and $resolve[$_]->($x, $subject, $b->[$_], $b->[ $_ + 1 ], $len) for 0 .. $#$items;
        return 1;
    };
}

1;
