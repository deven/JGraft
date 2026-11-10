package JGraft::Error;

use v5.36;

# "INVALID_TARGET: division by zero in COPY at /3/2"
use overload
    '""' => sub ($e, @) {
        my ($action, $where) = @$e{qw(action where)};
        "$e->{code}: $e->{message}" . (defined $action ? " in $action" : '') . (length($where // '') ? " at $where" : '');
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

# From a run: the document as the failure left it, and the log.
sub partial { $_[0]{partial} }
sub logs    { $_[0]{logs} }

1;
