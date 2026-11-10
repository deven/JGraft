package JGraft::Compiler;

# Turns a graft into closures, once.  Everything that can be decided from the
# graft alone is decided here: which operation an array names, how many
# arguments it has, what context each argument is in, what type a literal is.
#
# Closure conventions:
#
#   value, match    $code->($x, $node, $key, $parent)   a value / true or false
#   sequence        $code->($x, $subject, $pos, $len)   list of successor positions
#   action          $code->($x)
#
# $x is the JGraft::Exec.  The current node is an argument, so descending into
# the data is a call with different arguments and nothing needs restoring.
#
# Compile functions return a "node": the code, and what is known about it.
#   const, value   the value is known now
#   lit            (match) it compares the node with this constant
#   throws         it may raise a recoverable error
#   dated          (value) the value may be a date, or hold one
#   seq            the code is a sequence closure ...
#   one, zero      ... that consumes exactly one element / none
#   caps, resolve  it may record captures; code that extracts them (sequences)
#   pref           'max' or 'min': a length preference (SEQMAX / SEQMIN)
#   ns, keys, fixed, meta   a path (see `path` and `reader`)
#   poison         it is a fault, and raises it when reached
#
# The context is a hash: scope (lexical JGRAFT scope), exact (IS rather than
# HAS), regex (matching characters of a string), cap (captures observable),
# seq (inside a sequence), top (directly an item of an array pattern), and
# v (value context, where only scope and regex mean anything).
#
# A scope is { exprs, cells, known }: the common expressions as written, the
# compiled copies of them, and the values of constants that are known now.

use v5.36;
use builtin qw(created_as_number is_bool);
no warnings qw(experimental::builtin recursion);
use JGraft::Util;
use JGraft::Error;
use JGraft::Exec;
use JGraft::Seq;
use Exporter 'import';

our @EXPORT_OK = qw(defop node trap row %EXPR);

our (%EXPR, %ACTION);    # operation tables, keyed by both name and ID

# Declare an operation.  $args describes its arguments, one letter each:
#   V value   N value which, if omitted, is the current node
#   T test (a separate match, yielding true/false)   P path   A action
#   X raw structure, for the builder to compile itself
# with ? * + and (..) meaning what they do in a regex.  The builder receives
# the compiler, the context and the compiled arguments, and returns a node or
# just its code.  Flags: `safe` (cannot raise a recoverable error of its own),
# `seq` (the builder handles sequence context itself), `dated` (the result may
# hold a date that did not come from a V or N argument), `reads` (something it
# reads besides its arguments: see below), `blind` (a match expression that
# does not itself look at the current node).
sub defop ($name, $id, $kind, $args, $build, %flag) {
    my $table = $kind eq 'action' ? \%ACTION : \%EXPR;
    $table->{$name} = $table->{$id} = { name => $name, kind => $kind, args => $args, build => $build, %flag };
}

# A node for a value that is known now.  Every evaluation, in every run, is
# handed the same value, so it must never change.
sub konst ($v) {
    my $dated = freeze($v);
    return { const => 1, value => $v, dated => $dated, code => sub { $v } };
}

# Protect a constant from change as far as Perl allows, and report whether
# there is a date in it.  Arrays, their elements and the values of objects
# become read-only.  An object cannot be kept from gaining or losing
# properties without also making it an error to read one it lacks, so that
# is left to the caller.
sub freeze ($v) {
    my $r = ref $v;
    return $r eq 'JGraft::Date' unless $r eq 'ARRAY' || $r eq 'HASH';
    Internals::SvREADONLY(@$v, 1) if $r eq 'ARRAY';
    my $dated = 0;
    for ($r eq 'ARRAY' ? @$v : values %$v) {
        $dated = 1 if freeze($_);
        Internals::SvREADONLY($_, 1);
    }
    return $dated;
}

# A node for $code whose flags are inherited from the nodes it calls.
sub node ($code, @kids) {
    return { code => $code, map { my $f = $_; ($f => !!grep { $_->{$f} } @kids) } qw(throws caps dated) };
}

# The table row an array names, if it is an operation.
sub row ($table, $s) {
    return undef unless ref $s eq 'ARRAY' && @$s;
    my $op = $s->[0];
    return undef if ref $op || !defined $op;
    my $row = $table->{$op} or return undef;
    return (created_as_number($op) xor $op eq $row->{name}) ? $row : undef;
}

sub new ($class, %opt) {
    return bless { max_version => 1, %opt, faults => [], warnings => [], dates => 0,
        site   => {},       # the action being compiled: { where, action }, as in an error
        limits => { %{ $opt{limits} // {} } } }, $class;
}

sub compile ($class, $struct, %opt) {
    my $c    = $class->new(%opt);
    my $root = row(\%ACTION, $struct);
    my $code = $root && $root->{name} eq 'JGRAFT'
        ? $c->action({ scope => { exprs => {}, cells => {}, known => {} } }, $struct)
        : $c->fault('a graft must be a JGRAFT action')->{code};
    # `dates` is by reference: parts of a graft are compiled when first used
    return ($code, $c->{faults}, \$c->{dates}, $c->{warnings});
}

# Record a defect in the graft.  The node returned raises it when reached.
sub fault ($c, $message, $code = 'INVALID_GRAFT', %more) {
    my $error = JGraft::Error->new(code => $code, message => $message, %{ $c->{site} }, %more);
    push @{ $c->{faults} }, $error;
    my $die = sub { die $error };
    return { code => $die, keys => $die, ns => 'node', poison => 1 };
}

#---------------------------------------------------------------------------
# Arguments

# The argument letters for $n arguments under spec $spec, or undef.  An
# omitted N appears as `n`, so arguments keep their positions.
sub fit ($spec, $n) {
    state %memo;
    return $memo{"$spec $n"} //= do {
        my @token = map {
            my ($unit, $count) = /(\w+)\)?([?*+]?)$/;
            [ $unit, $count =~ /[?*]/ ? 0 : 1, $count =~ /[*+]/ ? $n : 1 ];
        } $spec =~ /\(\w+\)[?*+]?|\w[?*+]?/g;
        _fit(\@token, 0, $n);
    };
}

sub _fit ($token, $i, $n) {
    return $n ? undef : '' if $i == @$token;
    my ($unit, $min, $max) = @{ $token->[$i] };
    for (my $k = int($n / length $unit); $k >= $min; $k--) {
        next if $k > $max;
        my $rest = _fit($token, $i + 1, $n - $k * length $unit);
        return ($k || $unit ne 'N' ? $unit x $k : 'n') . $rest if defined $rest;
    }
    return undef;
}

sub build ($c, $ctx, $row, $s) {
    my $kinds = fit($row->{args}, $#$s)
        // return $c->fault("wrong number of arguments to $row->{name}");
    $c->reads('node') if $kinds =~ /n/ || $row->{kind} eq 'match' && !$row->{blind};
    $c->reads($row->{reads}) if $row->{reads};
    my (@arg, @kid);
    my $i = 0;                                  # index in $s of the argument being compiled
    for my $k (split //, $kinds) {
        my $raw = $k eq 'n' ? undef : $s->[ ++$i ];
        push @arg, $k eq 'n'    ? $c->cur
                 : $k =~ /[VN]/ ? $c->value($ctx, $raw)
                 : $k eq 'T'    ? $c->root($ctx, $raw)
                 : $k eq 'P'    ? $c->path($ctx, $raw)
                 : $k eq 'A'    ? $c->action($ctx, $raw, $i)
                 :                $raw;
        push @kid, $arg[-1] if $k =~ /[VNnTP]/;
    }
    my $n = $row->{build}->($c, $ctx, @arg);
    return $n unless ref $n eq 'CODE';      # a builder that returns a whole node sets its own flags
    return {
        code   => $n,
        throws => !$row->{safe} || !!(grep { $_->{throws} } @kid),
        dated  => $row->{dated} || !!(grep { $_->{dated} } @kid),
    };
}

#---------------------------------------------------------------------------
# Constant folding
#
# While an expression is compiled, note is taken of what it will read when it
# runs: `node` (the current node), `temp NAME` (a property of TEMP), or `*`
# (anything that cannot be known until the graft runs).  An operation that
# supplies one of these to an expression inside it compiles that expression
# with `binding`, and the name goes no further: [MAP, f, array] supplies the
# node that f reads.  An expression left reading nothing is a constant,
# however it is built, and `value` evaluates it there and then.
#
# That evaluation is work done by `new`, so it is the `limits` given to `new`
# that govern it: one allowance for the whole graft.

sub reads ($c, @names) {
    my $noted = $c->{reads} or return;
    @$noted{@names} = ();
}

# Compile something, returning it along with the names it read (as the keys
# of a hash), other than those in @bound.
sub reading ($c, $compile, @bound) {
    my %read;
    my $n = do { local $c->{reads} = \%read; $compile->() };
    delete @read{@bound};
    $c->reads(keys %read);
    return ($n, \%read);
}

sub binding ($c, $bound, $compile) { ($c->reading($compile, @$bound))[0] }

# Evaluate now the expression $s, compiled as $n, which reads nothing.  What
# comes of it now would come of it in every run, so this returns a node to
# stand for $n:
#
#   a value            a constant.
#   INVALID_OPERAND    a fault.  The expression was given something it could
#                      never accept, which makes the graft wrong, wherever
#                      the expression is and whether or not a run reaches it.
#   INVALID_TARGET     a node that raises it again.  This is no fault: it may
#                      be what the graft is for, or be one alternative in a
#                      match.  But unless it was asked for, as by [FAIL], it
#                      is worth a warning.
#
# $n itself is returned if evaluating it would exceed what the limits still
# allow, leaving that to a run; and for a SPLIT, whose result is more than
# its value.
sub fold ($c, $ctx, $s, $n) {
    my $x = JGraft::Exec->new(undef, limits => $c->{limits});
    @$x{qw(folding const site)} = (1, $ctx->{scope}{known} // {}, $c->{site});
    my $v;
    my $done  = eval { $v = $n->{code}->($x, $MISSING, undef, undef); 1 };
    my $error = $@;
    $c->{limits}{$_} = $x->{$_} for qw(ops mem new_obj);        # what is left, for the rest of the graft
    return %{ $x->{side} } ? $n : konst($v) if $done;
    return $n unless ref $error eq 'JGraft::Error' && $error->{soft};
    return $c->fault("an expression always fails: $error->{message}", 'INVALID_GRAFT', expr => $s)
        if $error->code eq 'INVALID_OPERAND';
    # An expression around this one will be evaluated in its turn, and may
    # fail only because this one does.  So that this can be told, it is the
    # very same error that is raised then; and it is the innermost expression
    # that is reported.
    if (!$error->{expr}) {
        $error->{expr} = $s;
        push @{ $c->{warnings} }, $error unless $error->{meant};
    }
    my ($message, $meant) = @$error{qw(message meant)};
    return { %$n, code => sub { die $error if $_[0]{folding}; $_[0]->fail_target($message, $meant) } };
}

# Compile the action $s: the whole graft, or element $i of the action being
# compiled.  Where it is in the graft is kept, as a JSON Pointer, for errors
# to report: those found now, and those of a run while the action runs.
sub action ($c, $ctx, $s, $i = undef) {
    my $row = row(\%ACTION, $s);
    local $c->{site} = { where => defined $i ? "$c->{site}{where}/$i" : '', action => $row && $row->{name} };
    $row or return $c->fault('unknown action')->{code};
    my ($site, $code) = ($c->{site}, $c->build($ctx, $row, $s)->{code});
    return sub { local $_[0]{site} = $site; &$code };
}

#---------------------------------------------------------------------------
# Value context

sub value ($c, $ctx, $s) {
    return konst($s) if ref $s ne 'ARRAY' && ref $s ne 'HASH';
    $ctx = { scope => $ctx->{scope}, regex => $ctx->{regex}, v => 1 } unless $ctx->{v};
    my ($n, $read) = $c->reading(sub { $c->_value($ctx, $s) });
    return $n->{const} || $n->{poison} || %$read ? $n : $c->fold($ctx, $s, $n);
}

sub _value ($c, $ctx, $s) {
    my $r = ref $s;
    return $c->construct($ctx, $s) if $r eq 'HASH' || @$s == 1 && ref $s->[0] eq 'ARRAY';
    my $row = row(\%EXPR, $s)
        or return $c->fault(@$s ? 'unknown expression' : 'an empty array is not an expression');
    return $c->reader($ctx, $s)      if $row->{path};
    return $c->build($ctx, $row, $s) if $row->{kind} ne 'match';
    my $test = $c->root($ctx, $s)->{code};      # a match expression used as a function
    return { code => sub { &$test ? $TRUE : $FALSE } };
}

# An object, or an escaped array, whose members are themselves value context.
sub construct ($c, $ctx, $s) {
    my $hash = ref $s eq 'HASH';
    my @key  = $hash ? keys %$s : ();
    my @kid  = map { $c->value($ctx, $_) } $hash ? @$s{@key} : @{ $s->[0] };
    my $make = $hash ? sub { my %h; @h{@key} = @_; \%h } : sub { [@_] };
    return konst($make->(map { $_->{value} } @kid)) unless grep { !$_->{const} } @kid;
    my @code = map { $_->{code} } @kid;
    my @meta = $hash ? () : map { $_->{meta} } @kid;
    return node(sub {
        my $x = $_[0];
        $x->charge_obj($hash ? scalar @code : 0);
        my $new = $make->(map { $_->(@_) } @code);
        if (%{ $x->{side} }) {      # elements referred to directly keep their SPLIT metadata
            $meta[$_] and $x->set_meta($new, $_, $meta[$_]->(@_)) for 0 .. $#meta;
            $x->settle($new);
        }
        $new;
    }, @kid);
}

# The current node as a value: what an omitted N argument becomes.
sub cur ($c) {
    state $cur = { throws => 1, code => sub { $_[0]->escape($_[1]) } };
    return $cur;
}

#---------------------------------------------------------------------------
# Paths

my %NS = (NODE => 'node', CONST => 'const', STASH => 'stash', TEMP => 'temp', CAP => 'cap');

# Path context: { ns, keys }, where keys->(env) yields the validated keys.
# `fixed` is the keys themselves if all are literal, and `head` the first of
# them if that one is.  $half permits a final half-index (MOVE destinations).
sub path ($c, $ctx, $s, $half = 0) {
    $s = [ NODE => $s ] unless ref $s eq 'ARRAY' || ref $s eq 'HASH';
    my $row = row(\%EXPR, $s);
    my $ns  = $row && $NS{ $row->{name} } or return $c->fault('not a path');
    my @kid = map { $c->value($ctx, $_) } @$s[ 1 .. $#$s ];
    if (!grep { !$_->{const} } @kid) {      # all literal: checked now
        my $k = path_keys($ns, $half, map { $_->{value} } @kid);
        return ref $k ? { ns => $ns, keys => sub { @$k }, fixed => $k, head => $k->[0], throws => 1 } : $c->fault($k);
    }
    my @code = map { $_->{code} } @kid;
    my $first = $kid[0]{const} ? $kid[0]{value} : undef;
    my $head  = is_str($first) || created_as_number($first) ? "$first" : undef;
    return { ns => $ns, head => $head, throws => 1, keys => sub {
        my $k = path_keys($ns, $half, map { $_->(@_) } @code);
        ref $k ? @$k : $_[0]->fail_operand($k);
    } };
}

# Flatten and validate the evaluated elements of a path.  Returns the keys,
# or a string saying what is wrong with them.
sub path_keys ($ns, $half, @element) {
    my @k = map { ref eq 'ARRAY' ? @$_ : $_ } @element;
    for my $i (0 .. $#k) {
        my $t = type_of($k[$i]);
        if    ($t == T_STR) { }
        elsif ($t == T_NUM) {
            is_int($k[$i]) || $half && $i == $#k && is_int($k[$i] * 2) or return 'fractional array index';
        }
        elsif ($t == T_BOOL && !$k[$i]) { $k[$i] = undef }      # false: the append position
        else                            { return 'invalid path element' }
    }
    return 'the TEMP namespace has no accessible root' if !@k && $ns eq 'temp';
    $k[0] = "$k[0]" if $ns ne 'node' && @k && created_as_number($k[0]);    # root properties may be written as integers
    return \@k;
}

# A reference expression read as a value.
sub reader ($c, $ctx, $s) {
    my $p = $c->path($ctx, $s);
    my ($ns, $keys) = @$p{qw(ns keys)};
    # What it reads can be named if the path begins with a literal; and a
    # constant whose value is already known is not read from the run at all.
    my $first = $p->{head};
    $c->reads($ns eq 'node' ? 'node'
            : !defined $first ? '*'
            : $ns eq 'temp' ? "temp $first"
            : $ns eq 'const' && exists $ctx->{scope}{known}{$first} ? ()
            : '*');
    return {
        %$p,
        dated => $ns eq 'stash' || $ns eq 'temp' || $ns eq 'const',     # where a date can be kept
        code  => $ns eq 'node'
            ? sub { my ($x, $v) = @_; $v = $x->step($v, $_) for &$keys; $x->escape($v) }
            : sub { my $x = $_[0]; my $v = $x->{$ns}; $v = $x->step($v, $_) for &$keys; $x->escape($v) },
        # the SPLIT metadata the value carries, if it is read straight from an array element
        meta => sub {
            my ($x, $v, $i, $a) = @_;
            return undef unless %{ $x->{side} };
            if (my @k = &$keys) {
                $i = pop @k;
                $a = $x->walk($ns eq 'node' ? $v : $x->{$ns}, @k);
            }
            elsif ($ns ne 'node') { return undef }
            return ref $a eq 'ARRAY' && is_idx($i) ? $x->elem_meta($a, $x->index_for($a, $i)) : undef;
        },
    };
}

#---------------------------------------------------------------------------
# Match context

sub match ($c, $ctx, $s) { $c->as_seq($ctx, $c->_match($ctx, $s)) }

sub _match ($c, $ctx, $s) {
    my $one = $ctx->{seq} ? { %$ctx, seq => 0, top => 0 } : $ctx;    # for matching a single element
    if (my $row = row(\%EXPR, $s)) {
        return $c->matcher($ctx, $c->value($ctx, $s))                # a function's result, used as a pattern
            unless $row->{kind} eq 'match' || $row->{name} eq 'EXPR';
        my ($n, $read) = $c->reading(sub { $c->build($row->{seq} ? $ctx : $one, $row, $s) });
        return $n if %$read || $n->{seq} || $n->{caps} || $n->{poison};
        # A match that reads nothing, not even the node it is matched
        # against, has one answer.
        my $known = $c->fold($ctx, $s, $n);
        return $known unless $known->{const};
        my $yes = $known->{value} ? 1 : 0;
        return { zero => $n->{zero}, code => sub { $yes } };
    }
    return $c->matcher($ctx, konst($s)) if ref $s ne 'ARRAY' && ref $s ne 'HASH';
    return $c->fault('only characters can be matched in a string') if $ctx->{regex};
    $c->reads('node');
    return $c->object($one, $s) if ref $s eq 'HASH';
    return $c->array($one, $s->[0]) if @$s == 1 && ref $s->[0] eq 'ARRAY';
    return $c->fault(@$s ? 'unknown expression' : 'an empty array is not an expression');
}

# Match the node against whatever value $v produces.  A node that compares
# against a constant says so (`lit`), letting a pattern made only of such
# nodes collapse into one comparison.
sub matcher ($c, $ctx, $v) {
    return $v if $v->{poison};
    $c->reads('node');
    return $c->char_matcher($ctx, $v) if $ctx->{regex};
    my ($exact, $get) = ($ctx->{exact}, $v->{code});
    return { throws => 1, code => sub { match_lit($_[1], &$get, $exact) } } unless $v->{const};
    my $lit = $v->{value};
    my $t   = type_of($lit);
    return { lit => $lit, code =>
          $t == T_STR  ? sub { defined $_[1] && !ref $_[1] && !created_as_number($_[1]) && !is_bool($_[1]) && $_[1] eq $lit }
        : $t == T_NUM  ? sub { created_as_number($_[1]) && $_[1] == $lit }
        : $t == T_NULL ? sub { !defined $_[1] }
        :                sub { match_lit($_[1], $lit, $exact) } };
}

# The same, where the node is a character of a string: a one-character string
# or a code point matches it, and any other string is a run of characters.
sub char_matcher ($c, $ctx, $v) {
    my $get = $c->here($ctx, $v->{code});
    if (!$v->{const}) {
        return { throws => 1, seq => 1, code => sub { char_step($_[0], &$get, @_[ 1 .. 3 ]) } } if $ctx->{seq};
        return { throws => 1, code => sub { my $cp = char_code($_[0], &$get); created_as_number($_[1]) && $_[1] == $cp } };
    }
    my $lit = $v->{value};
    is_str($lit) || is_int($lit) && $lit >= 0 or return $c->fault('not a character or string');
    return { code => do { my $cp = char_code(undef, $lit); sub { created_as_number($_[1]) && $_[1] == $cp } } }
        unless $ctx->{seq};
    my $n = is_str($lit) ? length $lit : 1;
    return { seq => 1, one => $n == 1, code => is_str($lit)
        ? sub { substr(${ $_[1] }, $_[2], $n) eq $lit ? $_[2] + $n : () }
        : sub { $_[2] < $_[3] && ord(substr ${ $_[1] }, $_[2], 1) == $lit ? $_[2] + 1 : () } };
}

sub char_code ($x, $v) {
    return is_int($v) && $v >= 0 ? $v : is_str($v) ? (length $v == 1 ? ord $v : -1)
         : $x->fail_operand('not a character');
}

sub char_step ($x, $v, $subject, $p, $len) {
    if (is_str($v)) {
        my $n = length $v;
        return substr($$subject, $p, $n) eq $v ? $p + $n : ();
    }
    my $cp = char_code($x, $v);
    return $p < $len && ord(substr $$subject, $p, 1) == $cp ? $p + 1 : ();
}

# Make code that expects (x, node, key, parent) callable with the arguments
# of the context it is used in.
sub here ($c, $ctx, $code) {
    return $code unless $ctx->{seq};
    my $chars = $ctx->{regex};
    return sub {
        my ($x, $s, $p, $len) = @_;
        $code->($x, $p < $len ? ($chars ? ord substr($$s, $p, 1) : $s->[$p]) : $MISSING, $p, $s);
    };
}

# In a sequence, a node that matches a single element becomes a sequence
# item: it consumes that element, or none if it is a zero-width assertion.
sub as_seq ($c, $ctx, $n) {
    return $n if !$ctx->{seq} || $n->{seq} || $n->{poison};
    my $test = $n->{code};
    my $here = $c->here($ctx, $test);
    my $code = $n->{zero}     ? sub { &$here ? $_[2] : () }
             : $ctx->{regex}  ? sub { $_[2] < $_[3] && &$here ? $_[2] + 1 : () }
             :                  sub { $_[2] < $_[3] && $test->($_[0], $_[1][ $_[2] ], $_[2], $_[1]) ? $_[2] + 1 : () };
    my $seq = { %$n, code => $code, seq => 1, one => !$n->{zero} };
    # To extract captures, match the chosen element again with capturing on.
    $seq->{resolve} = sub ($x, $s, $from, $to, $len) {
        push @{ $x->{path} }, $from unless $n->{zero};
        $here->($x, $s, $from, $len);
        pop @{ $x->{path} } unless $n->{zero};
    } if $n->{caps};
    return $seq;
}

# Call a child matcher with its key appended to the capture path.
sub keyed ($n) {
    my $test = $n->{code};
    return $test unless $n->{caps};
    return sub { push @{ $_[0]{path} }, $_[2]; my $ok = &$test; pop @{ $_[0]{path} }; $ok };
}

sub object ($c, $ctx, $s) {
    my $exact = $ctx->{exact};
    my %kid   = map { $_ => $c->match($ctx, $s->{$_}) } keys %$s;
    return $c->matcher($ctx, konst({ map { $_ => $kid{$_}{lit} } keys %kid }))
        unless grep { !exists $_->{lit} } values %kid;
    my @test  = map { [ $_, keyed($kid{$_}) ] } keys %kid;
    return node(sub {
        my ($x, $n) = @_;
        return 0 unless ref $n eq 'HASH';
        my $present = 0;
        for (@test) {
            my ($k, $test) = @$_;
            my $has = exists $n->{$k};
            $test->($x, $has ? $n->{$k} : $MISSING, $k, $n) or return 0;
            $present += $has;
        }
        return !$exact || $present == keys %$n;
    }, values %kid);
}

# An array pattern.  Items are matched one per element, unless one of them is
# SEQ / SEQMAX / SEQMIN, which makes the whole pattern a sequence.  $from, if
# given, is code for the index of the first element matched (ARRAY), and
# then elements after the pattern are always allowed.
sub array ($c, $ctx, $items, $from = undef) {
    my $exact = $ctx->{exact} && !$from;
    my $gone  = sub ($x, @element) { $x->{moving} && grep { ref eq 'JGraft::Missing' } @element };
    my $start = sub ($x, $a, $ofs) {
        is_int($ofs) or $x->fail_operand('array offset must be an integer');
        $ofs += @$a if $ofs < 0;
        return $ofs >= 0 && $ofs <= @$a && !$gone->($x, @$a[ 0 .. $ofs - 1 ]) ? $ofs : undef;    # skipped elements must exist
    };
    if (grep { $c->begins_seq($ctx, $_) } @$items) {
        my @kid = map { $c->match({ %$ctx, seq => 1, top => 1 }, $_) } @$items;
        my $run = JGraft::Seq::runner(\@kid);
        my $n   = node(sub {
            my ($x, $a) = @_;
            return 0 unless ref $a eq 'ARRAY';
            my $i = $from ? $start->($x, $a, &$from) // return 0 : 0;
            return $run->($x, $a, scalar @$a, [$i], $exact ? scalar @$a : undef);
        }, @kid);
        return { %$n, throws => 1 };
    }
    my @kid  = map { $c->match($ctx, $_) } @$items;
    return $c->matcher($ctx, konst([ map { $_->{lit} } @kid ])) unless $from || grep { !exists $_->{lit} } @kid;
    my @test = map { keyed($_) } @kid;
    return node(sub {
        my ($x, $a) = @_;
        return 0 unless ref $a eq 'ARRAY';
        my $i = $from ? $start->($x, $a, &$from) // return 0 : 0;
        return 0 if $i + @test > @$a + 1 || $exact && @$a > @test;     # one item may test the element past the end
        for my $test (@test) {
            $test->($x, $i < @$a ? $a->[$i] : $MISSING, $i, $a) or return 0;
            $i++;
        }
        return !($ctx->{exact} && $gone->($x, @$a[ $i .. $#$a ]));
    }, @kid);
}

# A separate match: its own HAS/IS state, with recoverable errors meaning
# "no match".  With $cap the code returns the captures (a hash) or undef.
sub root ($c, $ctx, $s, $cap = 0) {
    my $n    = $c->match({ scope => $ctx->{scope}, regex => $ctx->{regex}, cap => $cap }, $s);
    my $test = trap($n);
    return { code => $test } unless $cap;
    return { code => sub { &$test ? {} : undef } } unless $n->{caps};
    return { code => sub {
        my $x = $_[0];
        local @$x{qw(caps capturing path)} = ({}, 1, []);
        &$test ? $x->{caps} : undef;
    } };
}

# Code for $n in which a recoverable error counts as a failure to match.
sub trap ($n) {
    my $code = $n->{code};
    return $code unless $n->{throws};
    return $n->{seq}
        ? sub { local $_[0]{quiet} = 1; my @r; eval { @r = &$code; 1 } or recoverable($@); @r }
        : sub { local $_[0]{quiet} = 1; my $r; eval { $r = &$code; 1 } or recoverable($@); $r };
}

sub recoverable ($error) { die $error unless ref $error eq 'JGraft::Error' && $error->{soft} }

#---------------------------------------------------------------------------
# Common expressions

# $s, with literal [EXPR, name] references replaced by what they name.
sub deref ($c, $ctx, $s, $seen = {}) {
    my $row = row(\%EXPR, $s);
    return $s unless $row && $row->{name} eq 'EXPR' && @$s == 2 && defined $s->[1] && !ref $s->[1];
    my $exprs = $ctx->{scope}{exprs};
    return $s if !exists $exprs->{ $s->[1] } || $seen->{ $s->[1] }++;
    return $c->deref($ctx, $exprs->{ $s->[1] }, $seen);
}

# The name of the operation at the root of $s, if any.
sub peek ($c, $ctx, $s) {
    my $row = row(\%EXPR, $c->deref($ctx, $s));
    return $row && $row->{name};
}

# Does $s begin matching (rather than produce a value to match against)?
sub matches ($c, $ctx, $s) {
    row(\%EXPR, $s) or return 1;                          # structure, matched as written
    my $row = row(\%EXPR, $c->deref($ctx, $s)) or return 0;   # a named structure is a value
    return $row->{kind} eq 'match' || $row->{name} eq 'EXPR';
}

# Does $s, as an item of an array pattern, make that pattern a sequence?
sub begins_seq ($c, $ctx, $s) {
    $s = $c->deref($ctx, $s);
    my $row = row(\%EXPR, $s) or return 0;
    return $row->{name} eq 'WITH' ? $c->begins_seq($ctx, $s->[-1]) : $row->{name} =~ /^SEQ/;
}

defop EXPR => -5, 'ref', 'V', sub ($c, $ctx, $name) {
    my $scope = $ctx->{scope};
    my $sig   = join ',', map { $_ // 0 } @$ctx{qw(v seq top exact regex cap)};
    my $cell  = sub ($nm) {       # one compiled copy per definition and context, made on first use
        is_str($nm) || is_int($nm) and exists $scope->{exprs}{$nm} or return undef;
        $scope->{cells}{"$sig $nm"} //= { def => $scope->{exprs}{$nm} };
    };
    my $fixed = $name->{const} && ($cell->($name->{value}) // return $c->fault('unknown common expression'));
    my $which = $c->here($ctx, $name->{code});
    my $site  = $c->{site};
    # A definition is a value unless it is itself a match expression.  One
    # that is a constant can stand in place of every reference to it.
    my $compile = sub ($def) {
        local $c->{site} = $site;       # this may be called by a run, long after
        my $row     = row(\%EXPR, $def);
        my $matches = !$ctx->{v} && $row && ($row->{kind} eq 'match' || $row->{name} eq 'EXPR');
        return $c->match($ctx, $def) if $matches;
        my $v = $c->value($ctx, $def);
        my $n = $ctx->{v} ? $v : $c->as_seq($ctx, $c->matcher($ctx, $v));
        return { %$n, inline => $v->{const} };
    };
    # A reference by a literal name is compiled now (unless it is to the very
    # definition being compiled), so that what it reads is known here.
    if ($fixed) {
        if (!$fixed->{node} && !$fixed->{busy}) {
            local $fixed->{busy} = 1;
            ($fixed->{node}, my $read) = $c->reading(sub { $compile->($fixed->{def}) });
            $fixed->{reads} = [ keys %$read ];
        }
        $c->reads($fixed->{reads} ? @{ $fixed->{reads} } : '*');
        return { %{ $fixed->{node} } } if $fixed->{node} && $fixed->{node}{inline};
    }
    else { $c->reads('*') }
    # a literal reference to SEQMAX / SEQMIN keeps the length preference visible
    my $pref = $fixed && $ctx->{cap} && $ctx->{top}
        ? { SEQMAX => 'max', SEQMIN => 'min' }->{ $c->peek($ctx, $fixed->{def}) // '' } : undef;
    return {
        throws => 1, seq => $ctx->{seq}, caps => $fixed && $ctx->{cap}, pref => $pref, dated => 1,
        code   => sub {
            my $x  = $_[0];
            my $it = $fixed || $cell->(&$which) // $x->fail_operand('unknown common expression');
            --$x->{ops} >= 0 or $x->limit('ops');
            local $x->{depth} = $x->{depth} + 1;
            $x->{depth} <= $x->{max_depth} or $x->limit('depth');
            ($it->{node} //= $compile->($it->{def}))->{code}->(@_);
        },
        resolve => sub { my $r = $fixed->{node} && $fixed->{node}{resolve}; &$r if $r },
    };
}, seq => 1;

defop $_->[0], $_->[1], 'ref', '', undef, path => 1
    for [ CAP => -4 ], [ TEMP => -3 ], [ STASH => -2 ], [ CONST => -1 ], [ NODE => 0 ];

require JGraft::Ops::Match;
require JGraft::Ops::Fn;
require JGraft::Ops::Math;
require JGraft::Ops::Split;
require JGraft::Ops::Action;

1;
