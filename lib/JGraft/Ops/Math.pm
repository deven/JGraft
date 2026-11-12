package JGraft::Ops::Math;

# Casts, comparison and arithmetic.
#
# Arithmetic is Perl's own, as the specification has it.  It is done in
# decimal instead (JGraft::Number) for a run that is to be exact, and for any
# number that is a decimal Perl's own would not hold, whatever the run.

use v5.36;
use builtin qw(created_as_number);
no warnings qw(experimental::builtin recursion);
use POSIX qw(floor fmod);
use List::Util qw(min max);
use JGraft::Util;
use JGraft::Number;
use JGraft::Date;
use JGraft::Compiler qw(defop);

use constant INF => 9**9**9;

# JSON number syntax, also allowing a leading '+' and a trailing '.'.
our $NUMBER = qr/\A[-+]?(?:0|[1-9][0-9]*)(?:\.[0-9]*)?(?:[eE][-+]?[0-9]+)?\z/;

# Every number computed by Perl's own arithmetic passes through here.
sub number ($x, $n) {
    $n == $n          or $x->fail_target('the result is not a number');
    abs($n) != INF    or $x->fail(UNSUPPORTED_GRAFT => 'number out of range');
    return $n;
}

# And every number computed in decimal through here: one that Perl's own
# would not hold is as large as it has digits, and is counted so.
sub decimal ($x, $n) {
    $x->charge(1, 16 + JGraft::Number::digits($n)) if ref $n;
    return $n;
}

# A number given to arithmetic that is one of another module's must be one.
sub finite ($x, @n) {
    ref && ref ne 'JGraft::Number' && ($_->is_nan || $_->is_inf) and $x->fail_target('not a number') for @n;
}

# While a constant expression is evaluated, it is not known whether the runs
# will be exact.  What would come out differently cannot be a constant.
sub undecided ($x) { die "it depends on whether the run is exact\n" if $x->{folding} }

# Is this number held as an integer, exactly?  (One that is whole, but held
# as a float too large to be exact, is not.)
sub exact ($n) { "$n" =~ /\A-?[0-9]+\z/ }

# The widest integers there are, as digits: for a number given as digits to
# be compared with.
sub fits ($sign, $digits) { JGraft::Number::fits($sign . $digits) }

#---------------------------------------------------------------------------
# Casts: [CASTxxx] applies to the current node, [CASTxxx, value] to a value.

my %CAST = (
    CASTBOOL => [ 68, sub ($x, $v) {
        my $t = type_of($v);
        return $t == T_BOOL ? ($v ? $TRUE : $FALSE)
             : $t == T_NUM && ($v == 0 || $v == 1 || !ref $v && JGraft::Number::equal($v, 1)) ? ($v ? $TRUE : $FALSE)
             : $t == T_STR && $v eq 'true'  ? $TRUE
             : $t == T_STR && $v eq 'false' ? $FALSE
             : $x->fail_target('cannot be cast to a boolean');
    } ],
    CASTNUM => [ 69, sub ($x, $v) {
        return $v if is_num($v);
        is_str($v) && $v =~ $NUMBER or $x->fail_target('cannot be cast to a number');
        if ($x->{exact}) {
            # every digit of it is kept; and if Perl's own number keeps them all, that is what it is
            my $n = JGraft::Number::read($v) // $x->fail(UNSUPPORTED_GRAFT => 'number out of range');
            undecided($x), return decimal($x, $n) if ref $n;
        }
        my $n = number($x, 0 + $v);
        $n != 0 || $v !~ /^[^eE]*[1-9]/ or $x->fail(UNSUPPORTED_GRAFT => 'number out of range');   # underflow
        return $n;
    } ],
    CASTSTR => [ 70, sub ($x, $v) {
        my $t = type_of($v);
        return $t == T_STR  ? $v
             : $t == T_BOOL ? ($v ? 'true' : 'false')
             : $t == T_NUM  ? (ref $v ? spelt($x, $v) : !is_int($v) || "$v" =~ /^-?\d+\z/ ? "$v" : sprintf '%.0f', $v)
             : $t >= T_DATE && $t <= T_TIMESTAMP ? $v->str
             : $x->fail_target('cannot be cast to a string');
    } ],
    CASTDATE => [ 71, sub ($x, $v) {
        return JGraft::Date::cast($v) // $x->fail_target('cannot be cast to a date');
    } ],
);

# A decimal that Perl's own number would not hold, written out.
sub spelt ($x, $n) {
    finite($x, $n);
    my $text = JGraft::Number::str($n);
    $x->charge(0, 16 + length $text);
    return $text;
}

for my $op (sort keys %CAST) {
    my ($id, $cast) = @{ $CAST{$op} };
    defop $op, $id, 'fn', 'N?', sub ($c, $ctx, $of) {
        $c->{dates} = 1 if $op eq 'CASTDATE';       # the only source of dates: see JGraft::Exec::outgoing
        my $get = $of->{code};
        sub { $cast->($_[0], &$get) };
    }, dated => $op eq 'CASTDATE';
}

# [DATE]: would CASTDATE accept the current node?
defop DATE => 11, 'match', '', sub ($c, $ctx) {
    sub { defined JGraft::Date::cast($_[1]) };
}, safe => 1;

#---------------------------------------------------------------------------
# Ordering

sub compare ($x, $a, $b) {
    my $t = type_of($a);
    $t == type_of($b) or $x->fail_target('cannot compare values of different types');
    return (ref $a || ref $b ? do { finite($x, $a, $b); JGraft::Number::order($a, $b) } : JGraft::Number::ordered($a, $b)) // $x->fail_target('cannot compare NaN')
        if $t == T_NUM;
    return $a cmp $b                                         if $t == T_STR;
    return ($a ? 1 : 0) <=> ($b ? 1 : 0)                     if $t == T_BOOL;
    return $a->cmp($b)                                       if $t >= T_DATE && $t <= T_TIMESTAMP;
    $t == T_ARR or $x->fail_target('values of this type have no order');
    $x->charge(1 + min($#$a, $#$b));
    for my $i (0 .. min($#$a, $#$b)) {
        my $order = compare($x, $a->[$i], $b->[$i]);
        return $order if $order;
    }
    return @$a <=> @$b;
}

# [LESS, b] compares the current node; [LESS, a, b] compares two values.
for ([ LESS => 72, 0 ], [ LESSEQ => 73, 1 ]) {
    my ($op, $id, $below) = @$_;
    defop $op, $id, 'fn', 'N?V', sub ($c, $ctx, $left, $right) {
        my ($a, $b) = ($left->{code}, $right->{code});
        sub { compare($_[0], &$a, &$b) < $below ? $TRUE : $FALSE };
    };
}

#---------------------------------------------------------------------------
# Arithmetic

# What can be asked of two numbers.  For each: a check that they can be asked
# it (if any is needed), then Perl's own answer, then the answer in decimal.
my %STEP = (
    ADD => [ undef, sub ($x, $a, $b) { $a + $b }, sub ($x, $a, $b) { JGraft::Number::add($a, $b) } ],
    SUB => [ undef, sub ($x, $a, $b) { $a - $b }, sub ($x, $a, $b) { JGraft::Number::sub($a, $b) } ],
    MUL => [ undef, sub ($x, $a, $b) { $a * $b }, sub ($x, $a, $b) { JGraft::Number::mul($a, $b) } ],
    DIV => [
        sub ($x, $a, $b) { $b == 0 and $x->fail_target('division by zero') },
        sub ($x, $a, $b) { $a / $b },
        sub ($x, $a, $b) { JGraft::Number::div($a, $b) },
    ],
    # The result takes the sign of the divisor.  Perl's % does that, exactly,
    # for integers; fmod is exact for the rest, but takes the other sign.
    MOD => [
        sub ($x, $a, $b) { $b == 0 and $x->fail_target('division by zero') },
        sub ($x, $a, $b) {
            return $a % $b if exact($a) && exact($b);
            my $r = fmod($a, $b);
            return $r && ($r < 0 xor $b < 0) ? $r + $b : $r;
        },
        sub ($x, $a, $b) { JGraft::Number::mod($a, $b) },
    ],
    POW => [
        sub ($x, $base, $power) { $base >= 0 && ($base > 0 || $power >= 0) or $x->fail_target('POW of an invalid base or exponent') },
        \&power,
        # A whole power is worked out in decimal, exactly, and its inverse if
        # it is negative.  Any other is Perl's own, and no more exact than that.
        sub ($x, $base, $power) {
            return power($x, 0 + $base, 0 + $power) unless JGraft::Number::whole($power) && abs($power) < 1e15;
            my $n = abs(0 + "$power");
            # (what it will cost is known beforehand: a number of $n times as many digits)
            my $size = JGraft::Number::same(1, (JGraft::Number::least($base))[0]) ? 1 : $n * JGraft::Number::digits($base);
            $size <= 1e9 or $x->fail(UNSUPPORTED_GRAFT => 'number out of range');
            $x->charge($size, $size) if $size > 100;
            my $r = JGraft::Number::pow($base, $n);
            return $power < 0 ? JGraft::Number::div(1, $r) : $r;
        },
    ],
    LOG => [
        sub ($x, $base, $n) { $base > 0 && $base != 1 && $n > 0 or $x->fail_target('LOG of an invalid base or value') },
        \&logarithm,
        sub ($x, $base, $n) { logarithm($x, 0 + $base, 0 + $n) },      # (Perl's own, in any case)
    ],
);

sub power ($x, $base, $power) {
    my $r = $base**$power;
    $r != 0 || $base == 0 or $x->fail(UNSUPPORTED_GRAFT => 'number out of range');
    # A power of integers is to be exact if an integer can hold it.  Perl
    # makes it so up to 2**53; from there to the widest integer, it is
    # worked out again in whole numbers.
    if ($r >= 2**53 && $r < 2**64 && exact($base) && exact($power)) {
        require Math::BigInt;
        my $digits = Math::BigInt->new("$base")->bpow("$power")->bstr;
        return 0 + $digits if fits('', $digits);
    }
    return $r;
}

sub logarithm ($x, $base, $n) {
    my $r     = log($n) / log($base);
    my $whole = floor($r + 0.5);
    return abs($r - $whole) < 1e-9 && $base**$whole == $n ? $whole : $r;     # exact powers give integers
}

# Perl's own operators, for whole numbers: if what they give is whole too, it
# is the answer whether the run is exact or not.
my %WHOLE = (
    ADD => sub { $_[0] + $_[1] }, SUB => sub { $_[0] - $_[1] }, MUL => sub { $_[0] * $_[1] },
    DIV => sub { $_[0] / $_[1] }, MOD => sub { $_[0] % $_[1] }, POW => sub { $_[0]**$_[1] },
);

# One step of arithmetic, where it is not simply Perl's own: the run is to be
# exact, or one of the numbers is a decimal that Perl's own would not hold.
sub exactly ($x, $op, $a, $b) {
    my ($check, $native, $decimal) = @{ $STEP{$op} };
    if (ref $a || ref $b) {
        is_num($a) && is_num($b) or $x->fail_target("$op needs numbers");
        finite($x, $a, $b) if ref $a ne 'JGraft::Number' || ref $b ne 'JGraft::Number';
        $check->($x, $a, $b) if $check;
        # To add 1 to 1e400 is to write the four hundred zeros out, and for more zeros than can be written there is no sum.
        if ($op =~ /ADD|SUB|MOD/ && (my $apart = JGraft::Number::apart($a, $b)) > 100) {
            $apart <= 1e9 or $x->fail(UNSUPPORTED_GRAFT => 'number out of range');
            $x->charge($apart, $apart);
        }
    }
    else {
        created_as_number($a) && created_as_number($b) && $a - $a == 0 && $b - $b == 0 or $x->fail_target("$op needs numbers");
        $check->($x, $a, $b) if $check;
        # (the numbers are what Perl writes them as, as they are in decimal: see JGraft::Number::parts)
        if ($WHOLE{$op} && exact($a) && exact($b)) {
            my $r = $WHOLE{$op}->(0 + "$a", 0 + "$b");
            return $r if exact($r) && $r == int $r;
        }
        undecided($x);
    }
    my $r = $decimal->($x, $a, $b);
    return ref $r ? decimal($x, $r) : number($x, $r);
}

# ADD and MUL take any number of numbers, or one array of them.
for ([ ADD => 74, 0 ], [ MUL => 76, 1 ]) {
    my ($op, $id, $identity) = @$_;
    my $combine = $STEP{$op}[1];
    defop $op, $id, 'fn', 'V*', sub ($c, $ctx, @arg) {
        my @get = map { $_->{code} } @arg;
        sub {
            my $x = $_[0];
            my @n = map { $_->(@_) } @get;
            @n = @{ $n[0] } if @n == 1 && ref $n[0] eq 'ARRAY';
            $x->charge(scalar @n);
            my $result = $identity;
            for my $n (@n) {
                if (ref $n || ref $result || $x->{exact}) {
                    # (the first, if it is exact already, is itself)
                    $result = ref $n && \$n == \$n[0] && is_num($n) ? $n : exactly($x, $op, $result, $n);
                    finite($x, $n) if ref $n;
                    next;
                }
                created_as_number($n) or $x->fail_target("$op needs numbers");
                $result = number($x, $combine->($x, $result, $n));  # checked at each step: what overflows cannot be undone
            }
            $result;
        };
    };
}

#---------------------------------------------------------------------------
# [ROUND, options?, value?]: decimal rounding, done on the digits themselves.

my %MODE = (DOWN => 0, HALF_UP => 1, HALF_EVEN => 2, CEILING => 3, FLOOR => 4, UP => 5);
my %AS   = (NUM => 0, INT => 1, STR => 2, SIG => 3);

# An option given by name or by ID.
sub choice ($x, $table, $v) {
    my ($id) = is_str($v) ? $table->{$v} : is_int($v) ? grep { $_ == $v } values %$table : ();
    return $id // $x->fail_operand('invalid ROUND option');
}

sub round ($x, $o, $v) {
    $o = { shift => $o } if is_int($o);
    ref $o eq 'HASH' && !grep { !/^(?:mode|at|shift|as)$/ } keys %$o or $x->fail_operand('invalid ROUND options');
    !exists $o->{$_} || is_int($o->{$_}) or $x->fail_operand("ROUND $_ must be an integer") for qw(at shift);
    abs($o->{$_} // 0) < 1e15 or $x->fail(UNSUPPORTED_GRAFT => 'exponent out of range') for qw(at shift);
    my $mode = exists $o->{mode} ? choice($x, \%MODE, $o->{mode}) : 1;
    my $as   = exists $o->{as}   ? choice($x, \%AS,   $o->{as})   : is_num($v) ? 0 : 2;
    my $at   = $o->{at} // 0;

    my $text = ref $v ? is_num($v) && spelt($x, $v) : created_as_number($v) && $v - $v == 0 ? $CAST{CASTSTR}[1]->($x, $v) : $v;
    # Is the result, as a number, to have every digit of it?  (For a number that
    # has them all itself, it is, whatever the run: so that much can be a constant.)
    my $every = $x->{exact} || ref $v;
    is_str($text) && $text =~ $NUMBER or $x->fail_target('ROUND needs a number');
    my ($sign, $whole, $fraction, $exponent) = $text =~ /^([-+]?)(\d+)(?:\.(\d*))?(?:[eE]([-+]?\d+))?$/;
    abs($exponent // 0) < 1e15 or $x->fail(UNSUPPORTED_GRAFT => 'exponent out of range');
    $sign = '' if $sign eq '+';

    # The value is $digits x 10**$e; $known is the position of its last significant digit.
    my $digits = $whole . ($fraction // '');
    my $e      = ($exponent // 0) - length($fraction // '') + ($o->{shift} // 0);
    my $known  = $e + (defined $fraction ? 0 : length(($digits =~ /(?<=\d)(0*)$/)[0]));
    $digits =~ s/^0+(?=\d)//;
    $x->charge(length $digits);

    if ($e < -$at) {        # digits below 10**-$at are rounded away
        my $n     = length $digits;
        my $drop  = -$at - $e;
        my $kept  = $drop >= $n ? '0' : substr $digits, 0, $n - $drop;
        my $first = $drop > $n ? 0 : substr $digits, $n - $drop, 1;
        my $more  = ($drop > $n ? $digits : substr $digits, $n - $drop + 1) =~ /[1-9]/;
        my $half  = $first > 5 || $first == 5 && $more ? 1 : $first == 5 ? 0 : -1;    # lost part, against one half
        my $up    = $mode == 0 ? 0
                  : $mode == 1 ? $half >= 0
                  : $mode == 2 ? $half > 0 || $half == 0 && substr($kept, -1) % 2
                  : $mode == 5 ? $first || $more
                  :              ($first || $more) && ($mode == 3 xor $sign eq '-');
        $kept =~ s/([0-8]?)(9*)$/ ($1 eq '' ? 1 : $1 + 1) . '0' x length $2 /e if $up;
        ($digits, $e) = ($kept, -$at);
    }
    my $zero = $digits !~ /[1-9]/;

    if ($as == 0) {         # a number, in whatever form holds it
        if ($every) {
            my $n = JGraft::Number::read("$sign${digits}e$e");
            ref $v or undecided($x), return decimal($x, $n) if ref $n;
        }
        my $whole = $e >= 0 && length($digits) + $e <= 20 ? $digits . '0' x $e : undef;      # kept exact if an integer can hold it
        my $n     = number($x, 0 + (defined $whole && fits($sign, $whole) ? "$sign$whole" : "$sign${digits}e$e"));
        $n != 0 || $zero or $x->fail(UNSUPPORTED_GRAFT => 'number out of range');
        return $n;
    }
    if ($as == 1) {         # an integer, exactly
        my $long;           # the text of it, if it is too long for an integer of Perl's
        if ($e < 0) {
            substr($digits, $e) !~ /[1-9]/ && -$e <= length $digits or $zero or $x->fail_target('not an integer');
            $digits = -$e < length $digits ? substr $digits, 0, $e : '0';
        }
        elsif (!$zero) {
            if (length($digits) + $e > 20) { $long = "$sign${digits}e$e" }
            else                           { $digits .= '0' x $e }
        }
        $long //= "$sign$digits" unless fits($sign, $digits);
        return 0 + "$sign$digits" unless defined $long;
        $every or $x->fail(UNSUPPORTED_GRAFT => 'integer out of range');
        ref $v or undecided($x);
        return decimal($x, JGraft::Number::read($long));
    }
    if ($as == 2) {         # plain decimal digits, with exactly $at of them after the point
        my $places = $at > 0 ? $at : 0;
        $x->charge(0, 16 + max($places + 1, $zero ? 0 : length($digits) + $e + $places));
        $digits = $zero ? '0' x ($places + 1) : $digits . '0' x ($e + $places);
        $digits = '0' x ($places + 1 - length $digits) . $digits if length $digits <= $places;
        substr $digits, -$places, 0, '.' if $places;
        return $sign . $digits;
    }
    # Keeping the significant digits: those down to the coarser of what was
    # known and what was rounded to.  A precision coarser than the units, or
    # ending in a zero, can only be shown in scientific notation.
    my $last = $known > -$at ? $known : -$at;
    $digits = $last - $e < length $digits ? substr $digits, 0, length($digits) - ($last - $e) : '0' if $last > $e;
    if ($last < 0) {
        $x->charge(0, 16 + max(1 - $last, length $digits));
        $digits = '0' x (1 - $last - length $digits) . $digits if length $digits <= -$last;
        substr $digits, $last, 0, '.';
        return $sign . $digits;
    }
    return $sign . $digits if $last == 0 && ($zero || $digits !~ /0$/);
    return "${sign}0e$last" if $zero;
    my $power = length($digits) - 1 + $last;
    substr $digits, 1, 0, '.' if length $digits > 1;
    return "$sign${digits}e$power";
}

defop ROUND => 81, 'fn', 'V?N?', sub ($c, $ctx, @arg) {
    my $get = pop(@arg)->{code};
    my $opt = @arg ? $arg[0]{code} : sub { {} };
    sub { my $o = &$opt; round($_[0], $o, &$get) };
};

my %BINARY = (SUB => 75, DIV => 77, MOD => 78, POW => 79, LOG => 80);
for my $op (sort keys %BINARY) {
    my ($check, $f) = @{ $STEP{$op} };
    # POW and LOG take their second operand from the current node if omitted
    defop $op, $BINARY{$op}, 'fn', ($op =~ /POW|LOG/ ? 'VN?' : 'VV'), sub ($c, $ctx, $left, $right) {
        my ($a, $b) = ($left->{code}, $right->{code});
        sub {
            my ($x, $m, $n) = ($_[0], &$a, &$b);
            return exactly($x, $op, $m, $n) if ref $m || ref $n || $x->{exact};
            created_as_number($m) && created_as_number($n) or $x->fail_target("$op needs numbers");
            $check->($x, $m, $n) if $check;
            number($x, $f->($x, $m, $n));
        };
    };
}

1;
