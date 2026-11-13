package JGraft::Exec;

# The state of one run, and the only code that changes a data tree.
#
# Trees are immutable: a container reachable from a namespace is modified in
# place only if this run created it (by cloning one, or on the way to a path
# that did not exist) and nothing else can refer to it ("owned").  Everything
# else is path-copied on write, so the input is never touched, COPY can share
# structure, and RAISE data is a snapshot.

use v5.36;
use builtin qw(refaddr);
no warnings qw(experimental::builtin recursion);
use JGraft::Util;
use JGraft::Error;
use JGraft::Ordered;
use JGraft::Source;

use constant INF => 9**9**9;

# A copy of a value that is the graft's own, for the run to have.
sub taken ($x, $v) {
    return $v unless ref $v eq 'ARRAY' || ref $v eq 'HASH';
    my ($n, $bytes, $tree) = JGraft::Compiler::weigh($v);
    $x->charge($n, $bytes);
    return JGraft::Compiler::thawed($v, $tree ? undef : {});
}

# A copy of a value that shares nothing with anything: not with the input,
# nor the graft, nor one part of itself with another.  Every array and object
# in it is its own, to be changed as the caller likes.  It is as large as the
# value written out would be, which for a value that holds one thing in many
# places is larger than the value; that is counted.
sub apart ($x, $v) {
    my $kind = ref $v;
    return $v unless $kind eq 'ARRAY' || $kind eq 'HASH';
    $x->charge(1, sizeof($v));
    my $copy = $kind eq 'ARRAY' ? [ map { ref $_ ? $x->apart($_) : $_ } @$v ] : do {
        my $object = JGraft::Ordered::is($v) ? JGraft::Ordered::hash() : {};
        $object->{$_} = ref $v->{$_} ? $x->apart($v->{$_}) : $v->{$_} for keys %$v;
        $object;
    };
    JGraft::Source::cloned($v, $copy) if $x->{src};     # (where its values came from in a text is still known)
    return $copy;
}

# Was the text that this sheet (of JGraft::Source) leads back to read with its numbers exact?
sub exact_text ($sheet) { my $record = $sheet && ($sheet->{rec} // $sheet->{from}); $record && $record->{exact} }

sub new ($class, $input, %opt) {
    my $limit = $opt{limits} // {};
    return bless {
        root => $input, at => [],                       # node namespace and the path to the current node
        node => $input, nkey => undef, nparent => undef, # the current node, cached for actions
        const => {}, stash => {}, temp => $opt{temp} // {}, cap => {},
        held => {},                                      # the constants whose values are the graft's own, not copies
        share => $opt{share} ? 1 : 0,                    # is the run handed the graft's own arrays and objects, not copies?
        caps => {}, path => [], capturing => 0,          # capture pass
        (map { $_ => $limit->{$_} // INF } qw(ops mem new_obj prop_per_obj)),
        depth => 0, max_depth => $limit->{depth} // 512,
        owned => {}, side => {}, moving => 0,
        origin => {},                                    # for each copy the run has made of an array or object: [ the copy, what it is a copy of ]
        dates => $opt{dates} // \0,     # whether the graft is one that makes dates
        quiet => 0, logs => [], opt => \%opt,
        site => {},                     # the action that is running: { where, action }, as in an error
        piece => undef,                 # inside ATSPLIT: code that says where a piece is (see `locus`)
        # Is the document one that JGraft::JSON read?  Then where each value came from in its
        # text is kept up as values move (see JGraft::Source), and new objects keep their order.
        src => ref $input && JGraft::Source::sheet($input) ? 1 : 0,
        # Is arithmetic to be exact (see JGraft::Number)?  As asked; or as the document was read.
        exact => $opt{exact} // (ref $input && exact_text(JGraft::Source::sheet($input)) ? 1 : 0),
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
    $x->charge($array ? scalar @$v : scalar keys %$v);
    for my $k ($array ? 0 .. $#$v : keys %$v) {
        my $old = $array ? $v->[$k] : $v->{$k};
        ref $old or next;
        my $new = $x->export($old);
        next if ref $new && refaddr($new) == refaddr($old);
        if (!$copy) {
            $copy = $array ? [@$v] : JGraft::Ordered::copy($v);
            JGraft::Source::cloned($v, $copy) if $x->{src};
        }
        $array ? ($copy->[$k] = $new) : ($copy->{$k} = $new);
    }
    return $copy // $v;
}

#---------------------------------------------------------------------------
# Errors and limits

my %PROBE = map { $_ => JGraft::Error->new(code => $_, message => 'failed probe', soft => 1) }
    qw(INVALID_TARGET INVALID_OPERAND);

sub fail ($x, $code, $message) {
    die JGraft::Error->new(code => $code, message => $message, $x->context);
}

# What an error says of the run: the action that is running, and where the
# current node is.  (When a constant is being evaluated there is no node.)
sub context ($x) { (%{ $x->{site} }, $x->{folding} ? () : (node => $x->locus)) }

# Where the current node is in the document, in the form of a capture:
# { path }, with { ofs, len, lim } as well if it is a piece of the string at
# that path, which is what the nodes inside an ATSPLIT are.
sub locus ($x) {
    my $piece = $x->{piece};
    return $piece ? $piece->($x->{root}, @{ $x->{at} }) : { path => [ @{ $x->{at} } ] };
}

# Run $code only to look at what a failure has left, or to put it straight:
# no limit applies, and if it fails in its turn it just returns nothing.
sub aside ($x, $code) {
    local @$x{qw(quiet ops mem new_obj prop_per_obj)} = (1, (INF) x 4);
    my @found;
    return eval { @found = $code->(); 1 } ? @found : ();
}

# The two recoverable errors.  Under a match they are routine, so they cost
# nothing to raise there.  A failure is `meant` if the graft asks for it.
sub fail_target ($x, $message, $meant = 0) {
    die $x->{quiet} ? $PROBE{INVALID_TARGET} : JGraft::Error->new(
        code => 'INVALID_TARGET', message => $message, $x->context, soft => 1, meant => $meant);
}

sub fail_operand ($x, $message) {
    die $x->{quiet} ? $PROBE{INVALID_OPERAND}
        : JGraft::Error->new(code => 'INVALID_OPERAND', message => $message, $x->context, soft => 1);
}

sub limit ($x, $which) { $x->fail(RESOURCE_LIMIT => "$which limit exceeded") }

# Account for work proportional to data: $ops steps producing $mem bytes.
sub charge ($x, $ops, $mem = 0) {
    ($x->{ops} -= $ops) >= 0 or $x->limit('ops');
    ($x->{mem} -= $mem) >= 0 or $x->limit('mem') if $mem;
}

# Account for an array or object that the run creates as a value: an object
# with $props properties.  (The engine's own copies of what exists already,
# made in order to change it, are not new values.)
sub charge_obj ($x, $props = 0) {
    --$x->{new_obj} >= 0         or $x->limit('new_obj');
    $props <= $x->{prop_per_obj} or $x->limit('prop_per_obj');
}

# Account for the property $name, about to be set in $object.
sub charge_prop ($x, $object, $name) {
    exists $object->{$name} || scalar(%$object) < $x->{prop_per_obj} or $x->limit('prop_per_obj');
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
        if (!is_idx($k) && exists $v->{$k}) {
            my $e = $v->{$k};
            return $e unless ref $e eq 'JGraft::Missing';       # the current node, moved away and not yet replaced
        }
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
    my $new   = $hash ? JGraft::Ordered::copy($c) : [@$c];
    JGraft::Source::cloned($c, $new) if $x->{src};
    my $owned = $x->{owned};
    delete @$owned{ map { refaddr $_ } grep { ref } $hash ? values %$c : @$c } if %$owned;
    $owned->{ refaddr $new } = $new;        # holding it keeps the address from being reused
    # What it is a copy of, at first hand or by way of other copies: by which an undo
    # can tell a thing that was moved and then changed from one that is new.
    my $first = $x->{origin}{ refaddr $c };
    $x->{origin}{ refaddr $new } = [ $new, $first && $first->[0] == $c ? $first->[1] : $c ];
    if (my $side = $x->{side}{ refaddr $c }) {
        my $copy = $x->side($new);
        $copy->{split} = { %{ $side->{split} }, m => [ @{ $side->{split}{m} } ] } if $side->{split};
        $copy->{pend}  = delete $side->{pend} if $side->{pend};
    }
    $x->charge(scalar($hash ? %$new : @$new), sizeof($new));
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
    if (ref $$slot eq 'JGraft::Missing') {      # the document itself, moved away: it is made anew, as anything else would be
        $$slot = is_idx($keys->[0]) ? [] : $x->object;
        $x->{owned}{ refaddr $$slot } = $$slot;
        $x->charge_obj;
    }
    my $c = $$slot = $x->own($$slot, $keys->[0]);
    for my $i (0 .. $n - 1) {
        my $array = ref $c eq 'ARRAY';
        my $k     = $array ? $x->index_for($c, $keys->[$i], 1) : $keys->[$i];
        my $child = $array ? ($k < @$c ? $c->[$k] : $MISSING) : exists $c->{$k} ? $c->{$k} : $MISSING;
        if (ref $child eq 'JGraft::Missing') {      # absent, or an element whose removal is pending
            $child = is_idx($keys->[ $i + 1 ]) ? [] : $x->object;
            $x->{owned}{ refaddr $child } = $child;
            $x->charge_obj;
            $x->charge_prop($c, $k) unless $array;
            $array ? ($c->[$k] = $child) : ($c->{$k} = $child);
            JGraft::Source::set($c, $k) if $x->{src};
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

# A new, empty object: one that keeps its properties in order, if the
# document's own objects do.
sub object ($x) { $x->{src} ? JGraft::Ordered::hash() : {} }

# The root slot and full key list for a path in namespace $ns.
sub slot ($x, $ns, $keys) {
    return $ns eq 'node' ? (\$x->{root}, [ @{ $x->{at} }, @$keys ]) : (\$x->{$ns}, $keys);
}

# Assign $v at a path (COPY).  $meta is what $v carries from a SPLIT array,
# and $tok where it came from in a text.
sub put ($x, $ns, $keys, $v, $meta = undef, $tok = undef) {
    my ($slot, $k) = $x->slot($ns, $keys);
    if (!@$k) {
        $$slot = $v;                # the root of the node namespace
    }
    else {
        my $c = $x->own_path($slot, $k, $#$k);
        if (ref $c eq 'HASH') {
            $x->charge_prop($c, $k->[-1]);
            $c->{ $k->[-1] } = $v;
            JGraft::Source::set($c, $k->[-1], $tok) if $x->{src};
        }
        else {
            my $i      = $x->index_for($c, $k->[-1], 1);
            my $append = $i == @$c;
            $c->[$i] = $v;
            JGraft::Source::set($c, $i, $tok) if $x->{src};
            $x->arrived($c, $i, $meta) if $append;
        }
    }
    $x->refresh if $ns eq 'node';
}

# Replace $count elements at the array element a path names (SPLICE).
sub splice_at ($x, $ns, $keys, $count, $new, $metas, $toks = []) {
    my ($slot, $k) = $x->slot($ns, $keys);
    # (an element at or below the current node: not the node itself, though it be one in its parent)
    @$keys && is_idx($keys->[-1]) or $x->fail_target('SPLICE needs an element of an array');
    $x->walk($$slot, @$k[ 0 .. $#$k - 1 ]);        # no containers are created on the way
    my $c    = $x->own_path($slot, $k, $#$k);
    my $i    = $x->index_for($c, $k->[-1], 1);
    my $rest = @$c - $i;
    my $n    = !defined $count ? $rest : $count < 0 ? $rest + $count : $count;
    $n >= 0 && $n <= $rest or $x->fail_target('SPLICE count out of range');
    $x->charge(scalar @$new, 8 * @$new);
    my $old = @$c;
    JGraft::Source::spliced($c, $old, $i, $n, map { $toks->[$_] } 0 .. $#$new) if $x->{src};
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

# Detach and return the value at a path, with any SPLIT metadata it carries
# and where it came from in a text.
sub take ($x, $ns, $keys) {
    my ($slot, $k) = $x->slot($ns, $keys);
    my @k = $x->locate($$slot, @$k);                # it must exist
    my ($v, $meta, $tok);
    if (!@k) {
        ref $$slot eq 'JGraft::Missing' and $x->fail_target('path does not exist');     # moved away already
        ($v, $$slot) = ($$slot, $MISSING);
    }
    else {
        my $c = $x->own_path($slot, \@k, $#k);
        my $i = $k[-1];
        $tok = JGraft::Source::token($c, $i) if $x->{src};
        if (ref $c eq 'HASH') {
            # where it was among the properties, in case it is only being renamed (see `give`)
            $x->{vacated} = [ refaddr $c, JGraft::Ordered::place($c, $i) ] if @$keys && JGraft::Ordered::is($c);
            # the current node keeps its place, to be filled before the action ends
            $v = @$keys ? delete $c->{$i} : $c->{$i};
            $c->{$i} = $MISSING unless @$keys;
            JGraft::Source::unset($c, $i) if $x->{src} && @$keys;
        }
        else {
            ($v, $meta) = ($c->[$i], $x->elem_meta($c, $i));
            $c->[$i] = $MISSING;
            $x->set_meta($c, $i, undef);
            $x->pend($c)->{del}{$i} = 1 if @$keys;
        }
    }
    $x->refresh if $ns eq 'node';
    return ($v, $meta, $tok);
}

# Attach a value at a path.
sub give ($x, $ns, $keys, $v, $meta, $tok = undef) {
    my ($slot, $k) = $x->slot($ns, $keys);
    if (!@$k) {
        $$slot = $v;
    }
    else {
        my $c = $x->own_path($slot, $k, $#$k);
        my $i = $k->[-1];
        if (ref $c eq 'HASH') {
            $x->charge_prop($c, $i);
            my $renamed = !exists $c->{$i} && $x->{vacated} && $x->{vacated}[0] == refaddr $c;
            $c->{$i} = $v;
            # a property taken from this object by the same pair has only changed its name: it stays where it was
            JGraft::Ordered::place($c, $i, $x->{vacated}[1]) if $renamed;
            JGraft::Source::set($c, $i, $tok) if $x->{src};
        }
        elsif (defined $i && $i != int $i) {        # a half index: insert between elements, later
            $i += @$c if $i < -0.5;
            $i >= -0.5 && $i < @$c or $x->fail_target('array index out of range');
            push @{ $x->pend($c)->{ins}{$i} }, [ $v, $meta, $tok ];
        }
        else {
            $i = $x->index_for($c, $i, 1);
            my $new = $i == @$c || ref $c->[$i] eq 'JGraft::Missing';
            $c->[$i] = $v;
            JGraft::Source::set($c, $i, $tok) if $x->{src};
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
        my $t = $x->{src} && JGraft::Source::tokens($a) || [];
        my @entry = @{ $pend->{ins}{-0.5} // [] };                  # each [ value, metadata, token ]
        for my $i (0 .. $#$a) {
            push @entry, [ $a->[$i], $m->[$i] && [ $side->{split}{origin}, @{ $m->[$i] } ], $t->[$i] ] unless $pend->{del}{$i};
            push @entry, @{ $pend->{ins}{ $i + 0.5 } // [] };
        }
        @$a = map { $_->[0] } @entry;
        JGraft::Source::rebuilt($a, map { $_->[2] } @entry) if $x->{src};
        # An array that came of a SPLIT keeps to it: what arrives from another is not let in.
        $side->{split} = $side->{split} ? { origin => $side->{split}{origin}, m => [] } : undef;
        delete $side->{split} unless $side->{split};
        $x->set_meta($a, $_, $entry[$_][1]) for 0 .. $#$a;
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
