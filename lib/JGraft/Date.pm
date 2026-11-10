package JGraft::Date;

# The three date types, which exist only inside the engine.  An immutable
# array: [ type, year, month, day, hour, minute, second, tz_offset ], cut
# short for a date (3 fields) or a datetime (6).

use v5.36;
use builtin qw(created_as_number);
no warnings qw(experimental::builtin);
use JGraft::Util;

my @FIELD   = qw(year month day hour minute second tz_offset);
my %INDEX   = map { $FIELD[$_] => $_ + 1 } 0 .. $#FIELD;
my @DEFAULT = (undef, 1, 1, 0, 0, 0, 0);
my @DAYS    = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);

# Build from fields; how many are given decides the type.  Undef if invalid.
sub new ($class, @f) {
    my ($y, $m, $d, $h, $min, $s, $tz) = @f = map { $_ + 0 } @f;
    return undef unless abs($y) < 1e9;      # as far as days and minutes can be counted exactly
    my $leap = $y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0);
    return undef unless $m >= 1 && $m <= 12 && $d >= 1 && $d <= $DAYS[ $m - 1 ] + ($m == 2 && $leap ? 1 : 0);
    return undef if @f > 3 && !($h >= 0 && $h <= 23 && $min >= 0 && $min <= 59 && $s >= 0 && $s < 61);
    return undef if @f > 6 && abs($tz) >= 24 * 60;
    return bless [ (@f == 3 ? T_DATE : @f == 6 ? T_DATETIME : T_TIMESTAMP), @f ], $class;
}

# CASTDATE: a date, an ISO 8601 string, or an object of fields.  Undef if not a date.
sub cast ($v) {
    return $v if ref $v eq __PACKAGE__;
    if (ref $v eq 'HASH') {
        return undef if !exists $v->{year} || grep { !$INDEX{$_} } keys %$v;
        for my $name (keys %$v) {
            return undef unless $name eq 'second' ? created_as_number($v->{$name}) : is_int($v->{$name});
        }
        my $count = exists $v->{tz_offset} ? 7 : (grep { exists $v->{$_} } qw(hour minute second)) ? 6 : 3;
        return __PACKAGE__->new(map { $v->{ $FIELD[$_] } // $DEFAULT[$_] } 0 .. $count - 1);
    }
    return undef unless is_str($v);
    my ($y, $m, $d, $h, $min, $s, $fraction, $zone) = $v =~ m{
        \A (?| ([-+]?\d{4,}) - (\d\d) - (\d\d) | (\d{4}) (\d\d) (\d\d) )
        (?: [T ] (\d\d) :? (\d\d) :? (\d\d) (?: [.,] (\d+) )?
            ( Z | [-+\x{2212}] \d\d (?: :? \d\d )? )? )? \z
    }xa or return undef;        # /a: only the digits 0 to 9
    return __PACKAGE__->new($y, $m, $d) unless defined $h;
    $s .= '.' . substr $fraction, 0, 12 if defined $fraction;     # truncated, never rounded up
    return __PACKAGE__->new($y, $m, $d, $h, $min, $s) unless defined $zone;
    my ($sign, $zh, $zm) = $zone eq 'Z' ? ('+', 0, 0) : $zone =~ /^(.)(\d\d):?(\d\d)?/a;
    my $offset = $zh * 60 + ($zm // 0);
    return undef if $zh > 23 || ($zm // 0) > 59 || $sign ne '+' && !$offset;    # "-00:00" is not a zone
    return __PACKAGE__->new($y, $m, $d, $h, $min, $s, $sign eq '+' ? $offset : -$offset);
}

# A virtual property, as used in paths.
sub prop ($d, $name) {
    my $i = $INDEX{ $name // '' };
    return $i && $i < @$d ? $d->[$i] : undef;
}

# Order two dates of the same type.  Timestamps compare as instants.
sub cmp ($a, $b) {
    my @a = @$a[ 1 .. $#$a ];
    my @b = @$b[ 1 .. $#$b ];
    if (@a == 7) { @a = _instant(@a); @b = _instant(@b) }
    $a[$_] <=> $b[$_] and return $a[$_] <=> $b[$_] for 0 .. $#a;
    return 0;
}

# (minutes since an arbitrary epoch in UTC, seconds): leap seconds stay comparable.
sub _instant ($y, $m, $d, $h, $min, $s, $tz) {
    $y-- if $m <= 2;
    my $era  = int(($y >= 0 ? $y : $y - 399) / 400);
    my $yoe  = $y - $era * 400;
    my $doy  = int((153 * ($m > 2 ? $m - 3 : $m + 9) + 2) / 5) + $d - 1;
    my $days = $era * 146097 + $yoe * 365 + int($yoe / 4) - int($yoe / 100) + $doy;
    return ($days * 1440 + $h * 60 + $min - $tz, $s);
}

# CASTSTR, and the default form in which a date leaves the engine.
sub str ($d) {
    my ($type, $y, $m, $day, $h, $min, $s, $tz) = @$d;
    my $date = sprintf '%s%04d-%02d-%02d', ($y < 0 ? '-' : ''), abs $y, $m, $day;
    return $date if $type == T_DATE;
    # seconds to the twelve places that are kept when a string is read, without the zeros that end them
    my ($whole, $fraction) = sprintf('%.12f', $s) =~ /^(\d+)\.(\d*?)0*$/a;
    my $time = sprintf '%02d:%02d:%02d%s', $h, $min, $whole, length $fraction ? ".$fraction" : '';
    return "$date $time" if $type == T_DATETIME;
    return "${date}T$time" . ($tz ? sprintf('%s%02d%02d', $tz < 0 ? '-' : '+', abs($tz) / 60, abs($tz) % 60) : 'Z');
}

1;
