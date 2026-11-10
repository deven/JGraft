package JGraft::Ops::Split;

# SPLIT and JOIN, and the split specification they share with ATSPLIT.

use v5.36;
no warnings qw(experimental::builtin recursion);
use List::Util qw(max first);
use JGraft::Util;
use JGraft::Compiler qw(defop trap row %EXPR);

my %KNOWN = map { $_ => 1 } qw(sep element default keep ltrim rtrim trim discard);

# Compile a split specification: a separator, or an object of options.
# Returns code that evaluates what the specification leaves to run time and
# yields a plan { sep, element, ltrim, rtrim, default, keep, discard }, in
# which each pattern is a string or a sequence closure.  (Or returns a fault.)
sub spec ($c, $ctx, $s) {
    my %o = ref $s eq 'HASH' ? %$s : (sep => $s);
    return $c->fault('unknown split option') if grep { !$KNOWN{$_} } keys %o;
    return $c->fault('a split needs a separator') unless exists $o{sep};
    if (exists $o{trim}) {
        return $c->fault('trim excludes ltrim and rtrim') if exists $o{ltrim} || exists $o{rtrim};
        @o{qw(ltrim rtrim)} = ($o{trim}) x 2;
    }
    my $keep = exists $o{keep} ? $o{keep} : '';
    return $c->fault('invalid keep option') unless is_str($keep) && $keep =~ /\A[<>@]\z/ || !exists $o{keep};
    return $c->fault('discard must be a boolean') if exists $o{discard} && type_of($o{discard}) != T_BOOL;
    my $discard = $o{discard} ? 1 : 0;

    # A pattern is a regex if it is a match expression, else a value that
    # must be a string.
    my (%pattern, $tails);
    for my $name (grep { exists $o{$_} } qw(sep element ltrim rtrim)) {
        my $row = row(\%EXPR, $c->deref($ctx, $o{$name}));
        if ($row && $row->{kind} eq 'match') {      # it is matched against the characters of the string
            my $n = $c->binding(['node'],
                sub { $c->match({ scope => $ctx->{scope}, regex => 1, seq => 1, top => 1 }, $o{$name}) });
            my $regex = $name =~ /trim/ && $n->{run} && native(@{ $n->{run} })
                     || $name eq 'sep' && separator($n)
                     || trap($n);
            $pattern{$name} = sub { $regex };
            $tails = $n->{tails} if $name eq 'rtrim';
        }
        else {
            my $get = $c->value($ctx, $o{$name})->{code};
            $pattern{$name} = sub {
                my $str = &$get;
                is_str($str) ? $str : $_[0]->fail_operand('split pattern must be a string');
            };
        }
    }
    my $default = exists $o{default} ? $c->value($ctx, $o{default})->{code} : undef;

    return sub {
        my @env  = @_;
        my %plan = (keep => $keep, discard => $discard, tails => $tails, map { $_ => $pattern{$_}->(@_) } keys %pattern);
        # only a JOIN wants the default separator, and only once
        $plan{default} = sub {
            $plan{value} //= $default ? $default->(@env) : $env[0]->fail_operand('JOIN needs a default separator');
            is_str($plan{value}) ? $plan{value} : $env[0]->fail_operand('default separator must be a string');
        };
        \%plan;
    };
}

# A trimming is nearly always a run of characters from one set, such as
# spaces.  Perl can find one of those far faster than the closures for the
# pattern can, so it is given the job: `front` matches the run at the start
# of a string, and `back` a run of any length there, for use on a piece that
# has been reversed.  (Nothing is returned if Perl will not have the set, and
# the pattern is then used as it is.)
sub native ($chars, $lo, $hi) {
    my $class = join '', map { sprintf '\\x{%X}-\\x{%X}', @$_ } @$chars;
    my $count = sprintf '{%d,%s}', $lo, $hi == 9**9**9 ? '' : sprintf '%d', $hi;
    return eval { no warnings; +{ front => qr/^[$class]$count/, back => qr/^[$class]+/, lo => $lo, hi => $hi } };
}

# A separator can be found by Perl if what its regex matches first at a
# place is the longest match there, as the specification requires, and is
# never empty.  That is so for a choice of strings and single characters.
sub separator ($n) {
    ($n->{width} // ($n->{longest} && $n->{least})) or return;
    return eval { no warnings; qr/$n->{re}/ };
}

# Where the longest match of a pattern at $p ends, within the first $len
# characters of the subject; undef if it does not match.
sub longest ($x, $pattern, $subject, $p, $len) {
    return max $pattern->($x, $subject, $p, $len) if ref $pattern;
    my $n = length $pattern;
    return $p + $n <= $len && substr($$subject, $p, $n) eq $pattern ? $p + $n : undef;
}

# Does the pattern match exactly the span $p .. $q?
sub spans ($x, $pattern, $subject, $p, $q) {
    return !!grep { $_ == $q } $pattern->($x, $subject, $p, $q) if ref $pattern;
    return substr($$subject, $p, $q - $p) eq $pattern;
}

sub split_string ($x, $plan, $s) {
    my ($sep, $element, $keep) = @$plan{qw(sep element keep)};
    my $len = length $s;
    $x->charge($len, 16 + $len);
    my (@part, @sep);
    my ($start, $q, $carried) = (0, 0, '');     # start of the element; where a separator is sought
    my $perl = ref $sep eq 'Regexp';                                # which Perl can search for,
    my $literal = !ref $sep && length $sep;                         # or simply look up
    if (!$len && !$perl && defined longest($x, $sep, \$s, 0, 0)) {              # no characters to tell apart
        $x->charge_obj;
        return [];
    }
    while ($q <= $len) {
        my $end;
        if ($perl) {
            pos($s) = $q;
            $s =~ /$sep/g or last;
            ($q, $end) = ($-[0], $+[0]);
        }
        else {
            if ($literal) { $q = index $s, $sep, $q; last if $q < 0 }
            $end = longest($x, $sep, \$s, $q, $len);
        }
        # an empty separator counts only between two characters of an element
        # and an element must be all that its own pattern says, from its start to its end
        my $text = defined $end ? substr $s, $start, $q - $start : undef;
        if (defined $end && ($end > $q || $q > $start && $q < $len)
            && (!defined $element || spans($x, $element, \$text, 0, length $text))) {
            my $found = substr $s, $q, $end - $q;
            push @part, $keep eq '<' ? $text . $found : $keep eq '>' ? $carried . $text : $text;
            push @part, $found if $keep eq '@';
            push @sep, $found;
            $carried = $found;
            $start = $q = $end;
        }
        else { $q++ }
    }
    push @part, ($keep eq '>' ? $carried : '') . substr($s, $start);
    push @sep, $sep[-1];        # the last element has no separator; it borrows its neighbour's

    my ($ltrim, $rtrim) = @$plan{qw(ltrim rtrim)};
    my @m = map { [ (ref $sep && !$keep ? $sep[$_] : undef), undef, undef ] } 0 .. $#part;
    if (defined $ltrim || defined $rtrim) {
        # where Perl does the trimming: its patterns, and the count of what it trims, to be charged for
        my ($front, $back) = map { ref eq 'HASH' ? $_ : undef } $ltrim, $rtrim;
        my ($at_front, $at_back, $lo, $hi) = ($front && $front->{front}, $back && @$back{qw(back lo hi)});
        my ($found, $i) = (0, -1);
        for my $text (@part) {      # each piece, where it lies
            $i++;
            my $lead = $at_front       ? ($text =~ $at_front ? $+[0] : 0)
                     : defined $ltrim  ? longest($x, $ltrim, \$text, 0, length $text)
                     :                   0;
            $m[$i][1] = substr $text, 0, $lead, '' if $lead;
            # the right trimming is the longest match that ends where the text does
            my $n   = length $text;
            my $cut = $n;
            if ($at_back) {                         # the run at the end is the run at the start, seen backwards
                my $run = reverse($text) =~ $at_back ? $+[0] : 0;
                $run  = $hi if $run > $hi;
                $cut -= $run if $run >= $lo;
            }
            elsif (ref $rtrim && $plan->{tails}) {  # a run of characters: work back from the end, one at a time,
                $cut-- while $cut && spans($x, $rtrim, \$text, $cut - 1, $cut);
                $cut++ until $cut == $n || spans($x, $rtrim, \$text, $cut, $n);    # and no further than its limit allows
            }
            elsif (defined $rtrim) {
                my @begin = ref $rtrim ? 0 .. $n - 1 : grep { $_ >= 0 } $n - length $rtrim;
                $cut = (first { spans($x, $rtrim, \$text, $_, $n) } @begin) // $n;
            }
            $m[$i][2] = substr $text, $cut, $n - $cut, '' if $cut < $n;
            $found += ($at_front ? $lead : 0) + ($at_back ? $n - $cut : 0);
            @{ $m[$i] }[ 1, 2 ] = () if $plan->{discard};
        }
        $x->charge($found);
    }
    $x->charge(scalar @part, 16 + 8 * @part);
    $x->charge_obj;
    # Metadata is only worth keeping if it says something a JOIN could not know.
    $x->carry(\@part, ++$x->{origins}, @m) if grep { grep { defined } @$_ } @m;
    return \@part;
}

# The elements of $a as one string.  $$begins, if asked for, is set to where
# the text of element $mark begins in it.
sub join_array ($x, $plan, $a, $mark = -1, $begins = undef) {
    my $sep     = $plan->{sep};
    my $between = $plan->{keep} ? '' : ref $sep ? undef : $sep;     # fixed, unless separators were captured
    my $default = $between // $plan->{default}->();
    ref $a eq 'ARRAY' && !grep { !is_str($_) } @$a or $x->fail_target('JOIN needs an array of strings');
    my $split = $x->split_of($a);
    my $out   = '';
    for my $i (0 .. $#$a) {
        my ($found, $left, $right) = $split ? @{ $split->{m}[$i] // [] } : ();
        $$begins = length($out) + ($plan->{discard} ? 0 : length($left // '')) if $i == $mark;
        $out .= $plan->{discard} ? $a->[$i] : ($left // '') . $a->[$i] . ($right // '');
        $out .= $between // $found // $default if $i < $#$a;
    }
    $x->charge(scalar @$a, 16 + length $out);
    return $out;
}

# [SPLIT, spec, string?] and [JOIN, spec, array?]
for ([ SPLIT => 62, \&split_string, \&is_str, 'a string' ],
     [ JOIN  => 63, \&join_array,   sub { 1 }, '' ]) {
    my ($op, $id, $do, $accepts, $what) = @$_;
    defop $op, $id, 'fn', 'XN?', sub ($c, $ctx, $s, $of) {
        my $plan = spec($c, $ctx, $s);
        return $plan if ref $plan eq 'HASH';        # a fault
        my $get = $of->{code};
        sub {
            my $p = &$plan;         # the specification is checked before the input
            my $v = &$get;
            $accepts->($v) or $_[0]->fail_target("$op needs $what");
            $do->($_[0], $p, $v);
        };
    };
}

1;
