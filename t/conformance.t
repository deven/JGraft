#!/usr/bin/env perl

# Runs every case in conformance/*.json, once with eager validation of the
# graft and once with lazy.
#
#   JGRAFT_FILES=regex   only run matching files
#   JGRAFT_MODE=1|0      only run strict (1) or lazy (0)
#   JGRAFT_SHOW=n        show the first n failures of each file (default 5)

use v5.36;
use builtin qw(created_as_number);
no warnings qw(experimental::builtin surrogate nonchar utf8);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use JSON::PP;
use JGraft;
use JGraft::Util qw(match_lit);

my $only = $ENV{JGRAFT_FILES};
my $show = $ENV{JGRAFT_SHOW} // 5;
my $json = JSON::PP->new->canonical->allow_nonref->allow_blessed->ascii;
sub show ($v) { eval { $json->encode($v) } // "<unencodable: $@>" }

# JSON decoders reject lone surrogate escapes, which the suite uses.  Hide
# each one behind a two-character marker, then put it back after decoding.
# JSON::PP also turns integers too long for the machine into strings; write
# those as decimals so that they stay numbers.
sub load ($file) {
    open my $fh, '<:raw', $file or die "$file: $!";
    my $text = do { local $/; <$fh> };
    $text =~ s{((?:\\u[0-9a-fA-F]{4})+)|\\.}{ defined $1 ? hide($1) : $& }ges;
    $text =~ s{("(?:[^"\\]|\\.)*")|(-?\d{20,})(?![\d.eE])}{ $1 // "$2.0" }ges;
    return reveal(JSON::PP->new->utf8->max_depth(1e6)->decode($text));
}

sub hide ($run) {
    my @unit = map { hex } $run =~ /\\u(....)/g;
    my $out  = '';
    while (@unit) {
        my $u = shift @unit;
        if ($u >= 0xD800 && $u <= 0xDBFF && @unit && $unit[0] >= 0xDC00 && $unit[0] <= 0xDFFF) {
            $out .= sprintf '\\u%04x\\u%04x', $u, shift @unit;
        }
        elsif ($u >= 0xD800 && $u <= 0xDFFF) { $out .= sprintf '\\ufdd0\\u%04x', 0xE000 + $u - 0xD800 }
        else                                 { $out .= sprintf '\\u%04x', $u }
    }
    return $out;
}

sub reveal ($v) {
    if    (ref $v eq 'ARRAY') { $_ = reveal($_) for @$v }
    elsif (ref $v eq 'HASH')  { %$v = map { reveal($_) => reveal($v->{$_}) } keys %$v }
    elsif (defined $v && !ref $v && !created_as_number($v)) {
        $v =~ s/\x{FDD0}([\x{E000}-\x{E7FF}])/chr(0xD800 + ord($1) - 0xE000)/ge;
    }
    return $v;
}

sub cases ($group, $path = '') {
    return map { $_->{tests} ? cases($_, "$path$_->{name} / ") : [ "$path$_->{name}", $_ ] } @{ $group->{tests} };
}

sub same ($got, $want) { match_lit($got, $want, 1) && match_lit($want, $got, 1) }

# Returns nothing if the case passes, else a description of what went wrong.
sub check ($t, $strict) {
    my $allowed = $t->{errors} // {};
    my $before  = show([ $t->{input}, $t->{jgraft} ]);
    my $result  = eval {
        local $SIG{ALRM} = sub { die "timed out\n" };
        alarm 20;
        my $r = JGraft->new($t->{jgraft}, strict => $strict)->run($t->{input}, limits => $t->{limits} // {});
        alarm 0;
        $r;
    };
    alarm 0;
    my $error = $result ? $result->error : $@;
    my $code  = !$error ? '' : ref $error eq 'JGraft::Error' ? $error->code : return "died: $error";
    return 'the input or the graft was modified' if show([ $t->{input}, $t->{jgraft} ]) ne $before;
    if ($t->{logs} && $result) {
        same($result->logs, $t->{logs})
            or return 'logs ' . show($result->logs) . ', expected ' . show($t->{logs});
    }
    return $allowed->{$code} ? () : "unexpected $error; expected " . join('/', sort keys %$allowed)
        . (exists $t->{output} ? ' or output ' . show($t->{output}) : '') if $code;
    return 'succeeded with ' . show($result->output) . ', expected ' . join('/', sort keys %$allowed)
        unless exists $t->{output};
    return same($result->output, $t->{output}) ? ()
        : 'output ' . show($result->output) . ', expected ' . show($t->{output});
}

for my $file (sort glob "$FindBin::Bin/../conformance/*.json") {
    next if $only && $file !~ /$only/;
    my @case = cases(load($file));
    my ($name) = $file =~ m{([^/]+)\.json$};
    for my $strict (grep { !length $ENV{JGRAFT_MODE} || $ENV{JGRAFT_MODE} == $_ } 1, 0) {
        my @failed;
        for (@case) {
            my ($title, $t) = @$_;
            my ($why) = check($t, $strict) or next;
            push @failed, "$title\n      graft: " . show($t->{jgraft}) . "\n      input: "
                . substr(show($t->{input}), 0, 200) . "\n      $why";
        }
        ok(!@failed, sprintf '%s (%s): %d of %d', $name, $strict ? 'strict' : 'lazy', @case - @failed, scalar @case)
            or diag join "\n", map { "  $_" } @failed[ 0 .. ($show < @failed ? $show : @failed) - 1 ];
    }
}

done_testing;
