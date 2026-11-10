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
    return bless { ok => 1, output => $x->{root}, logs => $x->{logs} }, 'JGraft::Result'
        if eval { $self->{code}->($x); 1 };
    my $error = $@;
    die $error unless ref $error && $error->isa('JGraft::Error');
    # The error takes with it what the run left behind, for a caller of
    # `apply`.  It is a copy that does: a fault is the same error in every run.
    my %left = (partial => $x->{root}, logs => $x->{logs});
    return bless { ok => 0, error => JGraft::Error->new(%$error, %left), %left }, 'JGraft::Result';
}

# Apply the graft and return the output, dying with a JGraft::Error on failure.
sub apply ($self, $input, %opt) {
    my $result = $self->run($input, %opt);
    die $result->error unless $result->ok;
    return $result->output;
}

package JGraft::Result;

sub ok      { $_[0]{ok} }
sub error   { $_[0]{error} }
sub logs    { $_[0]{logs} }
sub output  { $_[0]{output} }       # only of a run that succeeded
sub partial { $_[0]{partial} }      # only of one that failed: the document as the failure left it

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

=head1 RESULTS AND ERRORS

C<run> returns a result, whatever happens:

    $result->ok         # true if the graft was applied
    $result->output     # the new document, if so
    $result->error      # a JGraft::Error, if not
    $result->partial    # the document as the failure left it, if not
    $result->logs       # what RAISE recorded: [ { level, message, data }, ... ]

A failed run has no C<output>, so that a half-edited document cannot be taken
for a finished one; it is there to inspect as C<partial>.  C<apply> returns
the output, and dies with the error if there is none.

An error has a C<code> (C<NO_MATCH>, C<INVALID_TARGET>, C<INVALID_OPERAND>,
C<INVALID_GRAFT>, C<UNSUPPORTED_GRAFT> or C<RESOURCE_LIMIT>) and a
C<message>, and says which action failed:

    $error->action      # its name: "COPY"
    $error->where       # where it is in the graft: "/3/2"
    $error->node        # where its current node is in the document: { path => ["orders", 0] }
    $error->partial     # as for the result, so that a caller of apply has them
    $error->logs
    "$error"            # "INVALID_TARGET: division by zero in COPY at /3/2, on /orders/0"

C<where> is a JSON Pointer (RFC 6901) into the structure given to C<new>:
C</3/2> is C<< $struct->[3][2] >>, and the graft as a whole is the empty
string.  Faults and warnings found by C<new> are placed in the same way, by
the action they are in.

C<node> says which node the action was working on (the one that C<AT> had
reached, not one that an expression such as C<MAP> was looking at).  It has
the form of a capture.  C<path> is the keys that lead to the node from the
root of C<partial>.  Inside C<ATSPLIT> the nodes are pieces of a string:
then C<path> leads to the string, and C<ofs>, C<len> and C<lim> say which
characters of it the piece is.

    my $node  = $error->node;                   # { path => ["text"], ofs => 57, len => 16, lim => 73 }
    my $piece = substr $error->partial->{text}, $node->{ofs}, $node->{len};

For that to mean anything, a failure inside C<ATSPLIT> leaves the string in
C<partial> as its pieces stood, put back together.  If they could not be
(one of them is no longer a string, say), the string is left as it was and
C<node> has only the path.

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
