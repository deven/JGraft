package JGraft::Ops::Action;

# Actions: the only operations that change anything.

use v5.36;
no warnings qw(experimental::builtin recursion);
use JGraft::Util;
use JGraft::Compiler qw(defop);
use JGraft::Ops::Split;

# ['JGRAFT', metadata, action...]: a scope for constants, common expressions
# and a fresh stash.
defop JGRAFT => -1, 'action', 'XX*', sub ($c, $ctx, $meta, @body) {
    ref $meta eq 'HASH' or return $c->fault('JGRAFT metadata must be an object');
    if (exists $meta->{v}) {
        is_int($meta->{v}) && $meta->{v} >= 1 or return $c->fault('JGRAFT version must be a positive integer');
        $meta->{v} <= $c->{max_version}
            or return $c->fault("JGraft version $meta->{v} is not supported", 'UNSUPPORTED_GRAFT');
    }
    my %declared;
    for my $which (qw(const expr)) {
        exists $meta->{$which} or next;
        my $list = $meta->{$which};
        ref $list eq 'ARRAY' && @$list % 2 == 0 or return $c->fault("JGRAFT $which must be a list of name/value pairs");
        for my $i (grep { $_ % 2 == 0 } 0 .. $#$list) {
            my $name = $list->[$i];
            is_str($name) || is_int($name) or return $c->fault("JGRAFT $which names must be strings");
            push @{ $declared{$which} }, [ "$name", $list->[ $i + 1 ] ];
        }
    }
    # Constants are evaluated on entry, each seeing the ones before it.
    my @const = map { [ $_->[0], $c->value($ctx, $_->[1])->{code} ] } @{ $declared{const} // [] };
    # Common expressions are kept as written and compiled where they are used.
    my $scope = $declared{expr}
        ? { exprs => { %{ $ctx->{scope}{exprs} }, map { @$_ } @{ $declared{expr} } }, cells => {} }
        : $ctx->{scope};
    my @action = map { $c->action({ scope => $scope }, $_) } @body;
    return sub ($x) {
        local $x->{const} = $x->{const};
        $x->{const} = { %{ $x->{const} }, $_->[0] => $_->[1]->($x->env) } for @const;
        local $x->{stash} = {};
        $_->($x) for @action;
    };
};

# ['RAISE', level, message, data?]
my %LEVEL = (info => 0, warn => 1, fail => 2);

defop RAISE => 0, 'action', 'XVV?', sub ($c, $ctx, $level, $message, $data = undef) {
    $level = $LEVEL{$level} if is_str($level);
    is_int($level) && $level >= 0 && $level <= 2 or return $c->fault('invalid RAISE level');
    my $printable = sub ($s) { is_str($s) && $s !~ /[\p{Cc}\p{Cs}\p{NChar}]/ };
    $message->{const} && !$printable->($message->{value}) and return $c->fault('invalid RAISE message');
    my ($text, $extra) = ($message->{code}, $data && $data->{code});
    return sub ($x) {
        my $record = { level => $level + 0, message => $text->($x->env) };
        $printable->($record->{message}) or $x->fail_target('RAISE message must be a printable string');
        $record->{data} = $x->outgoing($extra->($x->env)) if $extra;      # the log is outside the engine too
        push @{ $x->{logs} }, $record;
        $x->{opt}{on_raise}->($record) if $x->{opt}{on_raise};
        $x->fail(NO_MATCH => $record->{message}) if $level == 2;
    };
};

# ['AT', path, action...]: run actions with a descendant as the current node.
defop AT => 1, 'action', 'PA*', sub ($c, $ctx, $path, @action) {
    $path->{ns} eq 'node' or return $c->fault('AT can only navigate within the current node');
    my $keys = $path->{keys};
    return sub ($x) {
        my @k = $x->locate($x->{node}, $keys->($x->env));
        {
            local $x->{at} = [ @{ $x->{at} }, @k ];
            $x->refresh;
            $_->($x) for @action;
        }
        $x->refresh;
    };
};

# ['MATCH', spec, action...]: the node must match, or the graft fails.
defop MATCH => 3, 'action', 'XA*', sub ($c, $ctx, $spec, @action) {
    my $match = $c->root($ctx, $spec, 1)->{code};
    return sub ($x) {
        my $caps = $match->($x->env) or $x->fail(NO_MATCH => 'the data does not match');
        local $x->{cap} = $caps;
        $_->($x) for @action;
    };
};

# ['IF', spec, action, ..., else_action?]
defop IF => 4, 'action', 'X*', sub ($c, $ctx, @arg) {
    my $else = @arg % 2 ? $c->action($ctx, pop @arg) : undef;
    my @case;
    push @case, [ $c->root($ctx, shift @arg, 1)->{code}, $c->action($ctx, shift @arg) ] while @arg;
    return sub ($x) {
        for (@case) {
            my ($match, $action) = @$_;
            my $caps = $match->($x->env) or next;
            local $x->{cap} = $caps;
            return $action->($x);
        }
        $else->($x) if $else;
    };
};

# A path that is written to: the node, stash and temp namespaces, and of
# those only the node may be replaced whole.  Returns the path, or a fault.
sub target ($c, $path) {
    return $path if $path->{poison};
    my $ns = $path->{ns};
    return $c->fault("cannot write to the $ns namespace") unless $ns =~ /^(?:node|stash|temp)$/;
    return $path if $ns eq 'node';
    return $c->fault("the $ns namespace itself cannot be replaced") if $path->{fixed} && !@{ $path->{fixed} };
    my $keys = $path->{keys};
    return { %$path, keys => sub {
        my @k = &$keys or $_[0]->fail_operand("the $ns namespace itself cannot be replaced");
        @k;
    } };
}

# Code giving the SPLIT metadata that a value brings with it (see `reader`).
sub carried ($value) { $value->{meta} // sub { undef } }

# Is a value that goes from $from to $to one whose dates must be replaced?
# Only if it is leaving the engine (the document is outside it), and is the
# value of an expression that could give a date at all.
sub leaving ($from, $to) { $to->{ns} eq 'node' && $from->{dated} }

# ['COPY', value, path, ...]
defop COPY => 5, 'action', '(VP)+', sub ($c, $ctx, @arg) {
    my @pair;
    while (my ($value, $path) = splice @arg, 0, 2) {
        $path = target($c, $path);
        push @pair, [ $value->{code}, carried($value), leaving($value, $path), @$path{qw(ns keys)} ];
    }
    return sub ($x) {
        local $x->{temp} = $x->{temp};      # TEMP lasts for one action
        for (@pair) {
            my ($value, $carried, $leaving, $ns, $keys) = @$_;
            my $v    = $value->($x->env);
            my $meta = $carried->($x->env);
            $x->put($ns, [ $keys->($x->env) ], $leaving ? $x->outgoing($v) : $v, $meta);
        }
    };
};

# ['MOVE', from, to, ...]: null as source writes a null; as destination, discards.
defop MOVE => 6, 'action', '(XX)+', sub ($c, $ctx, @arg) {
    my @pair;
    while (my ($from, $to) = splice @arg, 0, 2) {
        my ($src, $dst) = map { defined $_->[0] ? target($c, $c->path($ctx, @$_)) : undef } [ $from, 0 ], [ $to, 1 ];
        # what moves into the document from another namespace may hold dates
        push @pair, [ $src, $dst, $src && $dst && $dst->{ns} eq 'node' && $src->{ns} ne 'node' ];
    }
    return sub ($x) {
        local $x->{temp} = $x->{temp};
        $x->{moving}++;
        my $ok = eval {
            for (@pair) {
                my ($src, $dst, $leaving) = @$_;
                my @from = $src ? $src->{keys}->($x->env) : ();
                my @to   = $dst ? $dst->{keys}->($x->env) : ();
                my ($v, $meta) = $src ? $x->take($src->{ns}, \@from) : ();
                next unless $dst;
                eval { $x->give($dst->{ns}, \@to, $leaving ? $x->outgoing($v) : $v, $meta); 1 } or do {
                    my $error = $@;
                    $x->give($src->{ns}, \@from, $v, $meta) if $src;    # a failed pair leaves no trace
                    die $error;
                };
            }
            1;
        };
        my $error = $@;
        $x->finish_move;
        $x->{moving}--;
        $x->refresh;
        die $error unless $ok;
        $x->fail_target('MOVE left the current node empty') if ref $x->{node} eq 'JGraft::Missing';
    };
};

# ['SPLICE', element_path, count, replacement...]
defop SPLICE => 7, 'action', 'PVV*', sub ($c, $ctx, $path, $count, @new) {
    $path = target($c, $path);
    my ($ns, $keys, $howmany) = (@$path{qw(ns keys)}, $count->{code});
    my @value   = map { $_->{code} } @new;
    my @carried = map { carried($_) } @new;
    my @leaving = map { leaving($_, $path) } @new;
    return sub ($x) {
        my @k = $keys->($x->env);
        my $n = $howmany->($x->env);
        !defined $n || is_int($n) or $x->fail_operand('SPLICE count must be an integer');
        my @v = map { $_->($x->env) } @value;
        my @m = map { $_->($x->env) } @carried;
        $leaving[$_] and $v[$_] = $x->outgoing($v[$_]) for 0 .. $#v;
        $x->splice_at($ns, \@k, $n, \@v, \@m);
    };
};

# ['ATSPLIT', path, split_spec, action...]: run actions on the pieces of a
# string, then put the string back together.
defop ATSPLIT => 2, 'action', 'PXA*', sub ($c, $ctx, $path, $spec, @action) {
    $path->{ns} eq 'node' or return $c->fault('ATSPLIT can only navigate within the current node');
    my $plan = JGraft::Ops::Split::spec($c, $ctx, $spec);
    return $plan if ref $plan eq 'HASH';
    my $keys = $path->{keys};
    return sub ($x) {
        my @k    = $x->locate($x->{node}, $keys->($x->env));
        my $text = $x->walk($x->{node}, @k);
        # the specification is evaluated once, with the string as current node
        my $p = $plan->($x, $text, @k ? ($k[-1], $x->walk($x->{node}, @k[ 0 .. $#k - 1 ])) : @$x{qw(nkey nparent)});
        is_str($text) or $x->fail_target('ATSPLIT needs a string');
        $p->{default}->() if ref $p->{sep} && !$p->{keep};      # evaluated now, used when joining
        my $joined;
        {
            local @$x{qw(root at)} = (JGraft::Ops::Split::split_string($x, $p, $text), []);
            $x->refresh;
            $_->($x) for @action;
            $joined = JGraft::Ops::Split::join_array($x, $p, $x->{root});
        }
        $x->put(node => \@k, $joined);
    };
};

1;
