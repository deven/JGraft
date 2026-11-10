package JGraft::Exec;

# The state of one run, and the only code that changes a data tree.
#
# Trees are immutable: a container reachable from a namespace is modified in
# place only if this run created it by cloning and nothing else can refer to
# it ("owned").  Everything else is path-copied on write, so the input is
# never touched, COPY can share structure, and RAISE data is a snapshot.

use v5.36;
use builtin qw(refaddr);
no warnings qw(experimental::builtin recursion);
use JGraft::Util;
use JGraft::Error;

use constant INF => 9**9**9;

sub new ($class, $input, %opt) {
    my $limit = $opt{limits} // {};
    return bless {
        root => $input, at => [],                       # node namespace and the path to the current node
        node => $input, nkey => undef, nparent => undef, # the current node, cached for actions
        const => {}, stash => {}, temp => $opt{temp} // {}, cap => {},
        caps => {}, path => [], capturing => 0,          # capture pass
        (map { $_ => $limit->{$_} // INF } qw(ops mem new_obj prop_per_obj)),
        depth => 0, max_depth => $limit->{depth} // 512,
        owned => {}, side => {}, moving => 0,
        dates => $opt{dates} // \0,     # whether the graft is one that makes dates
        quiet => 0, where => undef, logs => [], opt => \%opt,
        folding => 0,                   # set by the compiler, when evaluating a constant expression
    }, $class;
}

# Argument list for evaluating an expression at action level.
sub env ($x) { ($x, @$x{qw(node nkey nparent)}) }

# Dates exist only inside the engine.  A value on its way out of it, into the
# document or the log, comes through here to have its dates replaced.  Nothing
# is looked at unless the graft is one that makes dates.
sub outgoing ($x, $v) { ref $v && ${ $x->{dates} } ? $x->export($v) : $v }

# $v with its dates replaced, copying only the arrays and objects that held one.
sub export ($x, $v) {
    my $r = ref $v;
    return ($x->{opt}{date_export} // \&JGraft::Date::str)->($v) if $r eq 'JGraft::Date';
    my $array = $r eq 'ARRAY';
    return $v unless $array || $r eq 'HASH';
    my $copy;
    for my $k ($array ? 0 .. $#$v : keys %$v) {
        my $old = $array ? $v->[$k] : $v->{$k};
        ref $old or next;
        my $new = $x->export($old);
        next if ref $new && refaddr($new) == refaddr($old);
        $copy //= $array ? [@$v] : {%$v};
        $array ? ($copy->[$k] = $new) : ($copy->{$k} = $new);
    }
    return $copy // $v;
}

#---------------------------------------------------------------------------
# Errors and limits

my %PROBE = map { $_ => JGraft::Error->new(code => $_, message => 'failed probe', soft => 1) }
    qw(INVALID_TARGET INVALID_OPERAND);

sub fail ($x, $code, $message) {
    die JGraft::Error->new(code => $code, message => $message, where => $x->{where});
}

# The two recoverable errors.  Under a match they are routine, so they cost
# nothing to raise there.  A failure is `meant` if the graft asks for it.
sub fail_target ($x, $message, $meant = 0) {
    die $x->{quiet} ? $PROBE{INVALID_TARGET} : JGraft::Error->new(
        code => 'INVALID_TARGET', message => $message, where => $x->{where}, soft => 1, meant => $meant);
}

sub fail_operand ($x, $message) {
    die $x->{quiet} ? $PROBE{INVALID_OPERAND}
        : JGraft::Error->new(code => 'INVALID_OPERAND', message => $message, where => $x->{where}, soft => 1);
}

sub limit ($x, $which) { $x->fail(RESOURCE_LIMIT => "$which limit exceeded") }

# Account for work proportional to data: $ops steps producing $mem bytes.
sub charge ($x, $ops, $mem = 0) {
    ($x->{ops} -= $ops) >= 0 or $x->limit('ops');
    ($x->{mem} -= $mem) >= 0 or $x->limit('mem') if $mem;
}

# Account for a new container with $props members.
sub charge_obj ($x, $props) {
    --$x->{new_obj} >= 0            or $x->limit('new_obj');
    $props <= $x->{prop_per_obj}    or $x->limit('prop_per_obj');
}

#---------------------------------------------------------------------------
# Reading

# Called on every value a reference expression hands out: it may now be
# referenced from a second place, so it can no longer be modified in place.
sub escape ($x, $v) {
    if (my $r = ref $v) {
        $x->fail_target('no such value') if $r eq 'JGraft::Missing';
        delete $x->{owned}{ refaddr $v };
    }
    return $v;
}

# The concrete index that path key $k names in array $a.
sub index_for ($x, $a, $k, $write = 0) {
    my $n = @$a;
    my $i = !defined $k ? $n : $k < 0 ? $n + $k : $k;
    $i >= 0 && $i <= $n - !$write or $x->fail_target('array index out of range');
    return $i;
}

# One step of a read path.
sub step ($x, $v, $k) {
    my $r = ref $v;
    if ($r eq 'HASH') {
        return $v->{$k} if !is_idx($k) && exists $v->{$k};
    }
    elsif ($r eq 'ARRAY') {
        if (is_idx($k)) {
            my $e = $v->[ $x->index_for($v, $k) ];
            return $e unless ref $e eq 'JGraft::Missing';
        }
    }
    elsif ($r eq 'JGraft::Date') {
        my $e = $v->prop($k);
        return $e if defined $e;
    }
    $x->fail_target('path does not exist');
}

# Follow @keys from $v; return them with array aliases resolved.
sub locate ($x, $v, @keys) {
    return map {
        my $k = ref $v eq 'ARRAY' && is_idx($_) ? $x->index_for($v, $_) : $_;
        $v = $x->step($v, $k);
        $k;
    } @keys;
}

sub walk ($x, $v, @keys) {
    $v = $x->step($v, $_) for @keys;
    return $v;
}

#---------------------------------------------------------------------------
# Writing

sub clone ($x, $c) {
    my $hash  = ref $c eq 'HASH';
    my $new   = $hash ? {%$c} : [@$c];
    my $owned = $x->{owned};
    delete @$owned{ map { refaddr $_ } grep { ref } $hash ? values %$c : @$c } if %$owned;
    $owned->{ refaddr $new } = $new;        # holding it keeps the address from being reused
    if (my $side = $x->{side}{ refaddr $c }) {
        my $copy = $x->side($new);
        $copy->{split} = { %{ $side->{split} }, m => [ @{ $side->{split}{m} } ] } if $side->{split};
        $copy->{pend}  = delete $side->{pend} if $side->{pend};
    }
    $x->charge(scalar($hash ? keys %$new : @$new), sizeof($new));
    return $new;
}

# A container we may modify, of the kind that key $k can index.
sub own ($x, $v, $k) {
    ref $v eq (is_idx($k) ? 'ARRAY' : 'HASH') or $x->fail_target('path does not fit the data');
    return $x->{owned}{ refaddr $v } ? $v : $x->clone($v);
}

# Make every container along keys[0 .. $n-1] modifiable, creating missing
# ones, and return the container that keys[$n] indexes.
sub own_path ($x, $slot, $keys, $n) {
    my $c = $$slot = $x->own($$slot, $keys->[0]);
    for my $i (0 .. $n - 1) {
        my $array = ref $c eq 'ARRAY';
        my $k     = $array ? $x->index_for($c, $keys->[$i], 1) : $keys->[$i];
        my $child = $array ? ($k < @$c ? $c->[$k] : $MISSING) : exists $c->{$k} ? $c->{$k} : $MISSING;
        if (ref $child eq 'JGraft::Missing') {      # absent, or an element whose removal is pending
            $child = is_idx($keys->[ $i + 1 ]) ? [] : {};
            $x->{owned}{ refaddr $child } = $child;
            $x->charge_obj(0);
            $array ? ($c->[$k] = $child) : ($c->{$k} = $child);
            $x->arrived($c, $k) if $array;
        }
        else {
            $child = $x->own($child, $keys->[ $i + 1 ]);
            $array ? ($c->[$k] = $child) : ($c->{$k} = $child);
        }
        $c = $child;
    }
    return $c;
}

# The root slot and full key list for a path in namespace $ns.
sub slot ($x, $ns, $keys) {
    return $ns eq 'node' ? (\$x->{root}, [ @{ $x->{at} }, @$keys ]) : (\$x->{$ns}, $keys);
}

# Assign $v at a path (COPY).  $meta is what $v carries from a SPLIT array.
sub put ($x, $ns, $keys, $v, $meta = undef) {
    my ($slot, $k) = $x->slot($ns, $keys);
    if (!@$k) {
        $$slot = $v;                # the root of the node namespace
    }
    else {
        my $c = $x->own_path($slot, $k, $#$k);
        if (ref $c eq 'HASH') {
            exists $c->{ $k->[-1] } or $x->charge_obj(1 + keys %$c);
            $c->{ $k->[-1] } = $v;
        }
        else {
            my $i      = $x->index_for($c, $k->[-1], 1);
            my $append = $i == @$c;
            $c->[$i] = $v;
            $x->arrived($c, $i, $meta) if $append;
        }
    }
    $x->refresh if $ns eq 'node';
}

# Replace $count elements at the array element a path names (SPLICE).
sub splice_at ($x, $ns, $keys, $count, $new, $metas) {
    my ($slot, $k) = $x->slot($ns, $keys);
    @$k && is_idx($k->[-1]) or $x->fail_target('SPLICE needs an element of an array');
    $x->walk($$slot, @$k[ 0 .. $#$k - 1 ]);        # no containers are created on the way
    my $c    = $x->own_path($slot, $k, $#$k);
    my $i    = $x->index_for($c, $k->[-1], 1);
    my $rest = @$c - $i;
    my $n    = !defined $count ? $rest : $count < 0 ? $rest + $count : $count;
    $n >= 0 && $n <= $rest or $x->fail_target('SPLICE count out of range');
    $x->charge(scalar @$new, 8 * @$new);
    my $old = @$c;
    splice @$c, $i, $n, @$new;
    my ($first) = grep { $_ } @$metas;
    my @only    = $x->split_of($c) ? ($i, $i + $#$new) : ();
    if (my $split = $x->split_of($c) // ($first && ($x->side($c)->{split} = { origin => $first->[0], m => [] }))) {
        $#{ $split->{m} } = $old - 1;
        splice @{ $split->{m} }, $i, $n, map { $_ && $_->[0] == $split->{origin} ? [ @$_[ 1 .. 3 ] ] : undef } @$metas;
        $x->settle($c, @only);
    }
    $x->refresh if $ns eq 'node';
}

# Recompute the cached current node after the node namespace changed.
sub refresh ($x) {
    my ($v, $k, $p) = ($x->{root});
    for (@{ $x->{at} }) {
        ($p, $k) = ($v, $_);
        $v = ref $p eq 'HASH' ? (exists $p->{$_} ? $p->{$_} : $MISSING)
           : ref $p eq 'ARRAY' && $_ < @$p ? $p->[$_] : $MISSING;
    }
    @$x{qw(node nkey nparent)} = ($v, $k, $p);
}

#---------------------------------------------------------------------------
# MOVE.  Removing an array element leaves a placeholder and a pending
# deletion; insertions between elements are queued.  Both are carried out
# when the action ends, so indices stay stable while it runs.

# Detach and return the value at a path, with any SPLIT metadata it carries.
sub take ($x, $ns, $keys) {
    my ($slot, $k) = $x->slot($ns, $keys);
    my @k = $x->locate($$slot, @$k);                # it must exist
    my ($v, $meta);
    if (!@k) {
        ($v, $$slot) = ($$slot, $MISSING);
    }
    else {
        my $c = $x->own_path($slot, \@k, $#k);
        my $i = $k[-1];
        if (ref $c eq 'HASH') {
            # the current node keeps its place, to be filled before the action ends
            $v = @$keys ? delete $c->{$i} : $c->{$i};
            $c->{$i} = $MISSING unless @$keys;
        }
        else {
            ($v, $meta) = ($c->[$i], $x->elem_meta($c, $i));
            $c->[$i] = $MISSING;
            $x->set_meta($c, $i, undef);
            $x->pend($c)->{del}{$i} = 1 if @$keys;
        }
    }
    $x->refresh if $ns eq 'node';
    return ($v, $meta);
}

# Attach a value at a path.
sub give ($x, $ns, $keys, $v, $meta) {
    my ($slot, $k) = $x->slot($ns, $keys);
    if (!@$k) {
        $$slot = $v;
    }
    else {
        my $c = $x->own_path($slot, $k, $#$k);
        my $i = $k->[-1];
        if (ref $c eq 'HASH') {
            $c->{$i} = $v;
        }
        elsif (defined $i && $i != int $i) {        # a half index: insert between elements, later
            $i += @$c if $i < -0.5;
            $i >= -0.5 && $i < @$c or $x->fail_target('array index out of range');
            push @{ $x->pend($c)->{ins}{$i} }, [ $v, $meta ];
        }
        else {
            $i = $x->index_for($c, $i, 1);
            my $new = $i == @$c || ref $c->[$i] eq 'JGraft::Missing';
            $c->[$i] = $v;
            $x->arrived($c, $i, $meta) if $new;
        }
    }
    $x->refresh if $ns eq 'node';
}

# Carry out the pending deletions and insertions of every array.
sub finish_move ($x) {
    for my $side (grep { $_->{pend} } values %{ $x->{side} }) {
        my ($a, $pend) = ($side->{a}, delete $side->{pend});
        my $m = $side->{split} ? $side->{split}{m} : [];
        my @entry = map { @$_ } @{ $pend->{ins}{-0.5} // [] };       # value, metadata, ...
        for my $i (0 .. $#$a) {
            push @entry, $a->[$i], $m->[$i] && [ $side->{split}{origin}, @{ $m->[$i] } ] unless $pend->{del}{$i};
            push @entry, map { @$_ } @{ $pend->{ins}{ $i + 0.5 } // [] };
        }
        @$a = @entry[ grep { $_ % 2 == 0 } 0 .. $#entry ];
        delete $side->{split};
        $x->set_meta($a, $_, $entry[ 2 * $_ + 1 ]) for 0 .. $#$a;
        $x->settle($a);
    }
}

#---------------------------------------------------------------------------
# SPLIT metadata: the separators and trimmings hidden by a SPLIT, kept
# beside the array as one [separator, ltrim, rtrim] per element together
# with the identity ("origin") of the SPLIT that made them.  A value read
# directly from such an element carries [origin, separator, ltrim, rtrim].

sub side ($x, $a)     { $x->{side}{ refaddr $a } //= { a => $a } }
sub split_of ($x, $a) { my $side = $x->{side}{ refaddr $a }; $side && $side->{split} }
sub pend ($x, $a)     { $x->side($a)->{pend} //= { del => {}, ins => {} } }

sub elem_meta ($x, $a, $i) {
    my $split = $x->split_of($a) or return undef;
    my $m     = $split->{m}[$i]  or return undef;
    return [ $split->{origin}, @$m ];
}

# Note what element $i of $a carries.  Only metadata of the array's own
# origin is kept; an array with none adopts the origin of the first arrival.
sub set_meta ($x, $a, $i, $meta) {
    my $split = $x->split_of($a)
        // ($meta ? ($x->side($a)->{split} = { origin => $meta->[0], m => [] }) : return);
    $split->{m}[$i] = $meta && $meta->[0] == $split->{origin} ? [ @$meta[ 1 .. 3 ] ] : undef;
}

# Element $i of $a has just come into existence.
sub arrived ($x, $a, $i, $meta = undef) {
    return unless $meta || $x->{side}{ refaddr $a };
    my @only = $x->split_of($a) ? ($i, $i) : ();        # metadata that begins here is new to every element
    $x->set_meta($a, $i, $meta);
    return $x->settle($a, @only) unless $x->{moving};
    delete $x->pend($a)->{del}{$i};         # and settle when the MOVE ends
}

# Elements without metadata take it from their neighbours: the separator and
# left trimming of the element before, or the separator of the first element
# that has one.  An empty array has no metadata at all.  Only elements
# $from .. $to are looked at (by default, all of them).
sub settle ($x, $a, $from = 0, $to = $#$a) {
    my $split = $x->split_of($a) or return;
    my $m     = $split->{m};
    $#$m = $#$a;
    return delete $x->{side}{ refaddr $a }{split} unless @$m;
    for my $i ($from .. $to) {
        next if $m->[$i];
        my $near = $i ? $m->[ $i - 1 ] : (grep { $_ } @$m)[0];
        $m->[$i] = [ $near && $near->[0], $i ? $near->[1] : undef, undef ];
    }
}

# Give a new array the metadata (one per element, or undef) of what it holds.
sub carry ($x, $new, $origin, @m) {
    return unless grep { $_ } @m;
    $x->side($new)->{split} = { origin => $origin, m => \@m };
    $x->settle($new);
}

# During a MOVE, elements awaiting deletion cannot be read.
sub check_live ($x, @element) {
    grep { ref eq 'JGraft::Missing' } @element and $x->fail_target('element is being moved');
}

1;
