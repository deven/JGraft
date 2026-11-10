package JGraft::Undo;

# A graft that turns one document back into another.
#
# Nothing is recorded while a graft runs.  A run never changes its input, and
# its output shares with the input every part that it left alone, so what the
# run did can be read off afterwards by comparing the two: wherever they are
# the very same array or object, nothing happened, and nothing is looked at.

use v5.36;
use Scalar::Util qw(refaddr);
use JGraft::Util;

# The structure of a graft which, applied to $now, gives $was.
sub graft ($now, $was) {
    my @actions;
    for my $do (changes($now, $was)) {      # consecutive copies make one action, and so do removals
        if (@actions && $actions[-1][0] eq $do->[0] && $do->[0] ne 'SPLICE') { push @{ $actions[-1] }, @$do[ 1 .. $#$do ] }
        else                                                                  { push @actions, $do }
    }
    return [ JGRAFT => { v => 1 }, @actions ];
}

# The actions that change $now, at @path in the document, into $was.
sub changes ($now, $was, @path) {
    return if alike($now, $was);
    my $here = [ NODE => @path ];
    return [ COPY => quote($was), $here ] unless nested($now, $was);
    if (ref $now eq 'HASH') {
        return (
            (map { [ MOVE => [ @$here, $_ ], undef ] } grep { !exists $was->{$_} } sort keys %$now),
            (map {
                exists $now->{$_} ? changes($now->{$_}, $was->{$_}, @path, $_) : [ COPY => quote($was->{$_}), [ @$here, $_ ] ]
            } sort keys %$was),
        );
    }
    # Arrays.  Set aside what the two have in common at each end, which is
    # often nearly everything.
    my ($head, $tail) = (0, 0);
    $head++ while $head < @$now && $head < @$was && alike($now->[$head], $was->[$head]);
    $tail++ while $tail < @$now - $head && $tail < @$was - $head && alike($now->[ -1 - $tail ], $was->[ -1 - $tail ]);
    my ($new, $old) = map { [ @$_[ $head .. $#$_ - $tail ] ] } $now, $was;
    # The last stretch that differs is dealt with first, so that the
    # positions of those before it are still what they are now.
    return map {
        my ($i, $n, $j, $m) = @$_;
        # One element where one was, or arrays and objects where the same
        # were: take it that they changed where they stood.  Otherwise the
        # old elements go back in place of the new.
        my $within = $n == $m && ($n == 1 || !grep { !nested($new->[ $i + $_ ], $old->[ $j + $_ ]) } 0 .. $n - 1);
        $within
            ? (map { changes($new->[ $i + $_ ], $old->[ $j + $_ ], @path, $head + $i + $_) } 0 .. $n - 1)
            : [ SPLICE => [ @$here, $head + $i ], $n, map { quote($_) } @$old[ $j .. $j + $m - 1 ] ];
    } reverse stretches($new, $old);
}

# Are these both arrays, or both objects?
sub nested ($a, $b) { ref $a eq ref $b && (ref $a eq 'ARRAY' || ref $a eq 'HASH') }

# Are these the same without looking inside: one array or object, or two
# equal values of any other kind?
sub alike ($a, $b) {
    return 1 if ref $a && ref $b && refaddr $a == refaddr $b;
    return 0 if grep { ref eq 'ARRAY' || ref eq 'HASH' } $a, $b;
    return match_lit($a, $b, 1);
}

# A string that two values share only if they are alike.
sub key ($v) {
    my $t = type_of($v);
    return $t == T_NULL ? 'null'
         : $t == T_BOOL ? ($v ? 'true' : 'false')
         : $t == T_NUM  ? sprintf('%s %.17g', $v, $v)      # as an integer shows itself, and as a float does
         : $t == T_STR  ? "'$v"
         :                '@' . refaddr $v;
}

# Where two arrays differ: a list of [ i, n, j, m ], each saying that the n
# elements of $new at i stand where the m elements of $old at j did.  Outside
# these stretches the elements of the two are alike, one for one.
#
# This walks the two together.  When they part, each side's element is looked
# for further on in the other, and the nearer of the two finds is where they
# are taken to fall into step again.  That is not always the least change,
# but it is found in one pass, and elements that a graft left alone are
# usually the very same ones, which no other can be mistaken for.
sub stretches ($new, $old) {
    my @new = map { key($_) } @$new;
    my @old = map { key($_) } @$old;
    my (%in_new, %in_old);
    push @{ $in_new{ $new[$_] } }, $_ for 0 .. $#new;
    push @{ $in_old{ $old[$_] } }, $_ for 0 .. $#old;
    my $next = sub ($at, $from) {       # the first of these positions that is not before $from, which only grows
        $at or return;
        shift @$at while @$at && $at->[0] < $from;
        return $at->[0];
    };
    my ($i, $j, @stretch) = (0, 0);
    while ($i < @new || $j < @old) {
        if ($i < @new && $j < @old && $new[$i] eq $old[$j]) { $i++; $j++; next }
        my ($i0, $j0) = ($i, $j);
        while ($i < @new && $j < @old && $new[$i] ne $old[$j]) {
            my $found = $next->($in_old{ $new[$i] }, $j);       # this new element, further on among the old
            my $kept  = $next->($in_new{ $old[$j] }, $i);       # this old element, further on among the new
            if    (!defined $found && !defined $kept)                           { $i++; $j++ }      # one replaced the other
            elsif (!defined $kept || defined $found && $found - $j <= $kept - $i) { $j = $found }   # old elements are gone
            else                                                                  { $i = $kept }    # new elements have come
        }
        ($i, $j) = (scalar @new, scalar @old) if $i == @new || $j == @old;     # what is left of either belongs here
        push @stretch, [ $i0, $i - $i0, $j0, $j - $j0 ];
    }
    return @stretch;
}

# A value written as an expression of a graft: its arrays escaped, and its
# dates as the expressions that make them.
sub quote ($v) {
    my $kind = ref $v;
    return $kind eq 'ARRAY'        ? [ [ map { quote($_) } @$v ] ]
         : $kind eq 'HASH'         ? +{ map { ($_ => quote($v->{$_})) } keys %$v }
         : $kind eq 'JGraft::Date' ? [ CASTDATE => $v->str ]
         :                           $v;
}

1;
