package Yath::Regen::DBIC::Emitter;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw/emit_result_body/;

use Yath::Regen::DBIC::Branch;

sub emit_result_body {
    my ($spec) = @_;
    my @lines;

    if (@{ $spec->{components} }) {
        push @lines, "__PACKAGE__->load_components(";
        for my $c (@{ $spec->{components} }) {
            push @lines, qq{    "$c",};
        }
        push @lines, ");";
    }

    push @lines, qq{__PACKAGE__->table("$spec->{table}");};
    push @lines, '__PACKAGE__->add_columns(';
    for my $col (@{ $spec->{columns} }) {
        push @lines, qq{    "$col->{name}",};
        push @lines, _emit_column_hash($col->{spec});
    }
    push @lines, ');';

    if (@{ $spec->{primary_key} }) {
        my $pk = join ', ', map { qq{"$_"} } @{ $spec->{primary_key} };
        push @lines, "__PACKAGE__->set_primary_key($pk);";
    }

    for my $uc (@{ $spec->{unique_constraints} }) {
        my $cols = join ', ', map { qq{"$_"} } @{ $uc->{cols} };
        push @lines, qq{__PACKAGE__->add_unique_constraint("$uc->{name}", [$cols]);};
    }

    for my $rel (@{ $spec->{relationships} }) {
        push @lines, _emit_relationship($rel);
    }

    return join("\n", @lines) . "\n";
}

sub _emit_column_hash {
    my ($spec) = @_;
    my @lines = ('    {');
    for my $key (sort keys %$spec) {
        my $val = $spec->{$key};
        if (ref($val) eq 'Yath::Regen::DBIC::Branch') {
            push @lines, "        $key => " . _emit_branch($val) . ",";
        }
        else {
            push @lines, "        $key => " . _emit_scalar($val) . ",";
        }
    }
    push @lines, '    },';
    return @lines;
}

sub _emit_scalar {
    my ($v) = @_;
    return 'undef' unless defined $v;
    if (ref $v eq 'ARRAY') {
        return '[' . join(', ', map { _emit_scalar($_) } @$v) . ']';
    }
    if (ref $v eq 'HASH') {
        my @pairs;
        for my $k (sort keys %$v) {
            push @pairs, qq{"$k" => } . _emit_scalar($v->{$k});
        }
        return '{ ' . join(', ', @pairs) . ' }';
    }
    if (ref $v eq 'SCALAR') {
        # Literal SQL reference, e.g. \"null".
        return '\\' . _emit_scalar($$v);
    }
    # Numeric?
    return $v if defined $v && !ref($v) && $v =~ /\A-?\d+(?:\.\d+)?\z/;
    my $quoted = $v;
    $quoted =~ s/\\/\\\\/g;
    $quoted =~ s/"/\\"/g;
    return qq{"$quoted"};
}

sub _emit_branch {
    my ($branch) = @_;
    my $groups = $branch->grouped;

    # Build a ternary chain. The LAST group becomes the final `else` — which
    # one doesn't matter for correctness as long as every backend is covered,
    # so pick a stable choice: whichever group is listed last by ->grouped.
    my @group_exprs;
    for my $g (@$groups) {
        my ($backends, $value) = @$g;
        my $cond = _backends_condition($backends);
        push @group_exprs, [ $cond, _emit_scalar($value) ];
    }

    my $chain = $group_exprs[-1][1];
    for (my $i = $#group_exprs - 1; $i >= 0; $i--) {
        my ($cond, $val) = @{ $group_exprs[$i] };
        $chain = "$cond ? $val : $chain";
    }
    return $chain;
}

sub _backends_condition {
    my ($backends) = @_;
    my %b = map { $_ => 1 } @$backends;
    my @tests;
    push @tests, 'is_sqlite()'     if $b{SQLite};
    push @tests, 'is_postgresql()' if $b{PostgreSQL};
    push @tests, 'is_mysql()'      if $b{MySQL};
    push @tests, 'is_mariadb()'    if $b{MariaDB};
    push @tests, 'is_percona()'    if $b{Percona};
    return @tests == 1 ? $tests[0] : '(' . join(' || ', @tests) . ')';
}

sub _emit_relationship {
    my ($rel) = @_;
    my $target = $rel->{target};
    $target =~ s/^App::Yath::Schema::Result::/App::Yath::Schema::DBIC::Result::/;

    my $cond_src  = _emit_scalar($rel->{cond});
    my $attrs_src = ($rel->{attrs} && %{ $rel->{attrs} })
        ? ', ' . _emit_scalar($rel->{attrs})
        : '';

    return sprintf(
        qq{__PACKAGE__->%s(\n    "%s",\n    "%s",\n    %s%s,\n);},
        $rel->{kind},
        $rel->{name},
        $target,
        $cond_src,
        $attrs_src,
    );
}

1;
