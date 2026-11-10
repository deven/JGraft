package JGraft::Source;

# Where the values of a document came from in the text it was read from.
#
# JGraft::JSON keeps, beside each array and object that it reads, a record of
# where it and each of its members lie in the text.  When the engine copies
# such a container in order to change it, or moves a value from one place to
# another, it keeps this up: each slot of a container has a "token", the
# place in some text where its value was written.  JGraft::JSON can then
# write a result out as the text it came from, changed only where the values
# changed.
#
# A token is [ start, end, \$text ].  It is a hint, not a promise: whoever
# uses one checks that it still says what the value is.  So nothing here can
# make a result wrong; at worst a value is written afresh.
#
# What is kept for a container is a "sheet":
#   { rec => record }                 as it was read (and it is never changed)
#   { from => record, tok => tokens } a copy of one that was read, with the
#                                     tokens of its slots as they now are
#   { tok => tokens }                 one that a run made
# The tokens of an array are a list beside its elements; of an object, a
# hash by key.  A record is { text, start, end } with `items` (the tokens of
# an array's elements) or `members` ([ key, key start, key end, token ] for
# each member of an object, as written, duplicates and all).
#
# Sheets are kept by the identity of the container, and go when it does.

use v5.36;
use Hash::Util::FieldHash qw(fieldhash);

fieldhash my %SHEET;

sub sheet ($c) { $SHEET{$c} }

# Called by the reader of a text, for each container it makes.
sub read_as ($c, $record) { $SHEET{$c} = { rec => $record } }

# The tokens of a container, to look at.
sub tokens ($c) {
    my $sheet = $SHEET{$c} or return undef;
    return $sheet->{tok} if $sheet->{tok};
    my $rec = $sheet->{rec} or return undef;
    return $rec->{items} // ($rec->{tok} //= { map { $_->[0] => $_->[3] } @{ $rec->{members} } });
}

# The same, to change: for a container that a run made or copied.
sub own ($c) {
    my $sheet = $SHEET{$c} //= {};
    return $sheet->{tok} //= ref $c eq 'ARRAY' ? [] : {};
}

# The token of one slot.
sub token ($c, $k) {
    my $tok = tokens($c) or return undef;
    return ref $tok eq 'ARRAY' ? $tok->[$k] : $tok->{$k};
}

# $new is a copy of $old, made in order to be changed.
sub cloned ($old, $new) {
    my $sheet = $SHEET{$old} or return;
    my $tok   = tokens($old);
    $SHEET{$new} = { from => $sheet->{rec} // $sheet->{from}, tok => ref $new eq 'ARRAY' ? [ @{ $tok // [] } ] : { %{ $tok // {} } } };
}

# The value now in a slot came from this token (or, with none, from nowhere
# that is known: what was there before is left as a hint to what it was).
sub set ($c, $k, $tok = undef) {
    return unless defined $tok || $SHEET{$c};
    my $own = own($c);
    if (ref $own eq 'ARRAY') {
        $#$own = $k - 1 if $#$own < $k - 1;        # a new last element
        $own->[$k] = $tok if defined $tok || $k > $#$own;
    }
    elsif (defined $tok) { $own->{$k} = $tok }
}

# A property is gone, or an element has given up its place.
sub unset ($c, $k) {
    my $sheet = $SHEET{$c} or return;
    my $own   = own($c);
    ref $own eq 'ARRAY' ? ($own->[$k] = undef) : delete $own->{$k};
}

# Elements $i .. $i + $n - 1 of an array of $length are about to be replaced
# by ones that came from these tokens.
sub spliced ($a, $length, $i, $n, @tok) {
    return unless $SHEET{$a} || grep { defined } @tok;
    my $own = own($a);
    $#$own = $length - 1;
    splice @$own, $i, $n, @tok;
}

# An array has been made over, and these are the tokens of its elements.
sub rebuilt ($a, @tok) {
    return unless $SHEET{$a} || grep { defined } @tok;
    @{ own($a) } = @tok;
}

# A new container has been made, of values that came from these tokens.
sub made ($c, $tok) {
    $SHEET{$c} = { tok => $tok } if grep { defined } ref $tok eq 'ARRAY' ? @$tok : values %$tok;
}

1;
