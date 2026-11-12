package JGraft::Number;

# Decimal numbers, exactly.
#
# One of Perl's own numbers is binary, and so 0.1 + 0.2 is not quite 0.3;
# nor can it hold an integer of thirty digits, or tell 0.30 from 0.3.  Where
# a run is to be exact (see JGraft, EXACT NUMBERS), arithmetic is done here:
# on a whole coefficient and a power of ten, as it would be done on paper.
# 0.30 is 30 and -2.  The rules are those of the General Decimal Arithmetic
# specification, which other languages' decimal types follow: a sum is known
# to as many places as the finer of its terms, a product to as many as its
# factors together, and nothing is rounded but a quotient that never ends.
#
# The result of a calculation is one of Perl's own numbers if, and only if,
# Perl would write that number as the same digits: 0.3 is, and 12.  So
# whatever is done with it afterwards, by Perl or by a JSON encoder, says what
# the exact number said.  It is an object of this class where Perl would write
# something else: 0.30, which Perl would make 0.3; a number of more than the
# fifteen digits Perl writes, or of more than an integer holds; one beyond
# Perl's range.  An object is
# [ coefficient, exponent ], and the coefficient a Math::BigInt if it has
# more than eighteen digits.  It is never changed once made.
#
# Math::BigInt and Math::BigFloat objects are read as numbers too, wherever a
# number is, though none is ever made.

use v5.36;
use overload
    '""'     => \&str,
    '0+'     => sub { 0 + str($_[0]) },
    'bool'   => sub { $_[0][0] != 0 },
    '<=>'    => sub { my $order = order($_[0], $_[1]); $_[2] ? -$order : $order },
    fallback => 1;

my $LONG = 18;          # an integer of this many digits is one that Perl holds, whatever they are

# How many significant digits a quotient that never ends is given.
our $DIGITS = 40;

# The coefficient as Math::BigInt, or as Perl's own integer if it is short enough to be.
sub wide ($c)  { require Math::BigInt; ref $c ? $c : Math::BigInt->new("$c") }
sub lower ($c) { ref $c && $c->length <= $LONG ? 0 + $c->bstr : $c }
sub len ($c)   { ref $c ? $c->length : length(abs $c) }

# The decimal that one of Perl's numbers stands for: the shortest that reads back as it.
sub text ($n) {
    my $text = "$n";
    return $text if $text == $n;
    $text = sprintf '%.16g', $n;
    return $text == $n ? $text : sprintf '%.17g', $n;
}

# The coefficient and exponent written in a text, just as they are written:
# "0.30" is 30 and -2.  Nothing, if the text is not a number.
sub scan ($text) {
    # (most are written plainly, and short)
    return (0 + "$1$2$3", -length $3) if $text =~ /\A(-?)([0-9]+)\.([0-9]+)\z/ && length($2) + length($3) <= $LONG;
    my ($sign, $whole, $fraction, $exponent) = $text =~ /\A([-+]?)([0-9]+)(?:\.([0-9]*))?(?:[eE]([-+]?[0-9]+))?\z/ or return;
    return if length($exponent // '') > 15;
    $fraction //= '';
    my $digits = $whole . $fraction;
    $digits =~ s/\A0+(?=[0-9])//;
    $sign = '' if $sign eq '+';
    return (length $digits <= $LONG ? 0 + "$sign$digits" : wide("$sign$digits"), ($exponent // 0) - length $fraction);
}

# The coefficient and exponent of any number.
sub parts ($n) {
    my $kind = ref $n;
    return @$n if $kind eq __PACKAGE__;
    if (!$kind) {
        my $text = "$n";
        return (0 + $n, 0) if $text =~ /\A-?[0-9]{1,18}\z/;
        return scan($text == $n ? $text : text($n));
    }
    return (lower($n), 0) if $kind eq 'Math::BigInt';
    my ($mantissa, $exponent) = $n->parts;      # Math::BigFloat
    return (lower($mantissa), $exponent->numify);
}

# The widest integers Perl has, as digits, for a number given as digits to be compared with.
my %WIDEST = ('' => '18446744073709551615', '-' => '9223372036854775808');
sub fits ($digits) {
    my $sign   = $digits =~ s/\A-// ? '-' : '';
    my $widest = $WIDEST{$sign};
    return length $digits < length $widest || length $digits == length $widest && $digits le $widest;
}

# The number with this coefficient and exponent: Perl's own, if that says as
# much, and otherwise an object.
sub make ($c, $e) {
    ($c, $e) = least(bless [ $c, $e ]) if $e > 0;     # (a whole number has no places to be known to: 150 thousands are 15 ten-thousands)
    my $length = ref $c ? 0 : length abs $c;
    $c = ref $c ? lower($c) : $length > $LONG ? wide($c) : $c;      # (a sum of two that were short may be long)
    if (ref $c) {
        if ($e >= 0 && $c->length + $e <= 20) {
            my $digits = up($c, $e)->bstr;
            return 0 + $digits if fits($digits);
        }
    }
    elsif (!$e || !$c && $e > 0)             { return $c }
    elsif ($e > 0 && $length + $e <= 20 && fits($c . '0' x $e)) { return 0 + ($c . '0' x $e) }
    elsif ($length <= 15 && abs($e) < 400) {
        # As a number of Perl's it must still say the same digits, to the same
        # place, when Perl writes it: 1.5 does, and 1.50 does not; nor does a
        # number of more than the fifteen digits that Perl writes.  Within its
        # range, fifteen digits that do not end in a zero always do, and are
        # not looked at again.
        return 0 + "${c}e$e" if $e < 0 && $e > -280 && $c % 10;
        my $n = 0 + "${c}e$e";
        if ($n - $n == 0) {
            my ($c2, $e2) = scan("$n");
            return $n if $e2 == $e && $c2 == $c;
        }
    }
    return bless [ $c, $e ], __PACKAGE__;
}

# The number written in a text (or nothing, if none is).
sub read ($text) {
    my ($c, $e) = scan($text) or return;
    return make($c, $e);
}

# A coefficient, with $k more zeros.
sub up ($c, $k) {
    return $c if !$k || !ref $c && !$c;
    return 0 + ($c . '0' x $k) if !ref $c && length(abs $c) + $k <= $LONG;
    return wide($c)->copy->blsft($k, 10);
}

# Two numbers as coefficients of one power of ten, and that power.
sub level ($a, $b) {
    my ($c1, $e1, $c2, $e2) = (parts($a), parts($b));
    my $e = $e1 < $e2 ? $e1 : $e2;
    return (up($c1, $e1 - $e), up($c2, $e2 - $e), $e);
}

#---------------------------------------------------------------------------
# Arithmetic.  Each takes numbers of any kind, and returns one as `make` does.

sub add ($a, $b) { my ($c1, $c2, $e) = level($a, $b); make($c1 + $c2, $e) }
sub sub ($a, $b) { my ($c1, $c2, $e) = level($a, $b); make($c1 - $c2, $e) }

sub mul ($a, $b) {
    my ($c1, $e1, $c2, $e2) = (parts($a), parts($b));
    return make(!ref $c1 && !ref $c2 && length(abs $c1) + length(abs $c2) <= $LONG ? $c1 * $c2 : wide($c1) * $c2, $e1 + $e2);
}

# The remainder, which takes the sign of the divisor (which is not zero).
sub mod ($a, $b) { my ($c1, $c2, $e) = level($a, $b); make(ref $c1 || ref $c2 ? wide($c1) % $c2 : $c1 % $c2, $e) }

# A whole number as the least coefficient it can have: 1000 as 1 and 3.
sub least ($n) {
    my ($c, $e) = parts($n);
    return ($c, $e) unless $e >= 0 && $c != 0 && (my $digits = ref $c ? $c->bstr : "$c") =~ s/(0+)\z//;
    return (length $digits <= $LONG ? 0 + $digits : wide($digits), $e + length $1);
}

# How far apart two numbers' last places are: what it costs to add them.
sub apart ($a, $b) { abs((parts($a))[1] - (parts($b))[1]) }

# $a to the power $n: a whole number of Perl's own, and not negative.
sub pow ($a, $n) {
    my ($c, $e) = least($a);
    return make(!ref $c && len($c) * $n <= 15 ? 0 + sprintf('%d', $c**$n) : wide($c)->copy->bpow($n), $e * $n);
}

# The quotient (of a divisor that is not zero).  It is exact if it ends, and
# is then written with as few places as it needs beyond those of the numbers
# divided; one that does not end is rounded to $DIGITS significant digits.
sub div ($a, $b) {
    my ($c1, $e1, $c2, $e2) = (parts($a), parts($b));
    my $e = $e1 - $e2;
    return make(0, $e < 0 ? $e : 0) if !$c1;
    if (!ref $c1 && !ref $c2 && $c1 % $c2 == 0) {
        use integer;
        return make($c1 / $c2, $e);
    }
    my ($n, $d) = (wide($c1), wide($c2));
    ($n, $d) = (-$n, -$d) if $d < 0;
    my $common = Math::BigInt::bgcd($n, $d);
    ($n, $d) = ($n / $common, $d / $common);
    # It ends if the divisor, in lowest terms, is made of twos and fives alone:
    # then some power of ten is a multiple of it.
    my ($rest, %times) = ($d->copy);
    for my $p (2, 5) {
        $times{$p} = 0;
        $rest /= $p, $times{$p}++ while $rest % $p == 0;
    }
    if ($rest == 1) {
        my $k = $times{2} > $times{5} ? $times{2} : $times{5};
        return make(up($n, $k) / $d, $e - $k);
    }
    my $k = $DIGITS - ($n->length - $d->length);
    $k = 0 if $k < 0;
    my ($quotient, $left) = up($n, $k)->bdiv($d);       # rounded down, with what is left over
    $quotient->binc if $left * 2 > $d;
    return make($quotient, $e - $k);
}

#---------------------------------------------------------------------------
# Comparison

# Which of two numbers is the greater: -1, 0 or 1, as <=> gives.
sub order ($a, $b) {
    # (an infinity, or what is not a number at all, is no decimal; Perl compares those as it does)
    return 0 + $a <=> 0 + $b if grep { !ref && $_ - $_ != 0 } $a, $b;
    my ($c1, $e1, $c2, $e2) = (parts($a), parts($b));
    my ($s1, $s2) = ($c1 <=> 0, $c2 <=> 0);
    return $s1 <=> $s2 if $s1 != $s2 || !$s1;
    # They have the same sign.  The one whose first digit stands further to
    # the left is the larger; only if they stand alike are the digits compared.
    my ($reach1, $reach2) = (len($c1) + $e1, len($c2) + $e2);
    return $s1 * ($reach1 <=> $reach2) if $reach1 != $reach2;
    my $e = $e1 < $e2 ? $e1 : $e2;
    return up($c1, $e1 - $e) <=> up($c2, $e2 - $e);
}

# Are two numbers the same, and known to the same place?  (0.30 and 0.3 are
# equal, and `order` says so, but they are not the same.)
sub same ($a, $b) {
    return $a == $b if !ref $a && !ref $b;
    my ($c1, $e1, $c2, $e2) = (parts($a), parts($b));
    return $e1 == $e2 && $c1 == $c2;
}

# Is a number whole?
sub whole ($n) {
    my ($c, $e) = parts($n);
    return 1 if $e >= 0 || !$c;
    my ($zeros) = (ref $c ? $c->bstr : "$c") =~ /(0*)\z/;
    return length $zeros >= -$e;
}

# How many digits a number has: what it costs to keep.  (Those of a whole
# number that are zeros at its end cost nothing.)
sub digits ($n) { len((least($n))[0]) }

#---------------------------------------------------------------------------
# Writing

# A number as JSON writes one, with every digit it has.  A very small or a
# very large one is written with an exponent.
sub str ($n, @) {
    my ($c, $e) = parts($n);
    my $digits = ref $c ? $c->bstr : "$c";
    my $sign   = $digits =~ s/\A-// ? '-' : '';
    my $length = length $digits;
    my $first  = $length - 1 + $e;          # the power of ten of its first digit
    if ($e <= 0 && $first >= -6) {
        return $sign . $digits if !$e;
        $digits = '0' x (1 - $e - $length) . $digits if $length <= -$e;
        substr $digits, $e, 0, '.';
        return $sign . $digits;
    }
    return $sign . $digits . '0' x $e if $e > 0 && $length + $e <= 21;
    substr $digits, 1, 0, '.' if $length > 1;
    return sprintf '%s%se%+d', $sign, $digits, $first;
}

1;
