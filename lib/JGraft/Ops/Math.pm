package JGraft::Ops::Math;

# Casts, comparison and arithmetic.

use v5.36;
use builtin qw(created_as_number);
no warnings qw(experimental::builtin recursion);
use POSIX qw(floor);
use List::Util qw(min);
use JGraft::Util;
use JGraft::Date;
use JGraft::Compiler qw(defop);

use constant INF => 9**9**9;

# JSON number syntax, also allowing a leading '+' and a trailing '.'.
our $NUMBER = qr/\A[-+]?(?:0|[1-9][0-9]*)(?:\.[0-9]*)?(?:[eE][-+]?[0-9]+)?\z/;

# Every computed number passes through here.
sub number ($x, $n) {
    $n == $n          or $x->fail_target('the result is not a number');
    abs($n) != INF    or $x->fail(UNSUPPORTED_GRAFT => 'number out of range');
    return $n;
}

#---------------------------------------------------------------------------
# Casts: [CASTxxx] applies to the current node, [CASTxxx, value] to a value.

my %CAST = (
    CASTBOOL => [ 68, sub ($x, $v) {
        my $t = type_of($v);
        return $t == T_BOOL ? ($v ? $TRUE : $FALSE)
             : $t == T_NUM && ($v == 0 || $v == 1) ? ($v ? $TRUE : $FALSE)
             : $t == T_STR && $v eq 'true'  ? $TRUE
             : $t == T_STR && $v eq 'false' ? $FALSE
             : $x->fail_target('cannot be cast to a boolean');
    } ],
    CASTNUM => [ 69, sub ($x, $v) {
        return $v if created_as_number($v);
        is_str($v) && $v =~ $NUMBER or $x->fail_target('cannot be cast to a number');
        my $n = number($x, 0 + $v);
        $n != 0 || $v !~ /^[^eE]*[1-9]/ or $x->fail(UNSUPPORTED_GRAFT => 'number out of range');   # underflow
        return $n;
    } ],
    CASTSTR => [ 70, sub ($x, $v) {
        my $t = type_of($v);
        return $t == T_STR  ? $v
             : $t == T_BOOL ? ($v ? 'true' : 'false')
             : $t == T_NUM  ? (!is_int($v) || "$v" =~ /^-?\d+\z/ ? "$v" : sprintf '%.0f', $v)
             : $t >= T_DATE && $t <= T_TIMESTAMP ? $v->str
             : $x->fail_target('cannot be cast to a string');
    } ],
    CASTDATE => [ 71, sub ($x, $v) {
        return JGraft::Date::cast($v) // $x->fail_target('cannot be cast to a date');
    } ],
);

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
    return $a <=> $b // $x->fail_target('cannot compare NaN') if $t == T_NUM;
    return $a cmp $b                                         if $t == T_STR;
    return ($a ? 1 : 0) <=> ($b ? 1 : 0)                     if $t == T_BOOL;
    return $a->cmp($b)                                       if $t >= T_DATE && $t <= T_TIMESTAMP;
    $t == T_ARR or $x->fail_target('values of this type have no order');
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

# ADD and MUL take any number of numbers, or one array of them.
for ([ ADD => 74, 0, sub { $_[0] + $_[1] } ], [ MUL => 76, 1, sub { $_[0] * $_[1] } ]) {
    my ($op, $id, $identity, $combine) = @$_;
    defop $op, $id, 'fn', 'V*', sub ($c, $ctx, @arg) {
        my @get = map { $_->{code} } @arg;
        sub {
            my $x = $_[0];
            my @n = map { $_->(@_) } @get;
            @n = @{ $n[0] } if @n == 1 && ref $n[0] eq 'ARRAY';
            $x->charge(scalar @n);
            my $result = $identity;
            for my $n (@n) {
                created_as_number($n) or $x->fail_target("$op needs numbers");
                $result = $combine->($result, $n);
            }
            number($x, $result);
        };
    };
}

my %BINARY = (
    SUB => [ 75, sub ($x, $a, $b) { $a - $b } ],
    DIV => [ 77, sub ($x, $a, $b) { $b == 0 ? $x->fail_target('division by zero') : $a / $b } ],
    # the result takes the sign of the divisor
    MOD => [ 78, sub ($x, $a, $b) { $b == 0 ? $x->fail_target('division by zero') : $a - $b * floor($a / $b) } ],
    POW => [ 79, sub ($x, $base, $power) {
        $base >= 0 && ($base > 0 || $power >= 0) or $x->fail_target('POW of an invalid base or exponent');
        my $r = $base**$power;      # exact for integers while the result fits
        $r != 0 || $base == 0 or $x->fail(UNSUPPORTED_GRAFT => 'number out of range');
        return $r;
    } ],
    LOG => [ 80, sub ($x, $base, $n) {
        $base > 0 && $base != 1 && $n > 0 or $x->fail_target('LOG of an invalid base or value');
        my $r     = log($n) / log($base);
        my $whole = floor($r + 0.5);
        return abs($r - $whole) < 1e-9 && $base**$whole == $n ? $whole : $r;     # exact powers give integers
    } ],
);

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
    my $mode = exists $o->{mode} ? choice($x, \%MODE, $o->{mode}) : 1;
    my $as   = exists $o->{as}   ? choice($x, \%AS,   $o->{as})   : created_as_number($v) ? 0 : 2;
    my $at   = $o->{at} // 0;

    my $text = created_as_number($v) && $v - $v == 0 ? $CAST{CASTSTR}[1]->($x, $v) : $v;
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
        my $n = number($x, 0 + ($e >= 0 && length($digits) + $e <= 18 ? $sign . $digits . '0' x $e : "$sign${digits}e$e"));
        $n != 0 || $zero or $x->fail(UNSUPPORTED_GRAFT => 'number out of range');
        return $n;
    }
    if ($as == 1) {         # an integer, exactly
        if ($e < 0) {
            substr($digits, $e) !~ /[1-9]/ && -$e <= length $digits or $zero or $x->fail_target('not an integer');
            $digits = -$e < length $digits ? substr $digits, 0, $e : '0';
        }
        elsif (!$zero) {
            length($digits) + $e <= 19 or $x->fail(UNSUPPORTED_GRAFT => 'integer out of range');
            $digits .= '0' x $e;
        }
        my $limit = $sign ? '9223372036854775808' : '9223372036854775807';
        length $digits < 19 || length $digits == 19 && $digits le $limit
            or $x->fail(UNSUPPORTED_GRAFT => 'integer out of range');
        return 0 + "$sign$digits";
    }
    if ($as == 2) {         # plain decimal digits, with exactly $at of them after the point
        my $places = $at > 0 ? $at : 0;
        $x->charge(0, 16 + length($digits) + $e + $places);
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

for my $op (sort keys %BINARY) {
    my ($id, $f) = @{ $BINARY{$op} };
    # POW and LOG take their second operand from the current node if omitted
    defop $op, $id, 'fn', ($op =~ /POW|LOG/ ? 'VN?' : 'VV'), sub ($c, $ctx, $left, $right) {
        my ($a, $b) = ($left->{code}, $right->{code});
        sub {
            my ($x, $m, $n) = ($_[0], &$a, &$b);
            created_as_number($m) && created_as_number($n) or $x->fail_target("$op needs numbers");
            number($x, $f->($x, $m, $n));
        };
    };
}

1;
