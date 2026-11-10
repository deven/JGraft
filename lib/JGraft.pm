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
    my ($code, $faults, $dates) = JGraft::Compiler->compile($struct, %opt);
    die $faults->[0] if $strict && @$faults;
    return bless { struct => $struct, code => $code, faults => $faults, dates => $dates }, $class;
}

sub struct ($self) { $self->{struct} }
sub faults ($self) { @{ $self->{faults} } }

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

C<limits> is a hash of any of C<ops> (operations performed), C<mem>
(estimated bytes allocated), C<new_obj> (arrays and objects created),
C<prop_per_obj> (properties in any one object) and C<depth> (nesting of
common expressions, 512 unless given).  Apart from C<depth>, what is not
given is not limited.

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

=head1 OPTIONS

C<new>: C<strict> (default 1), C<max_version> (default 1), C<limits>.

C<run> / C<apply>: C<limits>, C<on_raise> (callback for each RAISE record),
C<temp> (initial TEMP namespace), C<date_export> (callback turning a
JGraft::Date into output data; the default is its string form).

=cut
