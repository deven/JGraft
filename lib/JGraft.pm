package JGraft;

use v5.36;
use JGraft::Error;
use JGraft::Compiler;
use JGraft::Exec;

our $VERSION = '0.01';

# Compile a decoded JGraft structure.  With `strict` (the default) any fault
# found by static validation is thrown now; otherwise it is thrown only if
# the faulty part of the graft is reached.  `limits` bound the work of
# evaluating the graft's constant expressions (see the documentation below).
sub new ($class, $struct, %opt) {
    my $strict = delete $opt{strict} // 1;
    my ($code, $faults, $dates, $warnings) = JGraft::Compiler->compile($struct, %opt);
    die $faults->[0] if $strict && @$faults;
    return bless { struct => $struct, code => $code, faults => $faults, dates => $dates, warnings => $warnings }, $class;
}

sub struct   ($self) { $self->{struct} }
sub faults   ($self) { @{ $self->{faults} } }
sub warnings ($self) { @{ $self->{warnings} } }

# Apply the graft.  Never dies for JGraft errors; returns a JGraft::Result.
# The input is not modified.  The output shares structure with it and with
# the graft, and is to be treated as read-only (see the documentation below).
sub run ($self, $input, %opt) {
    my $x = JGraft::Exec->new($input, %opt, dates => $self->{dates});
    my $error;
    eval { $self->{code}->($x); 1 } or do {
        $error = $@;
        die $error unless ref $error && $error->isa('JGraft::Error');
    };
    return bless { ok => !$error, error => $error, output => $x->{root}, logs => $x->{logs} },
        'JGraft::Result';
}

# Apply the graft and return the output, dying with a JGraft::Error on failure.
sub apply ($self, $input, %opt) {
    my $result = $self->run($input, %opt);
    die $result->error unless $result->ok;
    return $result->output;
}

package JGraft::Result;

sub ok     { $_[0]{ok} }
sub error  { $_[0]{error} }
sub logs   { $_[0]{logs} }
sub output { $_[0]{output} }    # after a failure: the tree as it stood

1;

__END__

=head1 NAME

JGraft - apply JGraft edits to trees of JSON-like data

=head1 SYNOPSIS

    my $graft  = JGraft->new($decoded_json);
    my $output = $graft->apply($input);              # dies with a JGraft::Error

    my $result = $graft->run($input, limits => { ops => 1e6, depth => 100 });
    say $result->ok ? 'applied' : $result->error;

A compiled graft can be applied any number of times, and never modifies its
input.

=head1 THE OUTPUT IS READ-ONLY

Applying a graft copies only what it must.  The output shares with the input
everything the graft left untouched, and shares with the graft itself the
arrays and objects that the graft supplied: those written in it, and those
computed from them when it was compiled.  The same is true of the data in
C<logs>.

So treat the output as read-only.  To change it, change a deep copy
(C<Storable::dclone>, or encode and decode it as JSON).

Perl enforces part of this.  In data that came from the graft, arrays, their
elements, and the values of an object's properties are marked read-only, and
changing one dies with C<Modification of a read-only value attempted>.

The rest it cannot enforce, and getting it wrong fails silently:

=over

=item *

Adding or deleting a property of an object that came from the graft changes
what the graft produces from then on.  (Perl can lock a hash's keys, but then
reading a key it lacks is an error too.)

=item *

Changing anything shared with the input changes the input.

=back

=head1 LIMITS

C<limits> is a hash of any of these.  Apart from C<depth>, what is not given
is not limited.

=over

=item C<ops>

Operations performed.  Only work that grows with the data is counted, an
element or a character at a time.

=item C<mem>

Estimated bytes allocated.

=item C<new_obj>

Arrays and objects created as values: those written in the graft with
computed members, those created on the way to a path that did not exist,
captures, and the results of functions (C<MAP>, C<SPLIT>, C<MKOBJ> and so
on).  Changing or copying an array or object that exists does not count,
though the engine may copy it internally.

=item C<prop_per_obj>

The number of properties an object may have when it is created, or once it
has been given another.  A larger object in the input can be read, changed
and reduced, but not added to.  Arrays are not objects, however long.

=item C<depth>

Calls of common expressions (C<EXPR>) in progress at once: 512 unless given.

=back

Limits bound the work done by the call they are given to, and C<new> does
work too: it evaluates, once, every expression in the graft that does not
depend on the data, so that no run has to.

    my %limits = (limits => { ops => 1e6, mem => 1e8 });
    my $result = JGraft->new($untrusted, %limits)->run($input, %limits);

A run that exceeds its limits fails with C<RESOURCE_LIMIT>.  C<new> does
not fail: whatever its limits do not allow it to evaluate is left for the
runs that reach it, under their limits.  Given to C<new>, the limits are an
allowance for the whole graft.

So if a graft is not trusted, give limits to both.  Limits given to C<run>
alone do not cover an expensive constant, which C<new> will already have
computed.

=head1 FAULTS AND WARNINGS

C<new> checks the graft, and with C<strict> (the default) dies with the
first fault it finds: a L<JGraft::Error> whose code is C<INVALID_GRAFT> or
C<UNSUPPORTED_GRAFT>.  With C<< strict => 0 >> a fault is raised only by a
run that reaches the faulty part, and C<< $graft->faults >> lists them all.

Evaluating the expressions that do not depend on the data also shows which
of them always fail, and there are two kinds:

=over

=item *

One that fails with C<INVALID_OPERAND> was given something it can never
accept, such as C<["SLICE", "abc", "x"]>.  That is a mistake in the graft,
so it is a fault, wherever the expression is: even in a match, which would
otherwise take the failure to mean "does not match".

=item *

One that fails with C<INVALID_TARGET>, such as C<["DIV", 1, 0]>, is not a
fault.  The graft may be valid all the same: the expression may be in a
branch that is not taken, or be one alternative in a match.  It behaves as
it always did, and C<< $graft->warnings >> has a warning for it.

=back

    warn "$_\n" for $graft->warnings;       # INVALID_TARGET: division by zero

A warning is the L<JGraft::Error> that the expression raises.  Its C<expr>
is the expression: the same array that is in the structure given to C<new>,
and the innermost one that fails.  (A fault of the first kind has an C<expr>
too.)  Nothing is said about a failure that the graft asks for, with
C<FAIL> or with a C<CASE> that has no default.

Only what C<new> evaluates is checked in this way, so its C<limits> can
leave an expression unexamined.

=head1 OPTIONS

C<new>: C<strict> (default 1), C<max_version> (default 1), C<limits>.

C<run> / C<apply>: C<limits>, C<on_raise> (callback for each RAISE record),
C<temp> (initial TEMP namespace), C<date_export> (callback turning a
JGraft::Date into output data; the default is its string form).

=cut
