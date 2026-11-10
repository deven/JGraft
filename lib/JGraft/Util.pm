package JGraft::Util;

# The value model: how JSON types map onto Perl scalars, and the pure
# functions that compare them.  Nothing here knows about grafts.

use v5.36;
use builtin qw(created_as_number is_bool);
no warnings qw(experimental::builtin recursion);
use JSON::PP ();
use Exporter 'import';

use constant {
    T_MISSING => 0, T_NULL => 1, T_BOOL => 2, T_NUM => 3, T_STR => 4,
    T_ARR => 5, T_OBJ => 6, T_DATE => 7, T_DATETIME => 8, T_TIMESTAMP => 9, T_OTHER => 10,
};

our @EXPORT = qw(
    T_MISSING T_NULL T_BOOL T_NUM T_STR T_ARR T_OBJ T_DATE T_DATETIME T_TIMESTAMP T_OTHER
    $TRUE $FALSE $MISSING type_of is_str is_int is_idx match_lit sizeof
);

our $TRUE    = JSON::PP::true;
our $FALSE   = JSON::PP::false;
our $MISSING = bless \(my $nothing = 'nonexistent'), 'JGraft::Missing';

my %CLASS_TYPE = ('JSON::PP::Boolean' => T_BOOL, 'JGraft::Missing' => T_MISSING);

sub type_of {
    my $r = ref $_[0];
    return !defined $_[0] ? T_NULL : created_as_number($_[0]) ? T_NUM : is_bool($_[0]) ? T_BOOL : T_STR
        if $r eq '';
    return $r eq 'HASH' ? T_OBJ : $r eq 'ARRAY' ? T_ARR
         : $r eq 'JGraft::Date' ? $_[0][0] : ($CLASS_TYPE{$r} // T_OTHER);
}

sub is_str { defined $_[0] && !ref $_[0] && !created_as_number($_[0]) && !is_bool($_[0]) }

# A finite number with no fractional part.
sub is_int { created_as_number($_[0]) && $_[0] == int $_[0] && $_[0] - $_[0] == 0 }

# Path keys are validated before use: strings name object properties, while
# numbers and undef (the "append position", written `false`) index arrays.
sub is_idx { !defined $_[0] || created_as_number($_[0]) }

# Does data $v match the plain value $p?  HAS semantics unless $exact.
sub match_lit ($v, $p, $exact) {
    my $t = type_of($p);
    return 0 unless $t == type_of($v);
    return $v == $p   if $t == T_NUM;
    return $v eq $p   if $t == T_STR;
    return 1          if $t == T_NULL;
    return !$v == !$p if $t == T_BOOL;
    if ($t == T_ARR) {
        return 0 if $exact ? @$v != @$p : @$v < @$p;
        match_lit($v->[$_], $p->[$_], $exact) or return 0 for 0 .. $#$p;
        return 1;
    }
    if ($t == T_OBJ) {
        return 0 if $exact && keys %$v != keys %$p;
        exists $v->{$_} && match_lit($v->{$_}, $p->{$_}, $exact) or return 0 for keys %$p;
        return 1;
    }
    return $t <= T_TIMESTAMP ? $v->cmp($p) == 0 : 0;
}

# Shallow size estimate, in bytes, for the `mem` limit.
sub sizeof ($v) {
    my $r = ref $v;
    return $r eq 'ARRAY' ? 16 + 8 * @$v : $r eq 'HASH' ? 16 + 16 * keys %$v
         : 16 + (defined $v && !$r ? length $v : 0);
}

1;
