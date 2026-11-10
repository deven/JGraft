package JGraft::Error;

use v5.36;

use overload
    '""'     => sub { "$_[0]{code}: $_[0]{message}" . ($_[0]{where} ? " in $_[0]{where}" : '') },
    bool     => sub { 1 },
    fallback => 1;

sub new ($class, %field) { bless {%field}, $class }

sub code    { $_[0]{code} }       # NO_MATCH, INVALID_TARGET, INVALID_OPERAND, INVALID_GRAFT,
                                  # UNSUPPORTED_GRAFT or RESOURCE_LIMIT
sub message { $_[0]{message} }
sub where   { $_[0]{where} }      # name of the action that was running
sub expr    { $_[0]{expr} }       # the expression that always fails, if that was found when compiling

1;
