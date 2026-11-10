package JGraft::Ops::Fn;

# Function expressions.  They receive compiled arguments and never copy data:
# a result may freely contain or be part of an argument.

use v5.36;
use builtin qw(created_as_number);
no warnings qw(experimental::builtin recursion);
use JGraft::Util;
use JGraft::Compiler qw(defop);

#---------------------------------------------------------------------------
# Control and scope

# [CAPTURE, spec]: the captures of a successful match, else false.
defop CAPTURE => 50, 'fn', 'X', sub ($c, $ctx, $spec) {
    my $match = $c->root($ctx, $spec, 1)->{code};
    return { code => sub { &$match // $FALSE } };
};

# [LOCAL, name, value, ..., result]: evaluate the result under extra TEMP
# bindings; the name null rebinds the current node instead.
defop LOCAL => 51, 'fn', 'X+', sub ($c, $ctx, @arg) {
    @arg % 2 or return $c->fault('LOCAL takes name/value pairs and a result');
    my $last = pop @arg;
    # Each pair is compiled with the names before it already supplied; the
    # compiler knows what a pair supplies when its name is a literal.
    my (@bind, @bound, $rebinds);
    while (my @pair = splice @arg, 0, 2) {
        my @so_far = @bound;
        my ($name, $value) = map { my $s = $_; $c->binding(\@so_far, sub { $c->value($ctx, $s) }) } @pair;
        push @bind, $name->{code}, $value->{code};
        next unless $name->{const};
        push @bound, defined $name->{value} ? "temp $name->{value}" : 'node';
        $rebinds ||= !defined $name->{value};
    }
    my $result = $c->binding(\@bound, sub { $c->value($rebinds ? { %$ctx, regex => 0 } : $ctx, $last) })->{code};
    return sub {
        my ($x, @env) = @_;
        local $x->{temp} = { %{ $x->{temp} } };
        for (my $i = 0; $i < @bind; $i += 2) {
            my $name  = $bind[$i]->($x, @env);
            my $value = $bind[ $i + 1 ]->($x, @env);
            if    (!defined $name)                              { @env = ($value, undef, undef) }
            elsif (is_str($name) || created_as_number($name))   { $x->{temp}{$name} = $value }
            else                                                { $x->fail_operand('LOCAL names must be strings or null') }
        }
        $result->($x, @env);
    };
}, dated => 1;      # the result is an expression of its own

# [CASE, spec, value, ..., else?]
defop CASE => 66, 'fn', '(TV)+V?', sub ($c, $ctx, @arg) {
    my $else = @arg % 2 ? pop(@arg)->{code} : undef;
    my @case;
    push @case, [ map { $_->{code} } splice @arg, 0, 2 ] while @arg;
    return sub {
        $_->[0]->(@_) and return $_->[1]->(@_) for @case;
        $else ? &$else : $_[0]->fail_target('no CASE applies', 1);
    };
};

defop FAIL => 67, 'fn', '', sub ($c, $ctx) {
    sub { $_[0]->fail_target('FAIL', 1) };
};

defop CURPROP => 56, 'fn', '', sub ($c, $ctx) {
    sub { $_[2] };
}, safe => 1, reads => 'node';

#---------------------------------------------------------------------------
# Logic: each operand must be a boolean; evaluation stops when decided.

for ([ NOT => 52, 1, 0 ], [ AND => 53, 0, 0 ], [ OR => 54, 1, 1 ]) {
    my ($op, $id, $stop, $yield) = @$_;     # stop at the first operand with this truth; then answer $yield
    defop $op, $id, 'fn', 'V+', sub ($c, $ctx, @arg) {
        my @get = map { $_->{code} } @arg;
        return sub {
            for my $get (@get) {
                my $v = &$get;
                type_of($v) == T_BOOL or $_[0]->fail_target("$op operands must be booleans");
                return $yield ? $TRUE : $FALSE if !$v == !$stop;
            }
            $yield ? $FALSE : $TRUE;
        };
    };
}

#---------------------------------------------------------------------------
# Arrays and strings

defop LENGTH => 55, 'fn', 'N?', sub ($c, $ctx, $of) {
    my $get = $of->{code};
    return sub {
        my $v = &$get;
        ref $v eq 'ARRAY' ? scalar @$v : is_str($v) ? length $v : $_[0]->fail_target('LENGTH needs an array or string');
    };
};

# The array an iterating function works on, with its elements counted.
my $elements = sub ($x, $v, $who) {
    ref $v eq 'ARRAY' or $x->fail_target("$who needs an array");
    $x->charge(scalar @$v, 16 + 8 * @$v);
    $x->check_live(@$v) if $x->{moving};
    return $v;
};

# Give $new the SPLIT metadata of the elements of $a at the indices @from.
my $inherit = sub ($x, $new, $a, @from) {
    my $split = $x->split_of($a) or return $new;
    $x->carry($new, $split->{origin}, @{ $split->{m} }[@from]);
    return $new;
};

# [FILTER, spec, array?]: the elements that match.
defop FILTER => 60, 'fn', 'XN?', sub ($c, $ctx, $spec, $of) {
    my $keep = $c->binding(['node'], sub { $c->root({ %$ctx, regex => 0 }, $spec) })->{code};
    my $get  = $of->{code};
    return sub {
        my $x    = $_[0];
        my $a    = $elements->($x, &$get, 'FILTER');
        my @kept = grep { $keep->($x, $a->[$_], $_, $a) } 0 .. $#$a;
        $inherit->($x, [ @$a[@kept] ], $a, @kept);
    };
};

# [MAP, value, array?]: the value computed with each element as current node.
defop MAP => 61, 'fn', 'XN?', sub ($c, $ctx, $each, $of) {
    my $f   = $c->binding(['node'], sub { $c->value({ %$ctx, regex => 0 }, $each) })->{code};
    my $get = $of->{code};
    return sub {
        my $x = $_[0];
        my $a = $elements->($x, &$get, 'MAP');
        $inherit->($x, [ map { $f->($x, $a->[$_], $_, $a) } 0 .. $#$a ], $a, 0 .. $#$a);
    };
}, dated => 1;      # the elements come from an expression of its own

# [CONCAT, a, b, ...]: all strings, or all arrays.
defop CONCAT => 58, 'fn', 'V+', sub ($c, $ctx, @arg) {
    my @get = map { $_->{code} } @arg;
    return sub {
        my $x = $_[0];
        my @v = map { $_->(@_) } @get;
        if (!grep { !is_str($_) } @v) {
            my $size = 0;
            $size += length for @v;
            $x->charge(scalar @v, 16 + $size);
            return join '', @v;
        }
        grep { ref ne 'ARRAY' } @v and $x->fail_target('CONCAT needs strings or arrays');
        my @all = map { @{ $elements->($x, $_, 'CONCAT') } } @v;
        # metadata survives from the first SPLIT represented, and from any others like it
        if (my ($origin) = map { $_->{origin} } grep { $_ } map { $x->split_of($_) } @v) {
            $x->carry(\@all, $origin, map {
                my $split = $x->split_of($_);
                $split && $split->{origin} == $origin ? @{ $split->{m} } : (undef) x @$_;
            } @v);
        }
        \@all;
    };
};

# [SLICE, value, offset, length?] or [SLICE, { ofs, len, lim, path }]
defop SLICE => 57, 'fn', 'VV?V?', sub ($c, $ctx, @arg) {
    return $c->fault('SLICE needs a value and offset, or an object')
        if @arg == 1 && $arg[0]{const} && ref $arg[0]{value} ne 'HASH';
    $c->reads('node') if @arg == 1;         # the object form slices the current node
    my @get = map { $_->{code} } @arg;
    return sub {
        my $x = $_[0];
        my ($v, $size, $ofs, $lim);
        my $measure = sub {
            $size = ref $v eq 'ARRAY' ? @$v : is_str($v) ? length $v : $x->fail_target('SLICE needs an array or string');
        };
        if (@get == 1) {        # the form of a capture: non-negative positions, any two of three
            my $o = $get[0]->(@_);
            ref $o eq 'HASH' && !grep { !/^(?:ofs|len|lim|path)$/ } keys %$o
                or $x->fail_operand('SLICE needs a value and offset, or an object');
            my %given = %$o;        # a copy: the object itself must not be touched
            is_int($_) && $_ >= 0 or $x->fail_operand('SLICE positions must be non-negative integers')
                for @given{ grep { exists $given{$_} } qw(ofs len lim) };
            my $path = exists $given{path} ? $given{path} : [];
            my $keys = ref $path eq 'ARRAY' ? JGraft::Compiler::path_keys('node', 0, @$path) : 'not a path';
            ref $keys or $x->fail_operand("SLICE path: $keys");
            my ($from, $count, $to) = @given{qw(ofs len lim)};
            !defined $from || !defined $count || !defined $to || $from + $count == $to
                or $x->fail_operand('SLICE positions disagree');
            $v = $x->escape($x->walk($_[1], @$keys));
            $measure->();
            $ofs = $from // (defined $count && defined $to ? $to - $count : 0);
            $lim = $to // (defined $count ? $ofs + $count : $size);
        }
        else {
            ($v, my $o, my $n) = map { $_->(@_) } @get;
            is_int($o) && (@get < 3 || is_int($n)) or $x->fail_operand('SLICE offset and length must be integers');
            $measure->();
            $ofs = $o < 0 ? $size + $o : $o;
            $lim = @get < 3 ? $size : $n < 0 ? $size + $n : $ofs + $n;
        }
        0 <= $ofs && $ofs <= $lim && $lim <= $size or $x->fail_target('SLICE out of range');
        $x->charge($lim - $ofs, 16 + (ref $v ? 8 : 1) * ($lim - $ofs));
        return substr $v, $ofs, $lim - $ofs unless ref $v;
        my @span = $ofs .. $lim - 1;
        $x->check_live(@$v[@span]) if $x->{moving};
        $inherit->($x, [ @$v[@span] ], $v, @span);
    };
};

#---------------------------------------------------------------------------
# Objects

# [PROPS, object?, form?]: names; or [name, value] pairs (1); or [names, values] (2).
defop PROPS => 64, 'fn', 'N?X?', sub ($c, $ctx, $of, @form) {
    my $form = @form ? $form[0] : 0;
    created_as_number($form) && grep { $form == $_ } 0 + @form .. 2
        or return $c->fault('PROPS option must be 1 or 2');
    my $get = $of->{code};
    return sub {
        my $o = &$get;
        ref $o eq 'HASH' or $_[0]->fail_target('PROPS needs an object');
        my @name = sort keys %$o;
        $_[0]->charge(scalar @name, 16 + 24 * @name);
        $form == 0 ? \@name : $form == 1 ? [ map { [ $_, $o->{$_} ] } @name ] : [ \@name, [ @$o{@name} ] ];
    };
};

# [MKOBJ, name, value, ...], [MKOBJ, names, values] or [MKOBJ, pairs]
defop MKOBJ => 65, 'fn', 'V*', sub ($c, $ctx, @arg) {
    my @get = map { $_->{code} } @arg;
    return sub {
        my $x = $_[0];
        my @v = map { $_->(@_) } @get;
        my $bad = sub { $x->fail_target('MKOBJ needs unique string names, each with a value') };
        @v == 1 || @v && @v % 2 == 0 or $bad->();
        my @pair = @v == 1 ? (map { ref eq 'ARRAY' && @$_ == 2 ? @$_ : $bad->() } ref $v[0] eq 'ARRAY' ? @{ $v[0] } : $bad->())
                 : @v == 2 && ref $v[0] eq 'ARRAY' && ref $v[1] eq 'ARRAY'
                 ? (@{ $v[0] } == @{ $v[1] } ? map { $v[0][$_], $v[1][$_] } 0 .. $#{ $v[0] } : $bad->())
                 : @v;
        $x->charge(scalar @pair);
        my (%object, $size);
        while (my ($name, $value) = splice @pair, 0, 2) {
            is_str($name) && !exists $object{$name} or $bad->();
            $object{$name} = $value;
            $size += 16 + length $name;
        }
        $x->charge(0, 16 + ($size // 0));
        $x->charge_obj(scalar keys %object);
        \%object;
    };
};

# [REDUCE, value, name, initial, array?]: fold, with TEMP name as accumulator.
defop REDUCE => 59, 'fn', 'XXVN?', sub ($c, $ctx, $each, $name, $initial, $of) {
    is_str($name) || created_as_number($name) or return $c->fault('REDUCE accumulator name must be a string');
    my $f = $c->binding([ 'node', "temp $name" ], sub { $c->value({ %$ctx, regex => 0 }, $each) })->{code};
    my ($first, $get) = ($initial->{code}, $of->{code});
    return sub {
        my $x   = $_[0];
        my $acc = &$first;
        my $a   = $elements->($x, &$get, 'REDUCE');
        local $x->{temp} = { %{ $x->{temp} } };
        for my $i (0 .. $#$a) {
            $x->{temp}{$name} = $acc;
            $acc = $f->($x, $a->[$i], $i, $a);
        }
        $acc;
    };
}, dated => 1;      # the result comes from an expression of its own

1;
