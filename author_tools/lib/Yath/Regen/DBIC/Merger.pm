package Yath::Regen::DBIC::Merger;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw/merge_backends/;

use Yath::Regen::DBIC::Branch;

my @BACKENDS_ORDER = qw/SQLite PostgreSQL MySQL MariaDB Percona/;

sub merge_backends {
    my %by_backend = @_;
    my @backends   = grep { exists $by_backend{$_} } @BACKENDS_ORDER;
    die "merge_backends: need all 5 backends\n" unless @backends == @BACKENDS_ORDER;

    my $ref = $by_backend{SQLite};

    # Column presence check: every backend must have the same set, same order.
    my $ref_cols = [ map { $_->{name} } @{ $ref->{columns} } ];
    for my $b (@backends) {
        my $cols = [ map { $_->{name} } @{ $by_backend{$b}{columns} } ];
        die "column presence mismatch between SQLite and $b for $ref->{package}\n"
            unless _same_list($ref_cols, $cols);
    }

    my @merged_columns;
    for my $i (0 .. $#{ $ref->{columns} }) {
        my $name = $ref->{columns}[$i]{name};
        my %spec_per_backend;
        my %keys;
        for my $b (@backends) {
            my $spec = $by_backend{$b}{columns}[$i]{spec};
            $spec_per_backend{$b} = $spec;
            $keys{$_}++ for keys %$spec;
        }

        my %merged_spec;
        for my $key (keys %keys) {
            my %per_backend = map { $_ => $spec_per_backend{$_}{$key} } @backends;
            if (_all_same(values %per_backend)) {
                $merged_spec{$key} = $per_backend{SQLite};
            }
            else {
                $merged_spec{$key} = Yath::Regen::DBIC::Branch->new(per_backend => \%per_backend);
            }
        }

        push @merged_columns, { name => $name, spec => \%merged_spec };
    }

    # Primary key, unique constraints, relationships, table, components:
    # require full agreement across backends.
    for my $field (qw/primary_key unique_constraints relationships table components/) {
        for my $b (@backends) {
            next if $b eq 'SQLite';
            die "$field mismatch between SQLite and $b for $ref->{package}\n"
                unless _deep_equal($ref->{$field}, $by_backend{$b}{$field});
        }
    }

    return {
        package            => $ref->{package},
        table              => $ref->{table},
        components         => $ref->{components},
        columns            => \@merged_columns,
        primary_key        => $ref->{primary_key},
        unique_constraints => $ref->{unique_constraints},
        relationships      => $ref->{relationships},
    };
}

sub _same_list {
    my ($a, $b) = @_;
    return 0 unless @$a == @$b;
    for my $i (0 .. $#$a) {
        return 0 unless $a->[$i] eq $b->[$i];
    }
    return 1;
}

sub _all_same {
    my @vals = @_;
    my $ref  = _canon($vals[0]);
    for my $v (@vals) {
        return 0 unless _canon($v) eq $ref;
    }
    return 1;
}

sub _canon {
    my ($v) = @_;
    return 'u:' unless defined $v;
    return 's:' . $v unless ref $v;
    require Storable;
    local $Storable::canonical = 1;
    return 'r:' . Storable::freeze(\$v);
}

sub _deep_equal {
    my ($a, $b) = @_;
    return _canon($a) eq _canon($b);
}

1;
