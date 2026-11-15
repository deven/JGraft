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
use builtin qw(created_as_number refaddr blessed);
use overload ();
no warnings qw(experimental::builtin recursion surrogate nonchar non_unicode utf8 portable);
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

our $EXACT;      # is the text being written one whose numbers were read exactly?
our $STYLE;      # how a new array or object is to be laid out where one is being written, if that is known
our $COLON = ':';
our $WATCH;      # by which data that holds itself is noticed, for it cannot be written (see JSON5 below, and JGraft::Util::watch)
our $FIVE;       # is what is being written to be JSON5?
our $PLAIN;      # is nothing of the text to be written as it was (a JSON5 text being written as JSON)?
our $QUOTE = '"';   # the quote that a new string is written in, and how the name of a new property is written
our $NAMES = '"';

# JSON5 (json5.org) is JSON as ECMAScript 5 would let it be written: with
# comments, a comma after the last element, names that need no quotes,
# strings in single quotes and with more escapes, numbers in hexadecimal or
# with a point at either end or a plus sign, and Infinity and NaN.  Every
# JSON text is a JSON5 text that means the same.
#
# A text is read as JSON, unless it is asked for as JSON5; and a text that
# is not JSON but is JSON5 is read as JSON5 all the same.  A document knows
# which it was (`json5`), and is written back as that.

# White space, and a comment: each as bytes, for the text is bytes.
my $BLANK   = qr/[ \t\n\r\x0B\x0C]|\xC2\xA0|\xEF\xBB\xBF|\xE1\x9A\x80|\xE2\x80[\x80-\x8A\xA8\xA9\xAF]|\xE2\x81\x9F|\xE3\x80\x80/;
my $COMMENT = qr{//(?:(?!\xE2\x80[\xA8\xA9])[^\n\r])*+|/\*.*?\*/}s;
my $NUMBER5 = qr/[-+]?(?:0[xX][0-9a-fA-F]+|Infinity|NaN|(?:(?:0|[1-9][0-9]*)(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)/;
my $NUMBER  = qr/-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?/;
my $NEXT_NUMBER5 = qr/\G($NUMBER5)(?![A-Za-z0-9_\$])/;      # (as the next thing in a text)

sub json5 ($doc) { $doc->{json5} ? 1 : 0 }

sub parse ($class, $text, %opt) {
    my @unknown = grep { !/\A(?:exact|max_depth|max_size|json5)\z/ } sort keys %opt;
    die "JGraft::JSON->parse: unknown option @unknown\n" if @unknown;
    defined $opt{$_} && !($opt{$_} =~ /\A[0-9]+\z/) and die "JGraft::JSON->parse: $_ must be a whole number that is not negative\n" for qw(max_depth max_size);
    utf8::downgrade($text, 1) or utf8::encode($text);       # bytes, however they were handed over
    return bless reading($text, \%opt, $opt{json5} ? 1 : 0), $class if defined $opt{json5};
    # Nothing was said: it is JSON, or if it is not that, JSON5.  If it is neither, what is wrong with it is said
    # of the reading that got further, which is the one the text was more likely meant for.
    my $doc = eval { reading($text, \%opt, 0) };
    return bless $doc, $class if $doc;
    my $not_json = $@;
    $doc = eval { reading($text, \%opt, 1) };
    return bless $doc, $class if $doc;
    my $not_json5 = $@;
    my ($json_at, $json5_at) = map { /at byte ([0-9]+)$/ ? $1 : -1 } $not_json, $not_json5;
    die $json5_at > $json_at ? $not_json5 =~ s/^JGraft::JSON: /JGraft::JSON: (as JSON5) /r : $not_json;
}

# A text (which is bytes) as a document: as JSON, or if $five as JSON5.
sub reading ($text, $opt, $five) {
    my $exact = $opt->{exact} // 1;     # numbers are read with every digit they have, unless it is asked otherwise
    # How deep arrays and objects may be one inside another, and how long the text may be: as deep and as long as
    # they are, unless it is asked otherwise.
    my ($deepest, $depth) = ($opt->{max_depth}, 0);
    my $src   = \$text;
    my $fail  = sub ($what) { die sprintf "JGraft::JSON: %s at byte %d\n", $what, pos($text) // 0 };
    $fail->(sprintf 'the text is %d bytes, and max_size is %d', length $text, $opt->{max_size}) if defined $opt->{max_size} && length $text > $opt->{max_size};
    my $deeper = sub { defined $deepest && ++$depth > $deepest and $fail->("arrays and objects are more than max_depth ($deepest) deep") };
    my $space  = !$five ? sub { $text =~ /\G[ \t\n\r]*/gc } : sub {
        $text =~ /\G(?:$BLANK|$COMMENT)*/gc;
        $text =~ m{\G/\*} and $fail->('a comment does not end');
    };
    # A string may not hold a control character as it stands (in JSON), or a line break (in JSON5): it has to be
    # escaped.  The string is read as far as such a character, and the complaint is of that and not of a missing quote.
    my $string = !$five ? sub {
        $text =~ /\G"((?:[^"\\\x00-\x1F]++|\\.)*+)"/gc
            or $fail->($text =~ /\G"(?:[^"\\\x00-\x1F]++|\\.)*+[\x00-\x1F]/ ? 'a string has a control character that is not escaped' : 'a string does not end');
        return unquote($1) // $fail->('a string has an escape that means nothing');
    } : sub {
        my $quote = substr $text, pos($text) // 0, 1;
        ($quote eq '"' ? $text =~ /\G"((?:[^"\\\n\r]++|\\(?:\r\n|.))*+)"/gcs : $text =~ /\G'((?:[^'\\\n\r]++|\\(?:\r\n|.))*+)'/gcs)
            or $fail->($text =~ /\G["'](?:[^"'\\\n\r]++|\\(?:\r\n|.))*+[\n\r]/s ? 'a string has a line break that is not escaped' : 'a string does not end');
        return unquote($1, 1) // $fail->('a string has an escape that means nothing');
    };
    # (how a JSON5 text writes its first name, the colon after it, and its first string: for what is written new.
    # Of a JSON text all that is not already known is the colon, which is looked for when it is wanted.)
    my ($names, $colon, $quote) = $five ? () : ('"', undef, '"');
    my $value;
    $value = sub {
        $space->();
        my $start = pos($text) // 0;
        my ($v, $record, $next);
        if ($text =~ /\G\{/gc) {
            $deeper->();
            $v      = JGraft::Ordered::hash();
            $record = { text => $src, start => $start, exact => $exact, members => \my @member };
            $space->();
            until ($text =~ /\G\}/gc) {
                if (@member) {
                    $text =~ /\G,/gc or $fail->('expected , or }');
                    $space->();
                    last if $five && $text =~ /\G\}/gc;         # (a comma after the last)
                }
                my $at  = pos $text;
                my $key = substr($text, $at, 1) eq '"' ? $string->()
                        : !$five                         ? $fail->('expected the name of a property')
                        : substr($text, $at, 1) eq "'"   ? $string->()
                        :                                  name($text) // $fail->('expected the name of a property');
                my $to  = pos $text;
                $space->();
                $text =~ /\G:/gc or $fail->('expected :');
                if ($five) {
                    $names //= substr($text, $at, 1) =~ /(["'])/ ? $1 : 'bare';
                    if (!defined $colon) { $space->(); $colon = uncommented(substr $text, $to, pos($text) - $to) }
                }
                ($v->{$key}, my $token) = $value->();
                push @member, [ $key, $at, $to, $token ];
                $space->();
            }
        }
        elsif ($text =~ /\G\[/gc) {
            $deeper->();
            $v      = [];
            $record = { text => $src, start => $start, exact => $exact, items => \my @item };
            $space->();
            until ($text =~ /\G\]/gc) {
                if (@item) {
                    $text =~ /\G,/gc or $fail->('expected , or ]');
                    if ($five) { $space->(); last if $text =~ /\G\]/gc }
                }
                (my $element, my $token) = $value->();
                push @$v,   $element;
                push @item, $token;
                $space->();
            }
        }
        elsif (($next = substr $text, $start, 1) eq '"') { $v = $string->(); $quote //= '"' if $five }
        elsif ($five && $next eq "'")                    { $v = $string->(); $quote //= "'" }
        elsif (!$five && $text =~ /\G(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)/gc) {
            $v = $exact ? JGraft::Number::read($1) // $fail->('a number is beyond all reason') : JGraft::Number::native($1);
        }
        elsif ($five && $text =~ /$NEXT_NUMBER5/gc) { $v = number($1, $exact) // $fail->('a number is beyond all reason') }
        elsif ($text =~ /\Gtrue\b/gc)   { $v = $TRUE }
        elsif ($text =~ /\Gfalse\b/gc)  { $v = $FALSE }
        elsif ($text =~ /\Gnull\b/gc)   { $v = undef }
        else                            { $fail->('expected a value') }
        my $end = pos $text;
        if ($record) {
            $depth--;
            $record->{end} = $end;
            JGraft::Source::read_as($v, $record);
        }
        return ($v, [ $start, $end, $src ]);
    };
    my ($data, $root) = $value->();
    $space->();
    pos($text) == length $text or $fail->('there is something after the value');
    undef $value;       # (it refers to itself)
    return { text => $src, data => $data, root => $root, exact => $exact, json5 => $five, names => $names, colon => $colon, quote => $quote };
}

# Some text of a JSON5 document without its comments (to be written again where no comment belongs).
# A comment that had a line to itself goes with its line; any other, with the space that set it off from what it followed.
sub uncommented ($text) { $text =~ s/(?<=\n)[ \t]*(?:$COMMENT)[ \t]*(?:\r\n|[\n\r])//gr =~ s/[ \t]*(?:$COMMENT)//gr }

# The name of a property written without quotes, in JSON5, at the place the
# text has been read to: what ECMAScript 5 calls an IdentifierName.  Nothing,
# if there is none there.
sub name {
    my $at = pos $_[0];
    $_[0] =~ /\G((?:[A-Za-z0-9_\$]|\\u[0-9a-fA-F]{4}|$WIDE)+)/gc or return undef;
    my $name = $1;
    utf8::decode($name);
    $name =~ s/\\u([0-9a-fA-F]{4})/chr hex $1/ge;
    # (A character that this Perl does not know may be a letter in a Unicode newer than the one it has, and is let pass.)
    return $name if $name =~ /\A[\$_\p{L}\p{Nl}\p{Cn}][\$_\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}\p{Cn}\x{200C}\x{200D}]*\z/;
    pos($_[0]) = $at;       # (what is wrong is said of where it began)
    return undef;
}

# The number that a token of JSON5 says (and so any that a token of JSON
# does): as Perl reads numbers, or $exact with every digit.  Nothing, if it
# says none that can be held.
sub number ($token, $exact) {
    my ($sign, $rest) = $token =~ /\A([-+]?)(.*)\z/s;
    return $sign eq '-' ? -9**9**9 : 9**9**9 if $rest eq 'Infinity';
    return -sin(9**9**9)                     if $rest eq 'NaN';
    if ($rest =~ /\A0[xX]([0-9a-fA-F]+)\z/) {
        my $digits = $1 =~ s/\A0+(?=.)//r;
        require Math::BigInt;
        $rest = length $digits <= 15 ? hex $digits : Math::BigInt->from_hex($digits)->bstr;
    }
    $rest =~ s/\A\./0./;
    $sign = '' if $sign eq '+';
    return $exact ? JGraft::Number::read("$sign$rest") : JGraft::Number::native("$sign$rest");
}

# What is between the quotes of a string, as characters: or nothing, if an
# escape in it is not one that JSON has (or, if it is $five, that JSON5 has).
sub unquote ($body, $five = 0) {
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
        elsif ($five && $body =~ /\G\\(?:\r\n|[\n\r]|\xE2\x80[\xA8\xA9])/gc) { }       # a line that goes on: nothing
        elsif ($five && $body =~ /\G\\x([0-9a-fA-F]{2})/gc) { $s .= chr hex $1 }
        elsif ($five && $body =~ /\G\\v/gc)         { $s .= "\x0B" }
        elsif ($five && $body =~ /\G\\0(?![0-9])/gc) { $s .= "\0" }
        elsif ($five && $body =~ /\G\\(?=[0-9xu])/gc) { return undef }
        elsif ($five && $body =~ /\G\\((?:$WIDE)|[\x00-\x7F])/gc) { my $char = $1; utf8::decode($char); $s .= $char }    # any other: itself
        elsif ($body =~ /\G\\/gc)                   { return undef }
        else { $body =~ /\G(.)/gcs; $s .= chr STRAY + ord $1 }      # a byte (0x80 or more) that is not UTF-8
    }
    return $s;
}

#---------------------------------------------------------------------------
# Writing

# The text of the document with $value as its data: as JSON if the document
# was JSON, and as JSON5 if it was that, unless `json5` says which.
#
# A JSON5 document written as JSON is written anew throughout, for nothing
# of it can be taken as it stands: it keeps its layout, and loses its
# comments and whatever JSON has no way to write.
sub write ($doc, $value = $doc->{data}, %opt) {
    my @unknown = grep { $_ ne 'json5' } sort keys %opt;
    die "JGraft::JSON->write: unknown option @unknown\n" if @unknown;
    my ($start, $end, $text) = @{ $doc->{root} };
    local $EXACT = $doc->{exact};
    local $FIVE  = $opt{json5} // $doc->{json5} ? 1 : 0;
    local $PLAIN = $doc->{json5} && !$FIVE ? 1 : 0;
    # How what is new is to be written: as the text writes such things, as far as that is known.  The first name
    # in the text and the first string say how those are quoted and what follows a name; and some array or
    # object of the text will say how one is laid out (see `style`).
    local $COLON = spacing($doc->{colon} //= $$text =~ /"(?:[^"\\]|\\.)*"(\s*:\s*)/ ? $1 : ':');
    local ($QUOTE, $NAMES) = $FIVE ? ($doc->{quote} // '"', $doc->{names} // '"') : ('"', '"');
    local $STYLE = outermost($doc);
    local $WATCH = watch();
    my ($before, $after) = (substr($$text, 0, $start), substr($$text, $end));
    ($before, $after) = map { spacing($_) } $before, $after if $PLAIN;
    return $before . emit($value, $doc->{root}) . $after;
}

# The text of any value, on its own: what was read from a text as it was,
# and the rest as plainly as JSON can be written; or with `json5`, as JSON5,
# which differs for what JSON cannot say (an infinity is Infinity, not null).
sub encode ($class, $value, %opt) {
    my @unknown = grep { $_ ne 'json5' } sort keys %opt;
    die "JGraft::JSON->encode: unknown option @unknown\n" if @unknown;
    local ($FIVE, $PLAIN, $QUOTE, $NAMES) = ($opt{json5} ? 1 : 0, 0, '"', '"');
    local $WATCH = watch();
    return emit($value, undef);
}

# Some of the text between things, as it may be written again between other
# things: without the comments, which belong where they are; and in JSON,
# with a space for whatever JSON5 counts as white space and JSON does not.
sub spacing ($text) {
    $text = uncommented($text);
    $text =~ s/(?![ \t\n\r])$BLANK/ /g unless $FIVE;
    return $text;
}

# What a token of a text says: (1, the value), or nothing if it says none.
# It is read as JSON5, which reads all that JSON does.
sub said ($token, $exact) {
    return (1, $TRUE)  if $token eq 'true';
    return (1, $FALSE) if $token eq 'false';
    return (1, undef)  if $token eq 'null';
    if ($token =~ /\A["']/) {
        my $s = unquote(substr($token, 1, -1), 1);
        return defined $s ? (1, $s) : ();
    }
    return () unless $token =~ /\A$NUMBER5\z/;
    my $n = number($token, $exact);
    return defined $n ? (1, $n) : ();
}

# Is a token one that JSON has, and so one that can stand in either kind of text?
sub in_json ($token) { $token =~ /\A(?:true|false|null|$NUMBER)\z/ || $token =~ /\A"/ && defined unquote(substr($token, 1, -1), 0) }

# The name of a property as it is to be written: as $how says ('"', "'", or
# 'bare', which is without quotes if the name can do without them).
sub named ($k, $how) {
    return $k if $how eq 'bare' && $k =~ /\A[A-Za-z_\$][A-Za-z0-9_\$]*\z/;
    my $quote = $how eq 'bare' ? $QUOTE : $how;
    return $quote . quoted($k, $quote) . $quote;
}

# A value as text.  $hint is the token of the place it is in, if there is
# one: where in some text the value there was written.
sub emit ($v, $hint) {
    my $kind = ref $v;
    if ($kind eq 'ARRAY' || $kind eq 'HASH') {
        my $sheet = JGraft::Source::sheet($v) // {};
        my $rec   = $sheet->{rec};
        return substr ${ $rec->{text} }, $rec->{start}, $rec->{end} - $rec->{start} if $rec && !$PLAIN;        # just as it was read
        my $w = $WATCH;
        if (++$w->[0] >= $w->[1] || $w->[2]) { inside($w, $v) and die "JGraft::JSON: data that contains itself cannot be written\n" }
        my $out = $PLAIN               ? anew($v, JGraft::Source::tokens($v))
                : $kind eq 'ARRAY'     ? array($v, @$sheet{qw(from tok)})
                :                        object($v, @$sheet{qw(from tok)});
        left($w) if $w->[0]-- == $w->[3];
        return $out;
    }
    return emit(stand_in($v), $hint) if $kind && type_of($v) == T_OTHER;
    if ($hint) {
        my $token = substr ${ $hint->[2] }, $hint->[0], $hint->[1] - $hint->[0];
        # (a number is read as it was when the text was: with every digit, if that is how it is kept)
        if ($token !~ /^[\[{]/ and my ($read, $was) = said($token, $EXACT || ref $v)) {
            my $usable = $FIVE || in_json($token);          # (a token of JSON5 alone has no place in JSON)
            return $token                                                                   # it says what the value still is
                if $usable && type_of($was) == type_of($v) && (is_num($v) ? same_number($v, $was) : match_lit($v, $was, 1));
            # (a string that has changed keeps the quotes it had, and what of it is as it was)
            if (is_str($v) && is_str($was) && $usable) { my $quote = substr $token, 0, 1; return $quote . patched($token, $was, $v, $quote) . $quote }
        }
    }
    return scalar_text($v);
}

# What is to be written for something that is no JSON value: an object, or
# a reference to something that is neither an array nor a set of properties.
# An object says what stands for it, by the method that JSON encoders ask of
# one (TO_JSON); or failing that, if it is made to read as a string, it is
# written as that string.  Nothing else can be written, and the writer says
# so, where it would once have written something that meant nothing.
our $STOOD = 0;     # how many stand-ins deep the writer is: one object may stand for another, but not for ever

sub stand_in ($v) {
    my $class = blessed $v;
    die sprintf "JGraft::JSON: a reference to %s cannot be written\n", lc(ref $v) =~ s/^code$/a subroutine/r =~ s/^scalar$/a scalar/r unless defined $class;
    if ($v->can('TO_JSON')) {
        local $STOOD = $STOOD + 1;
        $STOOD <= 100 or die "JGraft::JSON: an object of $class cannot be written: what TO_JSON gives for it has TO_JSON asked of it without end\n";
        my $as = $v->TO_JSON;
        ref $as && refaddr($as) == refaddr($v) and die "JGraft::JSON: an object of $class cannot be written: its TO_JSON gives the object itself\n";
        return stood($as);
    }
    return "$v" if overload::Method($v, '""');
    die "JGraft::JSON: an object of $class cannot be written: it has no TO_JSON, and does not read as a string\n";
}

# (what stands for an object may itself be one, and is asked in its turn while the count above still holds)
sub stood ($as) { ref $as && ref $as ne 'ARRAY' && ref $as ne 'HASH' && type_of($as) == T_OTHER ? stand_in($as) : $as }

sub scalar_text ($v) {
    my $t = type_of($v);
    return 'null' if $t == T_NULL;
    return $v ? 'true' : 'false' if $t == T_BOOL;
    return $QUOTE . quoted($t == T_STR ? $v : $v->can('str') ? $v->str : "$v", $QUOTE) . $QUOTE if $t != T_NUM;
    if (ref $v) {
        return JGraft::Number::str($v) if ref $v eq 'JGraft::Number' || !$v->is_nan && !$v->is_inf;
        $v = $v->numify;
    }
    return '-0' if JGraft::Number::negative_zero($v);           # (which Perl would write as 0)
    # An infinity, or what is not a number: JSON has no way to write these, and by custom writes null.  JSON5 has.
    return !$FIVE ? 'null' : $v != $v ? 'NaN' : $v > 0 ? 'Infinity' : '-Infinity' unless $v - $v == 0;
    return "$v" if "$v" =~ /\A-?[0-9]+\z/;
    for my $digits (15, 16) {                                   # as few as give the same number back
        my $text = sprintf '%.*g', $digits, $v;
        return $text if $text == $v;
    }
    return sprintf '%.17g', $v;
}

# The characters of a string as they are written between quotes: double
# ones, or in JSON5 perhaps single, where it is the single quote that has to
# be escaped and the double that need not be.
sub quoted ($s, $quote = '"') {
    my $special = $quote eq '"' ? qr/[\x{D800}-\x{DFFF}"\\\x00-\x1F]|[^\x{0}-\x{10FFFF}]/ : qr/[\x{D800}-\x{DFFF}'\\\x00-\x1F]|[^\x{0}-\x{10FFFF}]/;
    return join '', map {
        my $part = $_;
        length $part == 1 && $part =~ $special
            ? (ord $part > 0x10FFFF ? stray($part) : $part eq "'" ? "\\'" : $ESCAPED{$part} // sprintf '\\u%04x', ord $part)
            : do { utf8::encode($part); $part };
    } grep { length } split /($special)/, $s;
}

# Are two numbers the same, to the place and the sign of a zero?  (As for
# JGraft::Number::same, but that what is not a number at all is the same as itself.)
sub same_number ($a, $b) {
    return JGraft::Number::same($a, $b) unless grep { !ref && $_ - $_ != 0 } $a, $b;      # (an infinity, or not a number: no decimal)
    return 0 if ref $a || ref $b;
    return $a != $a ? $b != $b : $a == $b;
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
    return anew($v, $tok) unless $items && @$items && @$v;
    my $text = $from->{text};
    my $cut  = sub ($a, $b) { substr $$text, $a, $b - $a };
    my %was; @was{ map { refaddr $_ } @$items } = 0 .. $#$items;       # which element of the old array a token is
    my $gap  = sub ($j) { $cut->($items->[$j][1], $items->[ $j + 1 ][0]) };      # what was between two elements
    my $join = spacing(@$items > 1 ? $gap->($#$items - 1) : ',' . substr $cut->($from->{start}, $items->[0][0]), 1);    # for what is new
    local $STYLE = style($from, $items->[0][0], $items->[-1][1], undef, $join, undef);
    # each element as it is now written, and which element of the old array it was (if it was one)
    my @unit = map { my $hint = $tok && $tok->[$_]; [ emit($v->[$_], $hint), $hint ? $was{ refaddr $hint } : undef ] } 0 .. $#$v;
    return stitched($from, [ map { [ @$_[ 0, 1 ] ] } @$items ], \@unit, $join);
}

# An object, likewise.  Each member that was read is [ key, start of the key,
# end of the key, token of the value ].
sub object ($v, $from, $tok) {
    my @order   = JGraft::Ordered::is($v) ? keys %$v : sort keys %$v;
    my $members = $from && $from->{members};
    return anew($v, $tok) unless $members && @$members && @order;
    my $text = $from->{text};
    my $cut  = sub ($a, $b) { substr $$text, $a, $b - $a };
    # (a new name is written as the first name here is: in its quotes, or in JSON5 perhaps without)
    my $names = !$FIVE ? '"' : $cut->($members->[0][1], $members->[0][1] + 1) =~ /(["'])/ ? $1 : 'bare';
    my $pair  = sub ($k, $colon) { named($k, $names) . $colon . emit($v->{$k}, $tok && $tok->{$k}) };
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
    my $colon = spacing($cut->($members->[0][2], $members->[0][3][0]));
    my $gap   = sub ($m) { $cut->($members->[$m][3][1], $members->[ $m + 1 ][1]) };      # what was between two members
    my $join  = spacing(@$members > 1 ? $gap->($#$members - 1) : ',' . substr $cut->($from->{start}, $members->[0][1]), 1);
    local $STYLE = style($from, $members->[0][1], $members->[-1][3][1], $colon, $join, $names);
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
    return stitched($from, [ map { [ $_->[1], $_->[3][1] ] } @$members ], \@unit, $join);
}

# How an array or object of the text is laid out, as far as it shows how a
# new one among its elements should be.  $first and $last are where its first
# element begins and its last ends.  If its elements are each on a line of
# their own, a new array or object is written so too, a step further in than
# they are; the step is as much as they are further in than it is.
# Otherwise a new one is written on one line, with what this one has between
# its elements and inside its brackets.
sub style ($from, $first, $last, $colon, $join, $names) {
    my $text = $from->{text};
    my $lead = spacing(substr $$text, $from->{start} + 1, $first - $from->{start} - 1);
    my $tail = spacing(substr $$text, $last, $from->{end} - 1 - $last);
    # What does not show here is as it was further out: the colon after a name and how a name is written, of
    # which an array says nothing.  And in JSON5, if this one has a comma after its last element, so has a new one.
    my %also = (colon => spacing($colon // ($STYLE ? $STYLE->{colon} : $COLON)), names => $names // ($STYLE ? $STYLE->{names} : $NAMES),
        last => $FIVE && $tail =~ /\A\s*,/ ? ',' : '');
    return { pad => $lead, join => spacing($join), %also } unless $lead =~ /(\r?\n)([ \t]*)\z/;
    my ($line, $inner) = ($1, $2);
    my $own = $tail =~ /\n([ \t]*)\z/ ? $1 : '';
    return { line => $line, at => $inner, step => index($inner, $own) == 0 ? substr($inner, length $own) : $inner, %also };
}

# How the whole of a text was laid out, by which to write a whole new one in
# its place: as the array or object that it was is, if it was one.
sub outermost ($doc) {
    my $record = ref $doc->{data} && (JGraft::Source::sheet($doc->{data}) // {})->{rec} or return undef;
    my $text   = $record->{text};
    my $cut    = sub ($a, $b) { substr $$text, $a, $b - $a };
    my ($first, $last, $colon, @between);
    if (my $items = $record->{items}) {
        @$items or return undef;
        ($first, $last) = ($items->[0][0], $items->[-1][1]);
        @between = ($items->[-2][1], $items->[-1][0]) if @$items > 1;
    }
    else {
        my $members = $record->{members};
        @$members or return undef;
        ($first, $last, $colon) = ($members->[0][1], $members->[-1][3][1], $cut->($members->[0][2], $members->[0][3][0]));
        @between = ($members->[-2][3][1], $members->[-1][1]) if @$members > 1;
    }
    my $names = !$record->{members} || !$FIVE ? undef : $cut->($first, $first + 1) =~ /(["'])/ ? $1 : 'bare';
    my $style = style($record, $first, $last, $colon, @between ? $cut->(@between) : ',' . $cut->($record->{start} + 1, $first), $names);
    # (it says how what is inside the text's array or object is laid out: that array or object is a step further out)
    $style->{at} = substr $style->{at}, 0, length($style->{at}) - length $style->{step} if defined $style->{line};
    return $style;
}

# An array or object that was not read from the text: written as what is
# around it is, or if nothing says how, as compactly as can be.
sub anew ($v, $tok) {
    my $array = ref $v eq 'ARRAY';
    my @keys  = $array ? 0 .. $#$v : JGraft::Ordered::is($v) ? keys %$v : sort keys %$v;
    my ($open, $close) = $array ? ('[', ']') : ('{', '}');
    return $open . $close unless @keys;
    my $s = $STYLE;
    local $STYLE = $s && defined $s->{line} ? { %$s, at => $s->{at} . $s->{step} } : $s;       # what is inside it is a step further in
    my @part = map {
        my $name = $array ? '' : named($_, $s ? $s->{names} : $NAMES) . ($s ? $s->{colon} : ':');
        $name . emit($array ? $v->[$_] : $v->{$_}, $tok && ($array ? $tok->[$_] : $tok->{$_}));
    } @keys;
    return $open . join(',', @part) . $close unless $s;
    return $open . $s->{pad} . join($s->{join}, @part) . $s->{pad} . $close unless defined $s->{line};
    my $in = $s->{line} . $s->{at} . $s->{step};
    return $open . join(',', map { $in . $_ } @part) . $s->{last} . $s->{line} . $s->{at} . $close;
}

# What to write between two things that now stand side by side, the $m-th
# and $n-th of those that were read (either may be new, and not defined).
# Neighbours get what was between them.  Otherwise it is what followed the
# first of them or what came before the second: the one that ended a line,
# if only one did, so that lines begin and end where they did.
# The elements of an array or object that was read (or its members), put
# together again with what stood between them.
#
# @$span is where each element was in the text, from its start to its end;
# @$unit is what there is now, each [ its text, which of the old elements it
# is, if it is one ]; $join is what goes between elements that are new.
#
# What stands between two elements belongs partly to the one before and
# partly to the one after, and goes where they go.  To the one before: all
# up to the end of its line, which is the comma and any comment that follows
# it there.  To the one after: whatever lines of comment come next, and the
# space that it is set in by.  (With no line break between them, the comma
# is the dividing line.)  And between the two is the line break itself, which
# is kept if either of them is still there to end or to begin a line.  So an
# element that is removed takes its comments with it and no other's; one
# that is put between two others comes between their comments; and elements
# that stay side by side have between them exactly what they had.
#
# The same is done at the two ends.  After the opening bracket, what is left
# of its line is the bracket's, and what follows is the first element's.
# Before the closing bracket, the end of the last element's line is that
# element's (and there, in JSON5, a comma may be), and what follows is the
# bracket's: comments at the end of a list stay at the end of the list.
sub stitched ($from, $span, $unit, $join) {
    my $text = $from->{text};
    my $cut  = sub ($a, $b) { substr $$text, $a, $b - $a };
    my $last = $#$span;
    # [ what belongs to the one before, the line break, what belongs to the one after ]
    my ($open, $open_break, $lead) = divided($cut->($from->{start} + 1, $span->[0][0]), 'open');
    my @gap = map { [ divided($cut->($span->[$_][1], $span->[ $_ + 1 ][0]), 'between') ] } 0 .. $last - 1;
    my ($trail, $close_break, $close) = divided($cut->($span->[$last][1], $from->{end} - 1), 'close');
    my @trail  = ((map { $_->[0] } @gap), $trail);          # after each element, on its line
    my @broken = ((map { $_->[1] } @gap), $close_break);     # the line break after each
    my @lead   = ($lead, map { $_->[2] } @gap);              # before each element
    my @before = ($open_break, map { $_->[1] } @gap);        # the line break before each
    my ($new_trail, $new_break, $new_lead) = divided($join, 'between');
    my $comma_last = uncommented($trail . $close) =~ /,/ ? 1 : 0;       # (JSON5: is there a comma after the last?)
    my $said = sub ($t) { uncommented($t) ne $t };                      # is there a comment in it?
    # (an element that stands twice in what there now is brings what was about it only once)
    my %seen;
    my @which = map { defined $_->[1] && !$seen{ $_->[1] }++ ? $_->[1] : undef } @$unit;
    # A comment goes with its element.  What is only space, or a comma, is the space of the place and not of the
    # element, and is taken from what stood in that place: after an element, what followed it; and failing that,
    # what came before the one that is now next.  The first element has ahead of it what the first had; and of the
    # two places that the space ahead of another could be taken from, it is what followed the element before,
    # unless that one did not end its line and this one began one: so that lines begin where they did.
    my $ahead = sub ($m, $n, $first) {
        return $lead[$n] if defined $n && $said->($lead[$n]);
        return spacing($lead) if $first;
        my $was_ahead = defined $n && $n > 0 ? $lead[$n] : undef;
        return $was_ahead if defined $was_ahead && length $before[$n] && !(defined $m && length $broken[$m]);
        my $followed = defined $m && $m < $last && !$said->($gap[$m][2]) ? $gap[$m][2] : undef;
        return $followed // $was_ahead // $new_lead;
    };
    my $behind = sub ($m, $n) {
        return $trail[$m] if defined $m && ($m < $last || $said->($trail[$m]));
        return defined $n && $n > 0 && !$said->($gap[ $n - 1 ][0]) ? $gap[ $n - 1 ][0] : $new_trail;
    };
    # (what is ahead of the first element may have come from where there was a comma, and here there is none)
    my $out = $cut->($from->{start}, $from->{start} + 1) . commas($open . $open_break . $ahead->(undef, $which[0], 1), 0);
    for my $i (0 .. $#$unit) {
        my ($m, $n) = @which[ $i, $i + 1 ];
        $out .= $unit->[$i][0];
        if ($i == $#$unit) {        # the last: what follows it is what followed the last, but for a comment of its own
            my $after = defined $m && ($m == $last || $said->($trail[$m])) ? $trail[$m] : spacing($trail);
            my $break = (defined $m ? $broken[$m] : '') || $close_break;
            $break ||= "\n" if $after =~ m{//} && $said->($after);      # (a comment that runs to the end of its line has to end)
            $out .= commas($after . $break . $close, $comma_last);
            last;
        }
        my $after = $behind->($m, $n);
        my $break = (defined $m ? $broken[$m] : $new_break) || (defined $n ? $before[$n] : $new_break);
        $break ||= "\n" if $after =~ m{//} && $said->($after);
        $out .= commas($after . $break . $ahead->($m, $n, 0), 1);
    }
    return $out . $cut->($from->{end} - 1, $from->{end});
}

# Some text that stands between two elements, or after the last, with as many
# commas in it as there should be: one, or (after the last) one or none.  A
# comma too many is the last of them; one too few is put at the front, next
# to the element.  A comma in a comment is not one.
sub commas ($text, $want) {
    my @piece = $text =~ /\G($COMMENT|,|[^,\/]+|\/)/gs;         # (a comment is taken whole, where one begins)
    my @at    = grep { $piece[$_] eq ',' } 0 .. $#piece;
    return $text if @at == $want;
    splice @piece, pop(@at), 1 while @at > $want;
    unshift @piece, ',' if @at < $want;
    return join '', @piece;
}

# Some text from between two elements, or between a bracket and an element,
# as three: what of it belongs to what comes before, the line break after
# that, and what belongs to what comes after.
sub divided ($text, $where) {
    pos($text) = 0;
    $text =~ /\G(?:(?![\n\r])(?:$COMMENT|.))*/gcs;           # as far as the first line break that is not inside a comment
    my $before = substr $text, 0, pos $text;
    my $break  = $text =~ /\G(\r\n|[\n\r])/gc ? $1 : '';
    my $after  = substr $text, pos $text;
    return ($before, $break, $after) if length $break || $where eq 'open';
    # All on one line.  Between two elements the comma divides it; before the closing bracket, what follows
    # a comma is the bracket's, and so is all of it if there is no comma.
    # (it is gone through a piece at a time, so that a comma inside a comment is not taken for the comma)
    pos($text) = 0;
    while ($text =~ /\G($COMMENT|,|[^,\/]+|\/)/gcs) {
        next unless $1 eq ',';
        return (substr($text, 0, pos $text), '', substr($text, pos $text));
    }
    return $where eq 'close' ? ('', '', $text) : ($text, '', '');
}

# A string that has changed, as text between quotes: the parts of it that
# are as they were are copied from the token that it was read from, and
# only the rest is written anew.  It is compared line by line; then, in each
# stretch of lines that differs, by what begins and ends alike, and what is
# left between by the least change that makes one of the other.
sub patched ($token, $was, $now, $quote = '"') {
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
            push @piece, quoted(substr($in, $ci, $cn), $quote);
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
        next if $body =~ /\G\\(?:\r\n|[\n\r]|\xE2\x80[\xA8\xA9])/gc;       # (in JSON5, a line that goes on: no character at all)
        push @byte, $from and shift @place while @place && $place[0] == $char;
        last if $from >= length $body;
        $body =~ /\G(?:\\u[dD][89abAB][0-9a-fA-F]{2}\\u[dD][c-fC-F][0-9a-fA-F]{2}|\\u[0-9a-fA-F]{4}|\\x[0-9a-fA-F]{2}|\\(?:$WIDE)|\\.|$WIDE|.)/gcs;
        $char++;
    }
    return @byte;
}

1;
