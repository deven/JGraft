package JGraft::Error;

use v5.36;
use JGraft::Undo;

# "INVALID_TARGET: division by zero in COPY at /3/2, on /orders/0/note (ofs 12, len 5)"
use overload
    '""' => sub ($e, @) {
        my ($action, $where, $node) = @$e{qw(action where node)};
        my $on   = $node ? join '', map { '/' . s/~/~0/gr =~ s{/}{~1}gr } @{ $node->{path} } : '';
        my $span = $node && defined $node->{ofs} ? " (ofs $node->{ofs}, len $node->{len})" : '';
        return "$e->{code}: $e->{message}"
            . (defined $action       ? " in $action"                              : '')
            . (length($where // '')  ? " at $where"                               : '')
            . (length "$on$span"     ? ', on ' . ($on || 'the document') . $span  : '');
    },
    bool     => sub { 1 },
    fallback => 1;

sub new ($class, %field) { bless {%field}, $class }

sub code    { $_[0]{code} }       # NO_MATCH, INVALID_TARGET, INVALID_OPERAND, INVALID_GRAFT,
                                  # UNSUPPORTED_GRAFT or RESOURCE_LIMIT
sub message { $_[0]{message} }

# The action concerned: its name, and where it is in the graft, as a JSON
# Pointer (RFC 6901) into the structure that was compiled.  The pointer of
# the graft as a whole is the empty string.
sub action  { $_[0]{action} }
sub where   { $_[0]{where} }

sub expr    { $_[0]{expr} }       # the expression that always fails, if that was found when compiling

# From a run: where the node that the action was working on is in the
# document, in the form of a capture.  { path } is the keys that lead to it;
# for a piece of a string (inside ATSPLIT) they lead to the string, and
# { ofs, len, lim } say which characters of it the piece is.
sub node    { $_[0]{node} }

# From a run: the document as the failure left it, and the log.
sub partial { $_[0]{partial} }
sub logs    { $_[0]{logs} }

# From a run: the structure of a graft that turns that document back into
# the input.  It is worked out when first asked for.
sub undo ($e) { exists $e->{input} ? $e->{undo} //= JGraft::Undo::graft(@$e{qw(left input origin)}) : undef }

1;
