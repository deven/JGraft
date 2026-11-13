package JGraft;

use v5.36;
use JGraft::Error;
use JGraft::Compiler;
use JGraft::Exec;
use JGraft::Undo;
use Carp qw(croak);
use Scalar::Util qw(blessed looks_like_number refaddr);
no warnings qw(recursion);

# What may be asked of `new` and of `run`, and what may be limited.  A name
# that is not among them is a mistake in the caller, and is not let pass: a
# limit misspelt would be no limit at all.
my %NEW   = map { $_ => 1 } qw(strict max_version limits share exact);
my %RUN   = map { $_ => 1 } qw(limits on_raise temp date_export exact clone);
my %LIMIT = map { $_ => 1 } qw(ops mem new_obj prop_per_obj depth);

sub options ($for, $known, %opt) {
    my @unknown = grep { !$known->{$_} } sort keys %opt;
    croak "JGraft->$for: unknown option" . (@unknown > 1 ? 's' : '') . " @unknown" if @unknown;
    my $limits = $opt{limits} // return;
    ref $limits eq 'HASH' or croak "JGraft->$for: limits must be a hash";
    for my $name (sort keys %$limits) {
        $LIMIT{$name} or croak "JGraft->$for: unknown limit $name";
        my $n = $limits->{$name} // next;       # not defined: not limited (or for depth, as usual)
        looks_like_number($n) && $n >= 0 or croak "JGraft->$for: limit $name must be a number that is not negative";
    }
}

# A copy of a graft's structure, which nothing the caller does afterwards
# can change; and for each array and object of the copy, the one it is a
# copy of, by which an error can point into the structure the caller has.
sub snapshot ($v, $from, $seen = {}) {
    my $kind = ref $v;
    return $v unless $kind eq 'ARRAY' || $kind eq 'HASH';
    return $seen->{ refaddr $v } if $seen->{ refaddr $v };
    my $copy = $seen->{ refaddr $v } = $kind eq 'ARRAY' ? [] : JGraft::Ordered::is($v) ? JGraft::Ordered::hash() : {};
    $from->{ refaddr $copy } = $v;
    if ($kind eq 'ARRAY') { @$copy = map { snapshot($_, $from, $seen) } @$v }
    else                  { $copy->{$_} = snapshot($v->{$_}, $from, $seen) for keys %$v }
    return $copy;
}

our $VERSION = '0.01';

# Compile a decoded JGraft structure.  With `strict` (the default) any fault
# found by static validation is thrown now; otherwise it is thrown only if
# the faulty part of the graft is reached.  `limits` bound the work of
# evaluating the graft's constant expressions (see the documentation below).
sub new ($class, $struct, %opt) {
    options(new => \%NEW, %opt);
    my $strict = delete $opt{strict} // 1;
    my $self   = bless { from => {}, limits => { %{ $opt{limits} // {} } }, share => delete $opt{share}, exact => delete $opt{exact} }, $class;
    $self->{struct} = snapshot($struct, $self->{from});
    @$self{qw(code faults dates warnings)} = JGraft::Compiler->compile($self->{struct}, %opt);
    die $self->theirs($self->{faults}[0]) if $strict && @{ $self->{faults} };
    return $self;
}

# An error, with the expression it names (if it names one) as the caller has it.
sub theirs ($self, $error) {
    my $expr = ref $error->{expr} ? $self->{from}{ refaddr $error->{expr} } : undef;
    return $expr ? JGraft::Error->new(%$error, expr => $expr) : $error;
}

sub struct   ($self) { $self->{struct} }        # the graft's own copy of it
sub faults   ($self) { map { $self->theirs($_) } @{ $self->{faults} } }
sub warnings ($self) { map { $self->theirs($_) } @{ $self->{warnings} } }

# Apply the graft.  Never dies for JGraft errors; returns a JGraft::Result.
# The input is not modified.  The output shares with it what the graft left
# alone, unless it is asked for `clone` (see the documentation below).
sub run ($self, $input, %opt) {
    options(run => \%RUN, %opt);
    # the limits given to `new` are those of every run, but for what a run is given of its own
    # (a run that is to copy all it leaves has no need of copies of what the graft supplies)
    my $x = JGraft::Exec->new($input, %opt, limits => { %{ $self->{limits} }, %{ $opt{limits} // {} } }, dates => $self->{dates},
        share => $self->{share} || $opt{clone},
        exact => $opt{exact} // $self->{exact});         # as the run is told; or the graft was; or else as the document was read
    local $JGraft::Number::EXACT = $x->{exact};      # for the comparisons that have no run to ask
    my $done  = eval { $self->{code}->($x); 1 };
    my $error = $@;
    die $error unless $done || blessed $error && $error->isa('JGraft::Error');
    # What the run left: as the run has it, sharing with the input what it did
    # not touch (from which the undo is worked out); and as the caller is given
    # it, which with `clone` is a copy that shares nothing.  The copy of an
    # output is part of the run, and of what the run costs.  The copy of what
    # a failure left is not: there is nothing more to stop.
    my ($left, $given) = ($x->{root}) x 2;
    if ($opt{clone}) {
        $done = eval { $given = $x->replica($left); 1 } or $error = $@ if $done;
        die $error unless $done || blessed $error && $error->isa('JGraft::Error');      # (something of the caller's own, as above)
        ($given) = $x->aside(sub { $x->replica($left) }) if !$done;
    }
    return bless { ok => 1, output => $given, logs => $x->{logs}, input => $input, left => $left, origin => $x->{origin} }, 'JGraft::Result' if $done;
    # The error takes with it what the run left behind, for a caller of
    # `apply`.  It is a copy that does: a fault is the same error in every run.
    my %left = (partial => $given, logs => $x->{logs}, input => $input, left => $left, origin => $x->{origin});
    return bless { ok => 0, error => JGraft::Error->new(%{ $self->theirs($error) }, %left), %left }, 'JGraft::Result';
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

# The structure of a graft that turns the output, or the partial document of
# a failure, back into the input.  It is worked out when first asked for.
sub undo ($r) { $r->{ok} ? $r->{undo} //= JGraft::Undo::graft(@$r{qw(left input origin)}) : $r->{error}->undo }

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
    $result->undo       # a graft that undoes what the run did (see below)

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
    $error->undo
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

=head1 UNDO

C<< $result->undo >> is the structure of a graft that undoes the run:
applied to the output, it gives the input back.  After a failure it undoes
whatever the run did before it failed, and applies to C<partial>.

    my $result = $graft->run($document);
    my $undo   = $result->undo;                 # [ "JGRAFT", { v => 1 }, [ "SPLICE", ... ], ... ]
    my $before = JGraft->new($undo)->apply($result->output);

It is plain data, to be encoded as JSON and kept, or applied later to
another copy of the same output.

Asking for it costs a run next to nothing, and needs no option: nothing is
recorded while a graft runs but which arrays and objects it copied.  Because the output shares with the input all that the
run left alone, what changed is found by comparing the two when C<undo> is
first called, without looking into anything they share.  So call it before
you change the input, if you ever do.

The undo graft is made to touch as little as it can:

=over

=item *

In an object, it puts back the properties that changed and removes those
that were added.

=item *

In an array, it finds the least change there can be between the two (the
fewest elements to remove and to put back), and makes that with C<SPLICE>.
Elements that are the same before and after, and in the same order, are left
alone however far they have shifted; one that has changed its place among
the others is removed and put back.  An array or object that stands where
one stood is taken to have changed inside, and is undone inside.

=item *

In a string of several lines, it puts back the lines that changed, with an
C<ATSPLIT> on the line breaks, comparing the lines as it would an array.
This does not depend on how the string came to change.

=item *

What the run took from its place and put somewhere else is taken back from
there, and not written out.  A property of an object that became another
property, of that object or of some other, is moved back by a C<MOVE>,
whatever its value is: C<["MOVE", "b", "a"]> undoes a rename, in a text
leaving the value written as it was.  So is a thing taken out of something
that the run made and the undo removes.

An array or object that went somewhere a C<MOVE> cannot simply reach back
from (into or out of an array, or inside something that has to be written
out) is copied aside to C<STASH> before anything else is done, and put back
from there; so is a string of 64 characters or more.  This holds whether the
thing is as it was or was changed after it was moved: it is then put back,
and changed back inside.  A thing of two thousand items is undone in a
hundred bytes or so whichever of these happened to it.

Paths in an undo graft are written as briefly as JGraft allows: a path of one
step is the step, C<"a"> for C<["NODE", "a"]>.

=back

Three things are less than ideal:

=over

=item *

Finding the least change in an array takes work that grows as the square of
the change.  It is given about as much effort as reading the two arrays
takes several times over, which finds any change of up to a few hundred
elements in an array of tens of thousands.  Beyond that the change is found
in a single pass: it may then remove and put back some elements that it
need not have, near the places where the array did change, but never the
long runs that did not.

=item *

A changed element that is right beside elements that came or went is put
back whole, not undone inside.  So is a string of one line, or one that has
no line in common with what it was.

=item *

What was moved is looked for in what the run added and replaced, and inside
that, but only so far: some thousands of places, the nearest first.  A thing
buried deep in a great deal that is new may be written out though it is
there.

=item *

The undo graft does not check that the document it is given is the one it
was made for.

=back

A date in the document (which there can be only if C<date_export> keeps
them) is put back by a C<CASTDATE> expression.

=head1 JSON, WRITTEN BACK AS IT WAS READ

L<JGraft::JSON> reads JSON text so that a graft can be applied to it and the
result written out as the same text, changed only where the data changed.

    use JGraft::JSON;

    my $doc    = JGraft::JSON->parse($bytes);
    my $output = $graft->apply($doc->data);
    my $text   = $doc->write($output);

A text that is read and written with no change between is the same text,
byte for byte.  After a change, what is kept is:

=over

=item *

Everything about a value the graft did not touch: how a number is spelled
(C<1e1>, C<-0>, C<1.50>, an integer of any length), the escapes of a string
(C<"\u00e9">, C<"\/">), white space, and bytes in a string that are not
UTF-8.

=item *

The order of an object's properties, as the graft left it.  A property that
is written over stays where it is; a new one goes last; one that is removed
and added again goes last; and one that is renamed (moved to another name in
the same object, by one pair of a C<MOVE>) stays where it was.  A property
that the text gives twice is kept twice, unless the graft changes or removes
it.

=item *

The spelling of a value that the graft moves or copies from one place to
another: by C<MOVE>, by C<COPY> or C<SPLICE> of a path, through the stash,
through C<FILTER>, C<SLICE> and C<CONCAT>, and as a member of an array or
object that the graft builds.  A value that is worked out (C<ADD>, a literal
in the graft) is written plainly.

=item *

The parts of a string that a change to it left alone.  A changed string is
compared with what it was, line by line and then within the lines that
differ, and only what differs is written anew: an C<ATSPLIT> that changes
one line of ten thousand rewrites that line, and a change to one word of a
long line rewrites that word.  (Where very much of a line has changed, the
whole of the changed stretch is written anew.)

=back

What is new is written as what is around it is written.  A new member or
element has the separators that those beside it have; a new array or object
is laid out as the one it stands in is, each element on a line of its own
and a step further in if that is how its neighbours are, or on one line with
their spacing if they are on one line; and a whole new document, where the
graft has replaced the old, as the old one was laid out.  With nothing to go
by (a text that was one number, say) it is written as compactly as JSON
allows.

C<< $doc->data >> is ordinary data, with three differences.  Its objects are
ordered hashes (L<JGraft::Ordered>, a tied hash that any Perl code can read
and write as a hash); matching against them costs about half as much again
as against plain ones.  And a byte in a string that is not UTF-8 is read as
a character beyond the end of Unicode (0x110000 plus the byte), so that a
graft sees one character there and the byte can be written back.  UTF-8 is
taken strictly for this: bytes that spell a surrogate, an overlong form, or
a code point past 0x10FFFF (those reserved characters among them) are not
UTF-8, and are read byte by byte, so every text comes back as it was.  A
string holding some other character past 0x10FFFF cannot have come from a
text, and C<write> dies if given one.  If a graft joins strings so that
such bytes come together and spell a character between them (the two halves
of one that had been cut in two, say), they become that character.  And
its numbers are read with every digit they have (L</EXACT NUMBERS>): one
that Perl would not write as the same digits, such as C<1.50> or an integer
of thirty digits, is a L<JGraft::Number> and not a number of Perl's own.

    my $doc = JGraft::JSON->parse($bytes, exact => 0);

reads them as Perl reads numbers instead.  Either way a negative zero in
the text (C<-0>, C<-0.0>) is one in the data, which Perl would have read
as 0: it is a zero in every calculation and comparison, but is written back
as it was, and C<CASTSTR> gives C<"-0"> for it.

A number too large or too
precise for Perl is then seen by the graft as the nearest one Perl has,
though it still keeps its spelling if the graft leaves it alone.

C<parse> reads a text of any length, nested to any depth, unless it is told
otherwise:

    my $doc = JGraft::JSON->parse($bytes, max_size => 1e6, max_depth => 200);

C<max_size> is the most bytes the text may have, and C<max_depth> how deep
arrays and objects may be one inside another; a text beyond either is
refused, and C<parse> dies.  Depth is worth limiting for a text that is not
trusted, though no depth breaks anything: each level costs some four
kilobytes while the text is read, so that two megabytes of nothing but
C<[> take four gigabytes.

The graft may be read the same way, C<< JGraft->new(JGraft::JSON->parse($g)->data) >>,
and then an object written in it gives its properties to the output in the
order written there.

As with C<output> in general, treat C<< $doc->data >> as read-only: C<write>
takes an array or object that was read to be still as it was read.

=head1 EXACT NUMBERS

Arithmetic in a graft is Perl's own, as the specification has it, and so
C<[ADD, 0.1, 0.2]> is 0.30000000000000004, and an integer of thirty digits
is only nearly itself.  It can be done in decimal instead, as on paper, and
for a text read by L<JGraft::JSON> it is:

    my $doc  = JGraft::JSON->parse($bytes);
    my $text = $doc->write($graft->apply($doc->data));

    my $output = $graft->apply($data, exact => 1);      # for data that is Perl's own, it is asked for

Whether a run is exact can be said in three places, and the nearest to the
run decides:

=over

=item C<< run >> or C<< apply >>: C<< exact => 1 >> or C<< exact => 0 >>, for that run.

=item C<< new >>: the same, for every run of the graft that is not told otherwise.

=item C<< JGraft::JSON->parse >>: how the text's numbers are read, which is
exactly unless it is given C<< exact => 0 >>.  A run on a document is exact
if the document was read so, unless the run or the graft says otherwise.

=back

A run on data that is Perl's own, of a graft that was told nothing, is not
exact.  Perl's numbers are not decimals, and only the caller knows whether
they stand for decimals: a time held to the microsecond has more digits
than the fifteen Perl writes, and exact arithmetic would take it for those
fifteen (see below).  A document that is nothing but one number or string
has nowhere to say how it was read: say C<exact> to the run or the graft.

In an exact run:

=over

=item *

Sums, differences, products, quotients, remainders and whole powers are
exact, whatever their size.  0.1 and 0.2 make 0.3, and a third, three times,
is 1.

=item *

A number is known to the places it was written with, and the result of a
calculation to the places that follow from them, by the rules that decimal
arithmetic has in other languages (the General Decimal Arithmetic
specification): 0.10 and 0.20 make 0.30, 1.50 times 2.0 is 3.000, and
0.30 less 0.30 is 0.00.  C<CASTSTR> writes those places, C<ROUND> counts
them as significant, and a text written back has them.  They make no
difference to what a number is worth: 0.30 matches 0.3.

=item *

A quotient that ends is the decimal (1 by 8 is 0.125).  One that does not
is kept as the fraction it is, and calculated with as a fraction: so 10 by
3, times 0.9, is 3.0.  It is given digits only when it is written, by
C<CASTSTR> or C<ROUND> or into a text: 34 significant digits, or as many as
C<$JGraft::Number::DIGITS> says.  It keeps count of the places meanwhile:
1.00 by 3, times 3, is 1.00.

=item *

C<LOG>, and C<POW> to a power that is not whole, are Perl's own and no more
exact than that.

=item *

No number is out of range.  C<CASTNUM> of C<"1e400"> is that number, where a
run that is not exact fails with C<UNSUPPORTED_GRAFT>; C<ROUND> to an
integer gives one of any length.  What a long number costs is counted
against C<ops> and C<mem>, a digit at a time, and a number of more than a
billion digits is not attempted (C<UNSUPPORTED_GRAFT>).

=back

A number that comes out is one of Perl's own if, and only if, Perl writes
that number as the same digits: 0.3 is, and 12, and 1e25.  Nothing is lost
by it.  Whatever then prints or encodes the number says what the exact
number said, and an exact run that meets it again reads it as those digits,
so that a calculation goes on from it exactly.  Any other number is an
object, a L<JGraft::Number>: one written to a place that Perl would drop
(0.30), one of more than the fifteen digits that Perl writes or of more
than its integers hold, one beyond its range, or a fraction that no decimal
says.  (Of a fraction, C<< $n->repeating >> gives the form taught in school,
with the digits that repeat marked: C<0.(3)>, C<0.1(6)>, C<0.(142857)>; or
nothing, if more than a thousand digits repeat.)  Such an object reads as
the number
(C<"$n"> is C<0.30>), compares as it, and can be calculated with as Perl
calculates (C<$n + 1>, inexactly); C<< JGraft::JSON->encode >> writes it
in full, as C<write> does.

Numbers of that class, and C<Math::BigInt> and C<Math::BigFloat> objects, are
numbers wherever they are met in the data or in a graft, in any run, and
arithmetic on one is exact whether or not the run is.

One of Perl's own numbers is, in exact arithmetic, the decimal that Perl
writes it as, and never the binary number that Perl holds: the 0.1 of a
Perl program is a tenth, though what is held is a little more.  Perl writes
fifteen digits, so a number that some earlier binary arithmetic has left as
0.30000000000000004 is 0.3 here.  A number with more digits than that has to
arrive exact to be exact: read by C<JGraft::JSON>, or cast from a string by
C<CASTNUM>.

Comparison goes the same way.  In an exact run two numbers are equal if
Perl writes them as the same number, whichever kind each is: so the
0.30000000000000004 that binary arithmetic made of 0.1 and 0.2 matches 0.3,
is not less than it, and lies within a bound of it.  And where a whole
number is needed (an index, a count, a length, the code of a character) a
number that Perl writes as whole is whole: the 3.0000000000000004 that
binary arithmetic left is the index 3, which in a run that is not exact is
refused as a fraction.

An index worked out by exact arithmetic is therefore as good as the
arithmetic: C<[MUL, [ADD, 0.1, 0.2], 10]> is 3, and so is
C<[MUL, [DIV, 10, 3], 0.9]>.

It costs time: some tens of times what Perl's own arithmetic does, for each
operation that is not on whole numbers, and more for numbers longer than
eighteen digits.

=head1 WHAT THE OUTPUT SHARES

Applying a graft copies only what it must, and so the output is not, by
default, all its own.

B<With the input> it shares everything the graft left untouched: an edit to
one field of a large document costs that field.  Changing such a part of
the output changes the input.

B<With itself>: a value that the graft copied from one place to another
(C<[COPY, [NODE, "a"], "b"]>) is one value in both places, and changing it
in one changes it in the other.

B<With the graft> it shares nothing.  An array or object written in the
graft, or worked out from what is written there when the graft was compiled,
is copied each time a run produces it, and the copy is the caller's.  (A
constant declared in C<const> is the exception that costs nothing: the graft
keeps the one value, however large, and a run copies only what it reads out
of it.)

Two options change this.

=over

=item C<< clone => 1 >>, to C<run> or C<apply>

What the run hands back to be changed shares nothing with anything, and
every array and object in it can be changed freely: the output, or after a
failure the C<partial> document.  The output is copied whole when the run
ends, which takes time and
memory in proportion to its size written out, and is counted against the
run's limits.  Read from a text by L<JGraft::JSON>, it is still written
back as it was read wherever the caller has not changed it.

Data that holds itself (which JSON cannot say, but Perl data can be) is
copied with the shape it has: the copy holds itself in the same places, and
holds once what the data holds in several.

Such a run is itself handed the graft's own arrays and objects, as with
C<share>: all that it leaves is copied in any case, so nothing of the graft
gets out.  C<undo> is not affected, and undoes the output as the run gave
it, before any change the caller makes.

=item C<< share => 1 >>, to C<new>

The graft does not copy what it supplies: every run is handed the same
arrays and objects.  This is faster where one literal is produced many times
(for each of 200,000 elements, eight to fourteen times faster in that part),
and then the output must be treated as read-only.  Perl enforces part of
that: such arrays, their elements, and the values of such objects'
properties are marked read-only, and changing one dies with
C<Modification of a read-only value attempted>.  It cannot enforce the
rest: adding or deleting a property of such an object changes what the graft
produces from then on, silently.

=back

Without C<clone>, to change an output safely, change a deep copy of it
(C<Storable::dclone>, or encode and decode it as JSON).  The same goes for
C<partial>.

C<logs> are for reading, in any run.  A log and its records are new for each
run, but the data of a record is the value the graft gave to C<RAISE>, as it
was at that moment: most often a part of the document, which is the input's
own, and in a run with C<share> or C<clone> perhaps a value of the
graft's.  Keeping it costs nothing, where a copy would cost as much as the
value is large each time something is logged.  To change it, change a copy.

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

Give limits to C<new>, and they bound everything the graft does:

    my $graft  = JGraft->new($untrusted, limits => { ops => 1e6, mem => 1e8 });
    my $result = $graft->run($input);

C<new> does work too: it evaluates, once, every expression in the graft that
does not depend on the data, so that no run has to.  The limits are its
allowance for that, for the whole graft.  It does not fail for want of it:
whatever the limits do not allow it to evaluate is left for the runs that
reach it.

Each run then has the same limits, all of them, however many runs there
are; one that exceeds them fails with C<RESOURCE_LIMIT>.  Limits given to
C<run> replace, one by one, those given to C<new>, and a limit given as
C<undef> is no limit:

    $graft->run($large, limits => { ops => 1e8 });      # mem is still 1e8

Limits given to C<run> alone do not cover an expensive constant, which
C<new> will already have computed.  So if a graft is not trusted, C<new> is
where the limits go.

A limit must be a number that is not negative, and a name that is not one
of those above is refused (C<new> and C<run> C<croak>): a limit misspelt
would not be one.

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

C<new>: C<strict> (default 1), C<max_version> (default 1), C<limits>,
C<share> (see L</WHAT THE OUTPUT SHARES>), C<exact> (for every run that is
not told otherwise: see L</EXACT NUMBERS>).

C<run> / C<apply>: C<limits>, C<on_raise> (callback for each RAISE record),
C<temp> (initial TEMP namespace), C<date_export> (callback turning a
JGraft::Date into output data; the default is its string form), C<exact>
(decimal arithmetic: see L</EXACT NUMBERS>; the default is as C<new> was
told, or else as the document was read), C<clone> (an output that shares nothing: see
L</WHAT THE OUTPUT SHARES>).

An option that is not one of these is refused: C<new> and C<run> C<croak>.

C<new> takes a copy of the structure it is given, so nothing done to that
structure afterwards changes the graft.  C<struct> returns the copy.  Where
an error names an expression (C<expr>), it is the expression in the
structure that was given.

=cut
