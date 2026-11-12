package JGraft::Util;

# The value model: how JSON types map onto Perl scalars, and the pure
# functions that compare them.  Nothing here knows about grafts.

use v5.36;
use builtin qw(created_as_number is_bool);
no warnings qw(experimental::builtin recursion non_unicode);
use JSON::PP ();
use JGraft::Number ();
use Exporter 'import';

use constant {
    T_MISSING => 0, T_NULL => 1, T_BOOL => 2, T_NUM => 3, T_STR => 4,
    T_ARR => 5, T_OBJ => 6, T_DATE => 7, T_DATETIME => 8, T_TIMESTAMP => 9, T_OTHER => 10,
};

our @EXPORT = qw(
    T_MISSING T_NULL T_BOOL T_NUM T_STR T_ARR T_OBJ T_DATE T_DATETIME T_TIMESTAMP T_OTHER
    $TRUE $FALSE $MISSING type_of is_str is_num is_int is_idx match_lit sizeof
    STRAY $WIDE mended
);

our $TRUE    = JSON::PP::true;
our $FALSE   = JSON::PP::false;
our $MISSING = bless \(my $nothing = 'nonexistent'), 'JGraft::Missing';

# A byte that is not UTF-8, in a string read by JGraft::JSON, is kept as a
# character past the end of Unicode: STRAY plus the byte (which is 0x80 or
# more).  $WIDE is one well-formed UTF-8 character that is not ASCII, as bytes.
use constant STRAY => 0x110000;
our $WIDE = qr/[\xC2-\xDF][\x80-\xBF]|\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE\xEF][\x80-\xBF]{2}|\xED[\x80-\x9F][\x80-\xBF]
             |\xF0[\x90-\xBF][\x80-\xBF]{2}|[\xF1-\xF3][\x80-\xBF]{3}|\xF4[\x80-\x8F][\x80-\xBF]{2}/x;

# A string that has just been made by joining others.  Such bytes may have
# come to stand side by side that did not before, as when the two halves of
# a character that was cut in two are put together again; and if they now
# spell a character, that is what they are.
sub mended ($s) {
    $s =~ /[\x{110080}-\x{1100FF}]{2}/ or return $s;
    $s =~ s{([\x{110080}-\x{1100FF}]{2,})}{
        my $bytes = join '', map { chr(ord($_) - STRAY) } split //, $1;
        my $read  = '';
        pos($bytes) = 0;
        while (pos($bytes) < length $bytes) {
            if ($bytes =~ /\G($WIDE)/gc) { my $char = $1; utf8::decode($char); $read .= $char }
            else                          { $bytes =~ /\G(.)/gcs; $read .= chr STRAY + ord $1 }
        }
        $read;
    }ge;
    return $s;
}

# A number is one of Perl's own, or a decimal that Perl's own would not hold
# (JGraft::Number, which also reads these two classes as numbers).
my %NUMBER     = map { $_ => 1 } qw(JGraft::Number Math::BigInt Math::BigFloat);
my %CLASS_TYPE = ('JSON::PP::Boolean' => T_BOOL, 'JGraft::Missing' => T_MISSING, map { $_ => T_NUM } keys %NUMBER);

sub type_of {
    my $r = ref $_[0];
    return !defined $_[0] ? T_NULL : created_as_number($_[0]) ? T_NUM : is_bool($_[0]) ? T_BOOL : T_STR
        if $r eq '';
    return $r eq 'HASH' ? T_OBJ : $r eq 'ARRAY' ? T_ARR
         : $r eq 'JGraft::Date' ? $_[0][0] : ($CLASS_TYPE{$r} // T_OTHER);
}

sub is_str { defined $_[0] && !ref $_[0] && !created_as_number($_[0]) && !is_bool($_[0]) }
sub is_num { created_as_number($_[0]) || ref $_[0] && $NUMBER{ ref $_[0] } }

# A finite number with no fractional part.
sub is_int {
    return $_[0] == int $_[0] && $_[0] - $_[0] == 0 if created_as_number($_[0]);
    return ref $_[0] && $NUMBER{ ref $_[0] } && JGraft::Number::whole($_[0]);
}

# Path keys are validated before use: strings name object properties, while
# numbers and undef (the "append position", written `false`) index arrays.
sub is_idx { !defined $_[0] || is_num($_[0]) }

# Does data $v match the plain value $p?  HAS semantics unless $exact.
sub match_lit ($v, $p, $exact, $x = undef) {
    my $t = type_of($p);
    return 0 unless $t == type_of($v);
    return ref $v || ref $p ? !JGraft::Number::order($v, $p) : $v == $p || $JGraft::Number::EXACT && JGraft::Number::equal($v, $p) if $t == T_NUM;
    return $v eq $p   if $t == T_STR;
    return 1          if $t == T_NULL;
    return !$v == !$p if $t == T_BOOL;
    if ($t == T_ARR) {
        return 0 if $exact ? @$v != @$p : @$v < @$p;
        $x->charge(scalar @$p) if $x;
        match_lit($v->[$_], $p->[$_], $exact, $x) or return 0 for 0 .. $#$p;
        return 1;
    }
    if ($t == T_OBJ) {
        return 0 if $exact && scalar(%$v) != scalar(%$p);
        $x->charge(scalar keys %$p) if $x;
        exists $v->{$_} && match_lit($v->{$_}, $p->{$_}, $exact, $x) or return 0 for keys %$p;
        return 1;
    }
    return $t >= T_DATE && $t <= T_TIMESTAMP ? $v->cmp($p) == 0 : 0;
}

# Shallow size estimate, in bytes, for the `mem` limit.
sub sizeof ($v) {
    my $r = ref $v;
    return $r eq 'ARRAY' ? 16 + 8 * @$v : $r eq 'HASH' ? 16 + 16 * scalar(%$v)
         : 16 + (defined $v && !$r ? length $v : 0);
}

1;
