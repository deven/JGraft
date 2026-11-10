package JGraft::Ordered;

# A hash that keeps its keys in order, as the objects of a JSON text do.
#
# Perl's own hashes keep no order, so an object read from JSON with a view to
# writing it back is tied to this class instead.  It behaves as any hash:
# setting a property that is there leaves it where it is, a new one goes to
# the end, and one that is deleted and set again goes to the end too.  The
# engine reads and writes such an object without knowing what it is; only
# where it makes a new object, or a copy of one, does it choose this kind.
#
# The tie is an array: [ the values by key, the keys in order, the place
# reached by `each` ].

use v5.36;

# A reference to a new ordered hash, holding these pairs.
sub hash (@pairs) {
    tie my %h, __PACKAGE__;
    while (my ($key, $value) = splice @pairs, 0, 2) { $h{$key} = $value }
    return \%h;
}

# Is this hash an ordered one?
sub is ($h) { ref tied %$h eq __PACKAGE__ }

# A copy of a hash, ordered if it is.
sub copy ($h) {
    my $tie = tied %$h or return {%$h};
    tie my %copy, __PACKAGE__;
    @{ tied %copy }[ 0, 1 ] = ({ %{ $tie->[0] } }, [ @{ $tie->[1] } ]);
    return \%copy;
}

# Where a key is among the keys, and (with a place given) put there: a key
# renamed takes the place of the one it was.  Both are for ordered hashes.
sub place ($h, $key, $at = undef) {
    my $keys = tied(%$h)->[1];
    my ($i) = grep { $keys->[$_] eq $key } 0 .. $#$keys;
    return $i unless defined $at && defined $i;
    splice @$keys, $i, 1;
    splice @$keys, ($at > @$keys ? scalar @$keys : $at), 0, $key;
    return $at;
}

sub TIEHASH ($class)      { bless [ {}, [], 0 ], $class }
sub FETCH   ($t, $k)      { $t->[0]{$k} }
sub EXISTS  ($t, $k)      { exists $t->[0]{$k} }
sub SCALAR  ($t)          { scalar @{ $t->[1] } }
sub STORE   ($t, $k, $v)  { exists $t->[0]{$k} or push @{ $t->[1] }, $k; $t->[0]{$k} = $v }
sub CLEAR   ($t)          { %{ $t->[0] } = (); @{ $t->[1] } = () }
sub FIRSTKEY ($t)         { $t->[2] = 0; $t->[1][0] }
sub NEXTKEY ($t, $)       { $t->[1][ ++$t->[2] ] }

sub DELETE ($t, $k) {
    exists $t->[0]{$k} or return undef;
    @{ $t->[1] } = grep { $_ ne $k } @{ $t->[1] };
    return delete $t->[0]{$k};
}

1;
