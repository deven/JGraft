package JGraft::Undo;

# A graft that turns one document back into another.
#
# Nothing is recorded while a graft runs.  A run never changes its input, and
# its output shares with the input every part that it left alone, so what the
# run did can be read off afterwards by comparing the two: wherever they are
# the very same array or object, nothing happened, and nothing is looked at.

use v5.36;
no warnings qw(recursion);
use Scalar::Util qw(refaddr);
use JGraft::Util;

# The structure of a graft which, applied to $now, gives $was.
sub graft ($now, $was) { [ JGRAFT => { v => 1 }, together(changes($now, $was)) ] }

# Actions, with consecutive copies made one action, and removals likewise.
sub together (@do) {
    my @actions;
    for my $do (@do) {
        if (@actions && $actions[-1][0] eq $do->[0] && $do->[0] =~ /^(?:COPY|MOVE)$/) { push @{ $actions[-1] }, @$do[ 1 .. $#$do ] }
        else                                                                          { push @actions, $do }
    }
    return @actions;
}

# The actions that change $now, at @path in the document, into $was.
sub changes ($now, $was, @path) {
    return if alike($now, $was);
    my $here = [ NODE => @path ];
    if (ref $now eq 'HASH' && ref $was eq 'HASH') {
        return (
            (map { [ MOVE => [ @$here, $_ ], undef ] } grep { !exists $was->{$_} } sort keys %$now),
            (map {
                exists $now->{$_} ? changes($now->{$_}, $was->{$_}, @path, $_) : [ COPY => quote($was->{$_}), [ @$here, $_ ] ]
            } sort keys %$was),
        );
    }
    if (ref $now eq 'ARRAY' && ref $was eq 'ARRAY') {
        # The last stretch that differs is dealt with first, so that the
        # positions of those before it are still what they are now.
        return map {
            my ($i, $n, $j, $m) = @$_;
            # One element where one was, or arrays and objects where the same
            # were: take it that they changed where they stood.  Otherwise
            # the old elements go back in place of the new.
            my $within = $n == $m && ($n == 1 || !grep { !nested($now->[ $i + $_ ], $was->[ $j + $_ ]) } 0 .. $n - 1);
            $within
                ? (map { changes($now->[ $i + $_ ], $was->[ $j + $_ ], @path, $i + $_) } 0 .. $n - 1)
                : [ SPLICE => [ @$here, $i ], $n, map { quote($_) } @$was[ $j .. $j + $m - 1 ] ];
        } reverse stretches($now, $was);
    }
    # Strings of several lines that have lines in common are compared as
    # arrays of lines, so that only the lines that changed are put back.
    if (is_str($now) && is_str($was) && $now =~ /\n/ && $was =~ /\n/) {
        my ($new, $old) = map { [ split /\n/, $_, -1 ] } $now, $was;
        my %old = map { $_ => 1 } @$old;
        return [ ATSPLIT => $here, "\n", together(changes($new, $old)) ] if grep { $old{$_} } @$new;
    }
    return [ COPY => quote($was), $here ];
}

# Are these both arrays, or both objects?
sub nested ($a, $b) { ref $a eq ref $b && (ref $a eq 'ARRAY' || ref $a eq 'HASH') }

# Are these the same without looking inside: one array or object, or two
# equal values of any other kind?
sub alike ($a, $b) {
    return 1 if ref $a && ref $b && refaddr $a == refaddr $b;
    return 0 if grep { ref eq 'ARRAY' || ref eq 'HASH' } $a, $b;
    # dates are alike only if written alike: the same moment in another zone is another value
    return ref $b eq 'JGraft::Date' && $a->str eq $b->str if ref $a eq 'JGraft::Date';
    return match_lit($a, $b, 1);
}

# A string that two values share only if they are alike.
sub key ($v) {
    my $t = type_of($v);
    return $t == T_NULL ? 'null'
         : $t == T_BOOL ? ($v ? 'true' : 'false')
         : $t == T_NUM  ? sprintf('%s %.17g', $v, $v)      # as an integer shows itself, and as a float does
         : $t == T_STR  ? "'$v"
         : ref $v eq 'JGraft::Date' ? 'date ' . $v->str
         :                '@' . refaddr $v;
}

#---------------------------------------------------------------------------
# Comparing arrays

# Where two arrays differ: a list of [ i, n, j, m ], each saying that the n
# elements of $now at i stand where the m elements of $was at j did.  Outside
# these stretches the elements of the two are alike, one for one.
sub stretches ($now, $was) {
    # set aside what the two have in common at each end, which is often nearly everything
    my ($head, $tail) = (0, 0);
    $head++ while $head < @$now && $head < @$was && alike($now->[$head], $was->[$head]);
    $tail++ while $tail < @$now - $head && $tail < @$was - $head && alike($now->[ -1 - $tail ], $was->[ -1 - $tail ]);
    my ($new, $old) = map { [ map { key($_) } @$_[ $head .. $#$_ - $tail ] ] } $now, $was;

    # Which of the new elements have come, and which of the old are gone?
    # The least change is looked for with about the effort the rougher way
    # takes, and not at all if too few elements are on both sides for the
    # change to be small enough to find.
    my $most = 1000 + 4 * (@$new + @$old);
    my %left;
    $left{$_}++ for @$old;
    my $apart = @$new + @$old - 2 * grep { $left{$_} && $left{$_}-- } @$new;    # at least this many have come or gone
    my ($come, $gone) = $apart**2 / 2 <= $most ? least($new, $old, $most) : ();
    ($come, $gone) = roughly($new, $old) unless $come;

    # Those left on each side pair off in order, and the others lie between.
    my ($i, $j, @stretch) = (0, 0);
    while ($i < @$new || $j < @$old) {
        my ($i0, $j0) = ($i, $j);
        $i++ while $come->[$i];
        $j++ while $gone->[$j];
        push @stretch, [ $head + $i0, $i - $i0, $head + $j0, $j - $j0 ] if $i > $i0 || $j > $j0;
        $i++, $j++;         # the pair that follows, if there is one
    }
    return @stretch;
}

# The least change there can be between two lists of keys: the fewest
# elements of @$new that have come and of @$old that are gone, as two lists
# of flags.  This is E. W. Myers's algorithm ("An O(ND) Difference Algorithm
# and Its Variations", 1986).  Each round allows one more element to have
# come or gone, and $far[k] is how far into @$new that gets along the
# diagonal k, where the place in @$old is k less.
#
# Its work grows as the square of the change.  When it has made $most
# comparisons it gives up and returns nothing: by then the change is large,
# and the least possible one would not be much smaller than another.
sub least ($new, $old, $most) {
    my ($n, $m) = (scalar @$new, scalar @$old);
    my $mid = $n + $m + 1;                          # where diagonal 0 is kept in @far
    my @far;
    $far[ $mid + 1 ] = 0;
    my @before;                                     # @far as each round found it
    for my $round (0 .. $n + $m) {
        push @before, pack 'l*', map { $_ // 0 } @far[ $mid - $round .. $mid + $round ];
        for (my $k = -$round; $k <= $round; $k += 2) {
            my $down = $k == -$round || $k != $round && $far[ $mid + $k - 1 ] < $far[ $mid + $k + 1 ];
            my $x    = $down ? $far[ $mid + $k + 1 ] : $far[ $mid + $k - 1 ] + 1;
            my $y    = $x - $k;
            my $from = $x;
            $x++, $y++ while $x < $n && $y < $m && $new->[$x] eq $old->[$y];
            $far[ $mid + $k ] = $x;
            ($most -= 1 + $x - $from) >= 0 or return;
            next unless $x >= $n && $y >= $m;
            # Both are used up.  Go back through the rounds by the way that
            # led here, marking the element each one stepped over.
            my (@come, @gone);
            for (my $r = $round; $r > 0; $r--) {
                my @was  = unpack 'l*', $before[$r];        # diagonal k is at $r + k
                my $k    = $x - $y;
                my $down = $k == -$r || $k != $r && $was[ $r + $k - 1 ] < $was[ $r + $k + 1 ];
                $k += $down ? 1 : -1;
                ($x, $y) = ($was[ $r + $k ], $was[ $r + $k ] - $k);
                $down ? ($gone[$y] = 1) : ($come[$x] = 1);
            }
            return (\@come, \@gone);
        }
    }
}

# The same, but found in one pass and not always the least.  The two lists
# are walked together.  Where they part, an element that is nowhere further
# on in the other list has certainly come, or gone.  When both are further
# on, the nearer is taken to be where the lists fall into step again, so a
# wrong guess passes over no more elements than a right one would have.
sub roughly ($new, $old) {
    my (%in_new, %in_old, @come, @gone);
    push @{ $in_new{ $new->[$_] } }, $_ for 0 .. $#$new;
    push @{ $in_old{ $old->[$_] } }, $_ for 0 .. $#$old;
    my $next = sub ($at, $from) {       # the first of these positions that is not before $from, which only grows
        $at or return;
        shift @$at while @$at && $at->[0] < $from;
        return $at->[0];
    };
    my ($i, $j) = (0, 0);
    while ($i < @$new && $j < @$old) {
        if ($new->[$i] eq $old->[$j]) { $i++; $j++; next }
        my $kept  = $next->($in_new{ $old->[$j] }, $i);     # where this old element is, among the new
        my $found = $next->($in_old{ $new->[$i] }, $j);     # where this new element was, among the old
        if    (!defined $kept)            { $gone[ $j++ ] = 1 }
        elsif (!defined $found)           { $come[ $i++ ] = 1 }
        elsif ($found - $j <= $kept - $i) { $gone[ $j++ ] = 1 while $j < $found }
        else                              { $come[ $i++ ] = 1 while $i < $kept }
    }
    $come[$_] = 1 for $i .. $#$new;
    $gone[$_] = 1 for $j .. $#$old;
    return (\@come, \@gone);
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
