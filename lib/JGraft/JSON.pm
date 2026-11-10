package JGraft::JSON;

# JSON read so that it can be written back as it was.
#
#   my $doc  = JGraft::JSON->parse($bytes);
#   my $out  = $graft->apply($doc->data);
#   my $text = $doc->write($out);
#
# `write` gives the original text, changed only where the data changed.  The
# spelling of every value that is still there is kept (1e1, -0, "\u00e9"),
# with the order of properties, duplicate properties, white space, and bytes
# that are not UTF-8; and so is the spelling of a value that has moved, and
# of the parts of a string that a change to it left alone.
#
# The data is ordinary Perl data, except that its objects are ordered hashes
# (JGraft::Ordered), and that beside every array and object is kept where it
# came from in the text (JGraft::Source).
#
# A byte in a string that is not UTF-8 is read as a character beyond the
# last one of Unicode: 0x110000 plus the byte, which is written back as that
# byte.  Those 128 code points (the byte is 0x80 or more) are thereby
# reserved, and nothing else may be read as one of them.  Nothing is: UTF-8
# is taken strictly, so bytes that spell a code point past 0x10FFFF, as
# older forms of UTF-8 and Perl's own allow, are not UTF-8 here, and each is
# read as a byte.  The same goes for surrogates and overlong forms.  And a
# string that holds any other character past 0x10FFFF, which can only have
# been put there by hand, cannot be written at all.

use v5.36;
use builtin qw(created_as_number refaddr);
no warnings qw(experimental::builtin recursion surrogate nonchar non_unicode utf8);
use JGraft::Util;
use JGraft::Ordered;
use JGraft::Source;
use JGraft::Undo;

my %ESCAPE  = ('"' => '"', '\\' => '\\', '/' => '/', b => "\b", f => "\f", n => "\n", r => "\r", t => "\t");
my %ESCAPED = ('"' => '\\"', '\\' => '\\\\', "\b" => '\\b', "\f" => '\\f', "\n" => '\\n', "\r" => '\\r', "\t" => '\\t');

sub data ($doc) { $doc->{data} }
sub text ($doc) { ${ $doc->{text} } }

#---------------------------------------------------------------------------
# Reading

sub parse ($class, $text) {
    utf8::downgrade($text, 1) or utf8::encode($text);       # bytes, however they were handed over
    my $src   = \$text;
    my $fail  = sub ($what) { die sprintf "JGraft::JSON: %s at byte %d\n", $what, pos($text) // 0 };
    my $space = sub { $text =~ /\G[ \t\n\r]*/gc };
    my $string = sub {
        $text =~ /\G"((?:[^"\\]++|\\.)*+)"/gcs or $fail->('a string does not end');
        return unquote($1) // $fail->('a string has an escape that means nothing');
    };
    my $value;
    $value = sub {
        $space->();
        my $start = pos($text) // 0;
        my ($v, $record);
        if ($text =~ /\G\{/gc) {
            $v      = JGraft::Ordered::hash();
            $record = { text => $src, start => $start, members => \my @member };
            $space->();
            until ($text =~ /\G\}/gc) {
                !@member || $text =~ /\G,/gc or $fail->('expected , or }');
                $space->();
                my $at = pos $text;
                substr($text, $at, 1) eq '"' or $fail->('expected the name of a property');
                my $key = $string->();
                my $to  = pos $text;
                $space->();
                $text =~ /\G:/gc or $fail->('expected :');
                ($v->{$key}, my $token) = $value->();
                push @member, [ $key, $at, $to, $token ];
                $space->();
            }
        }
        elsif ($text =~ /\G\[/gc) {
            $v      = [];
            $record = { text => $src, start => $start, items => \my @item };
            $space->();
            until ($text =~ /\G\]/gc) {
                !@item || $text =~ /\G,/gc or $fail->('expected , or ]');
                (my $element, my $token) = $value->();
                push @$v,   $element;
                push @item, $token;
                $space->();
            }
        }
        elsif (substr($text, $start, 1) eq '"') { $v = $string->() }
        elsif ($text =~ /\G(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)/gc) { $v = 0 + $1 }
        elsif ($text =~ /\Gtrue\b/gc)   { $v = $TRUE }
        elsif ($text =~ /\Gfalse\b/gc)  { $v = $FALSE }
        elsif ($text =~ /\Gnull\b/gc)   { $v = undef }
        else                            { $fail->('expected a value') }
        my $end = pos $text;
        if ($record) {
            $record->{end} = $end;
            JGraft::Source::read_as($v, $record);
        }
        return ($v, [ $start, $end, $src ]);
    };
    my ($data, $root) = $value->();
    $space->();
    pos($text) == length $text or $fail->('there is something after the value');
    undef $value;       # (it refers to itself)
    return bless { text => $src, data => $data, root => $root }, $class;
}

# What is between the quotes of a string, as characters: or nothing, if an
# escape in it is not one that JSON has.
sub unquote ($body) {
    if ($body !~ /\\/) {        # the usual case: no escapes, and (as is then checked) good UTF-8
        my $s = $body;
        return $s if utf8::decode($s) && $s !~ /[^\x{0}-\x{D7FF}\x{E000}-\x{10FFFF}]/;
    }
    my $s = '';
    pos($body) = 0;
    while (pos $body < length $body) {
        if ($body =~ /\G([\x00-\x5B\x5D-\x7F]+)/gc) { $s .= $1 }
        elsif ($body =~ /\G((?:$WIDE)+)/gc)        { my $run = $1; utf8::decode($run); $s .= $run }
        elsif ($body =~ /\G\\u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})/gc) {
            $s .= chr 0x10000 + ((hex($1) - 0xD800) << 10) + hex($2) - 0xDC00;
        }
        elsif ($body =~ /\G\\u([0-9a-fA-F]{4})/gc)  { $s .= chr hex $1 }
        elsif ($body =~ /\G\\(["\\\/bfnrt])/gc)     { $s .= $ESCAPE{$1} }
        elsif ($body =~ /\G\\/gc)                   { return undef }
        else { $body =~ /\G(.)/gcs; $s .= chr STRAY + ord $1 }      # a byte (0x80 or more) that is not UTF-8
    }
    return $s;
}

#---------------------------------------------------------------------------
# Writing

# The text of the document with $value as its data.
sub write ($doc, $value = $doc->{data}) {
    my ($start, $end, $text) = @{ $doc->{root} };
    return substr($$text, 0, $start) . emit($value, $doc->{root}) . substr($$text, $end);
}

# The text of any value, on its own: what was read from a text as it was,
# and the rest as plainly as JSON can be written.
sub encode ($class, $value) { emit($value, undef) }

# A value as text.  $hint is the token of the place it is in, if there is
# one: where in some text the value there was written.
sub emit ($v, $hint) {
    my $kind = ref $v;
    if ($kind eq 'ARRAY' || $kind eq 'HASH') {
        my $sheet = JGraft::Source::sheet($v) // {};
        my $rec   = $sheet->{rec};
        return substr ${ $rec->{text} }, $rec->{start}, $rec->{end} - $rec->{start} if $rec;       # just as it was read
        return $kind eq 'ARRAY' ? array($v, @$sheet{qw(from tok)}) : object($v, @$sheet{qw(from tok)});
    }
    if ($hint) {
        my $token = substr ${ $hint->[2] }, $hint->[0], $hint->[1] - $hint->[0];
        if ($token !~ /^[\[{]/) {
            my $was = $token =~ /^"/ ? unquote(substr $token, 1, -1) : $token eq 'true' ? $TRUE : $token eq 'false' ? $FALSE
                    : $token eq 'null' ? undef : 0 + $token;
            return $token if type_of($was) == type_of($v) && match_lit($v, $was, 1);       # it says what the value still is
            return '"' . patched($token, $was, $v) . '"' if is_str($v) && is_str($was);
        }
    }
    return scalar_text($v);
}

sub scalar_text ($v) {
    my $t = type_of($v);
    return 'null' if $t == T_NULL;
    return $v ? 'true' : 'false' if $t == T_BOOL;
    return '"' . quoted($t == T_STR ? $v : $v->can('str') ? $v->str : "$v") . '"' if $t != T_NUM;
    return "$v" if "$v" =~ /\A-?[0-9]+\z/;
    $v - $v == 0 or return 'null';                              # JSON has no way to write these
    for my $digits (15, 16) {                                   # as few as give the same number back
        my $text = sprintf '%.*g', $digits, $v;
        return $text if $text == $v;
    }
    return sprintf '%.17g', $v;
}

# The characters of a string as they are written between quotes.
sub quoted ($s) {
    return join '', map {
        my $part = $_;
        length $part == 1 && $part =~ /[\x{D800}-\x{DFFF}"\\\x00-\x1F]|[^\x{0}-\x{10FFFF}]/
            ? (ord $part > 0x10FFFF ? stray($part) : $ESCAPED{$part} // sprintf '\\u%04x', ord $part)
            : do { utf8::encode($part); $part };
    } grep { length } split /([\x{D800}-\x{DFFF}"\\\x00-\x1F]|[^\x{0}-\x{10FFFF}])/, $s;
}

# The byte that a character past the end of Unicode stands for.
sub stray ($char) {
    my $byte = ord($char) - STRAY;
    $byte >= 0x80 && $byte <= 0xFF or die sprintf "JGraft::JSON: a string holds the character 0x%X, which JSON cannot say\n", ord $char;
    return chr $byte;
}

# An array, copied (if $from) from one that was read: with $tok, the tokens
# of its elements.  What stood side by side in the text is written that way
# again, with what was between; the rest is joined as the text joined things.
sub array ($v, $from, $tok) {
    my $items = $from && $from->{items};
    return fresh('[', ']', map { emit($v->[$_], $tok && $tok->[$_]) } 0 .. $#$v) unless $items && @$items && @$v;
    my $text = $from->{text};
    my $cut  = sub ($a, $b) { substr $$text, $a, $b - $a };
    my %was; @was{ map { refaddr $_ } @$items } = 0 .. $#$items;       # which element of the old array a token is
    my $gap  = sub ($j) { $cut->($items->[$j][1], $items->[ $j + 1 ][0]) };      # what was between two elements
    my $join = @$items > 1 ? $gap->($#$items - 1) : ',' . substr $cut->($from->{start}, $items->[0][0]), 1;    # for what is new
    my ($out, $before) = ($cut->($from->{start}, $items->[0][0]));
    for my $i (0 .. $#$v) {
        my $hint = $tok && $tok->[$i];
        my $j    = $hint ? $was{ refaddr $hint } : undef;
        $out .= between($gap, $#$items, $before, $j, $join) if $i;
        $out .= emit($v->[$i], $hint);
        $before = $j;
    }
    return $out . $cut->($items->[-1][1], $from->{end});
}

# An object, likewise.  Each member that was read is [ key, start of the key,
# end of the key, token of the value ].
sub object ($v, $from, $tok) {
    my @order   = JGraft::Ordered::is($v) ? keys %$v : sort keys %$v;
    my $members = $from && $from->{members};
    my $pair    = sub ($k, $colon = ':') { '"' . quoted($k) . '"' . $colon . emit($v->{$k}, $tok && $tok->{$k}) };
    return fresh('{', '}', map { $pair->($_) } @order) unless $members && @$members && @order;
    my $text = $from->{text};
    my $cut  = sub ($a, $b) { substr $$text, $a, $b - $a };
    my (%first, %last);         # the members that had each key: one, unless the text gave a key twice
    for my $m (0 .. $#$members) {
        my $k = $members->[$m][0];
        $first{$k} //= $m;
        $last{$k} = $m;
    }
    # The keys that are still where they were, among the others that are;
    # one that has been taken out and put back, or was not there, is not.
    my ($reached, %stays) = (-1);
    for my $k (grep { defined $first{$_} } @order) {
        next if $first{$k} < $reached;
        $stays{$k} = 1;
        $reached = $first{$k};
    }
    my $colon = $cut->($members->[0][2], $members->[0][3][0]);
    my $gap   = sub ($m) { $cut->($members->[$m][3][1], $members->[ $m + 1 ][1]) };      # what was between two members
    my $join  = @$members > 1 ? $gap->($#$members - 1) : ',' . substr $cut->($from->{start}, $members->[0][1]), 1;
    # a member that was read, with the value its key has now
    my $kept  = sub ($m) {
        my $k = $members->[$m][0];
        $cut->($members->[$m][1], $members->[$m][3][0]) . emit($v->{$k}, $tok && $tok->{$k});
    };
    # A key that has moved is written as it was; and a new one whose value is
    # that of a member no longer there has taken its place, name for name.
    my %had; @had{ map { refaddr $_->[3] } @$members } = 0 .. $#$members;
    my $other = sub ($k) {
        return [ $kept->($last{$k}) ] if defined $last{$k};
        my $m = $tok && $tok->{$k} ? $had{ refaddr $tok->{$k} } : undef;
        return [ $pair->($k, $colon) ] unless defined $m && !exists $v->{ $members->[$m][0] };
        return [ $pair->($k, $cut->($members->[$m][2], $members->[$m][3][0])), $m ];
    };
    # Members are written in the order they were read, each key that has
    # moved or is new going before the next one that has stayed.
    my (@unit, @wait);          # [ text, which member it was ]
    my @coming = @order;
    for my $m (0 .. $#$members) {
        my $k = $members->[$m][0];
        next unless $stays{$k};
        if ($m == $first{$k}) {
            push @wait, shift @coming while @coming && $coming[0] ne $k;
            shift @coming;
            push @unit, map { $other->($_) } grep { !$stays{$_} } splice @wait;
        }
        # the last of a key written twice has its value; one before it is as it was
        push @unit, [ $m == $last{$k} ? $kept->($m) : $cut->($members->[$m][1], $members->[$m][3][1]), $m ];
    }
    push @unit, map { $other->($_) } grep { !$stays{$_} } @coming;
    my $out = $cut->($from->{start}, $members->[0][1]);
    for my $i (0 .. $#unit) {
        $out .= between($gap, $#$members, $unit[ $i - 1 ][1], $unit[$i][1], $join) if $i;
        $out .= $unit[$i][0];
    }
    return $out . $cut->($members->[-1][3][1], $from->{end});
}

sub fresh ($open, $close, @part) { $open . join(',', @part) . $close }

# What to write between two things that now stand side by side, the $m-th
# and $n-th of those that were read (either may be new, and not defined).
# Neighbours get what was between them.  Otherwise it is what followed the
# first of them or what came before the second: the one that ended a line,
# if only one did, so that lines begin and end where they did.
sub between ($gap, $last, $m, $n, $join) {
    return $gap->($m) if defined $m && defined $n && $n == $m + 1;
    my $after  = defined $m && $m < $last ? $gap->($m)     : undef;
    my $before = defined $n && $n > 0     ? $gap->($n - 1) : undef;
    return $before if defined $before && (!defined $after || $before =~ /\n/ && $after !~ /\n/);
    return $after // (defined $m && $m > 0 ? $gap->($m - 1) : $join);
}

# A string that has changed, as text between quotes: the parts of it that
# are as they were are copied from the token that it was read from, and
# only the rest is written anew.  It is compared line by line; then, in each
# stretch of lines that differs, by what begins and ends alike, and what is
# left between by the least change that makes one of the other.
sub patched ($token, $was, $now) {
    my ($old, $new) = map { [ split /(?<=\n)/, $_ ] } $was, $now;
    my (@piece, @place);        # each piece: text, or [ from, to ] in characters of $was; and every such place
    my $keep = sub ($from, $to) { push @piece, [ $from, $to ] and push @place, $from, $to if $to > $from };
    my ($j, $at) = (0, 0);      # lines of the old that are done, and characters
    my $same = sub ($to) {      # the old lines up to $to are as they were
        my $from = $at;
        $at += length $old->[ $j++ ] while $j < $to;
        $keep->($from, $at);
    };
    for my $stretch (JGraft::Undo::stretches($new, $old), [ scalar @$new, 0, scalar @$old, 0 ]) {
        my ($ni, $n, $oj, $m) = @$stretch;
        $same->($oj);
        my $gone = join '', @$old[ $oj .. $oj + $m - 1 ];
        my $come = join '', @$new[ $ni .. $ni + $n - 1 ];
        my $head  = agree($gone, 0, $come, 0);
        my $tail  = agree($gone, length $gone, $come, length $come, 1);
        my $least = (length $gone < length $come ? length $gone : length $come) - $head;
        $tail = $least if $tail > $least;       # (the two ends are not to overlap)
        $keep->($at, $at + $head);
        my ($out, $in) = map { substr $_, $head, length($_) - $head - $tail } $gone, $come;
        my ($base, $done) = ($at + $head, 0);
        for my $part (differences($in, $out), [ length $in, 0, length $out, 0 ]) {
            my ($ci, $cn, $cj, $cm) = @$part;
            $keep->($base + $done, $base + $cj);
            push @piece, quoted(substr $in, $ci, $cn);
            $done = $cj + $cm;
        }
        $keep->($at + length($gone) - $tail, $at + length $gone);
        $at += length $gone;
        $j = $oj + $m;
    }
    my %byte;
    @byte{@place} = bytes_at(substr($token, 1, -1), @place);
    return join '', map { ref ? substr $token, 1 + $byte{ $_->[0] }, $byte{ $_->[1] } - $byte{ $_->[0] } : $_ } @piece;
}

# How many characters two strings have alike from these places on (or,
# going $back, before them).  They are compared in leaps that grow while
# they agree, and then shrink to find where they stop agreeing.
sub agree ($a, $x, $b, $y, $back = 0) {
    my $most = $back ? ($x < $y ? $x : $y) : (length($a) - $x < length($b) - $y ? length($a) - $x : length($b) - $y);
    return 0 if $most < 1 || !$back && substr($a, $x, 1) ne substr($b, $y, 1);     # as is most often so
    my ($n, $leap, $stopped) = (0, 16, 0);
    while ($leap) {
        my $alike = $leap <= $most - $n
            && ($back ? substr($a, $x - $n - $leap, $leap) eq substr($b, $y - $n - $leap, $leap)
                      : substr($a, $x + $n, $leap) eq substr($b, $y + $n, $leap));
        if ($alike) { $n += $leap; $leap *= 2 unless $stopped }
        else        { $stopped = 1; $leap >>= 1 }
    }
    return $n;
}

# Where two strings differ, in as few places as can be: a list of
# [ i, n, j, m ], each saying that the n characters of $new at i stand where
# the m of $old at j did, and everything outside these is alike.
#
# This is E. W. Myers's algorithm, as in JGraft::Undo, but on the strings
# as they are: no character is ever a value of its own, and a run that is
# alike is passed over at the speed Perl compares strings.  Each round
# allows one more character to have come or gone; $far{k} is how far into
# $new that gets along the diagonal k, where the place in $old is k less.
# The search costs the square of the change, so it is given steps in
# proportion to the length (one for each character and a few hundred more,
# or fewer of a very long string), and past that the strings are taken to
# differ throughout: by then the change is large, and little is lost.
sub differences ($new, $old) {
    my ($n, $m) = (length $new, length $old);
    my $whole = [ 0, $n, 0, $m ];
    return $n || $m ? $whole : () unless $n && $m;
    my $steps = 500 + $n + $m;
    $steps = 20_000 + ($n + $m) / 4 if $steps > 20_000 + ($n + $m) / 4;
    my %far   = (1 => 0);
    my @before;                 # the diagonals of the round before, as each round found them
    for my $round (0 .. $n + $m) {
        $before[$round] = pack 'l*', map { $far{ 2 * $_ - $round + 1 } // 0 } 0 .. $round - 1;
        for (my $k = -$round; $k <= $round; $k += 2) {
            --$steps >= 0 or return $whole;
            my $down = $k == -$round || $k != $round && $far{ $k - 1 } < $far{ $k + 1 };
            my $x    = $down ? $far{ $k + 1 } : $far{ $k - 1 } + 1;
            $x += agree($new, $x, $old, $x - $k) if $x <= $n && $x - $k <= $m;
            $far{$k} = $x;
            next unless $x >= $n && $x - $k >= $m;
            # Both are used up.  Go back through the rounds by the way that
            # led here, noting the character that each one stepped over.
            my ($y, @step) = ($x - $k);
            for (my $r = $round; $r > 0; $r--) {
                my @was  = unpack 'l*', $before[$r];        # diagonal d is at ($d + $r - 1) / 2
                my $d    = $x - $y;
                my $down = $d == -$r || $d != $r && $was[ ($d + $r - 2) / 2 ] < $was[ ($d + $r) / 2 ];
                $d += $down ? 1 : -1;
                $x = $was[ ($d + $r - 1) / 2 ];
                $y = $x - $d;
                push @step, [ $x, $y, !$down ];             # where it stood, and whether a new character came
            }
            my @part;
            for (reverse @step) {
                my ($i, $j, $came) = @$_;
                push @part, [ $i, 0, $j, 0 ] unless @part && $part[-1][0] + $part[-1][1] == $i && $part[-1][2] + $part[-1][3] == $j;
                $part[-1][ $came ? 1 : 3 ]++;
            }
            return @part;
        }
    }
}

# Where, in the bytes between the quotes of a string, the characters at
# these places begin.  (The places are in rising order.)
sub bytes_at ($body, @place) {
    my ($char, @byte) = (0);
    pos($body) = 0;
    while (@place) {
        my $from = pos $body;
        if ($body =~ /\G[\x00-\x5B\x5D-\x7F]+/gc) {        # plain characters: a byte each
            my $run = pos($body) - $from;
            push @byte, $from + shift(@place) - $char while @place && $place[0] < $char + $run;
            $char += $run;
            next;
        }
        push @byte, $from and shift @place while @place && $place[0] == $char;
        last if $from >= length $body;
        $body =~ /\G(?:\\u[dD][89abAB][0-9a-fA-F]{2}\\u[dD][c-fC-F][0-9a-fA-F]{2}|\\u[0-9a-fA-F]{4}|\\.|$WIDE|.)/gcs;
        $char++;
    }
    return @byte;
}

1;
