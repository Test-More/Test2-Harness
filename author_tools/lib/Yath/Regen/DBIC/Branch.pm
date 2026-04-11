package Yath::Regen::DBIC::Branch;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless { per_backend => $args{per_backend} }, $class;
}

sub per_backend { $_[0]->{per_backend} }

sub value_for {
    my ($self, $backend) = @_;
    return $self->{per_backend}{$backend};
}

# Returns an arrayref of [backend_list, value] pairs, grouping backends
# that share the same value. E.g. for a branch where PostgreSQL and MySQL
# both say 'bigint' but SQLite says 'integer', returns:
#   [ [['PostgreSQL','MySQL'], 'bigint'], [['SQLite'], 'integer'] ]
sub grouped {
    my ($self) = @_;
    my %by_value;
    for my $backend (sort keys %{ $self->{per_backend} }) {
        my $v = $self->{per_backend}{$backend};
        my $key = _canon($v);
        push @{ $by_value{$key}{backends} }, $backend;
        $by_value{$key}{value} = $v;
    }
    return [
        map { [ $by_value{$_}{backends}, $by_value{$_}{value} ] }
        sort keys %by_value
    ];
}

sub _canon {
    my ($v) = @_;
    return 'u:' unless defined $v;
    return 's:' . $v unless ref $v;
    require Storable;
    local $Storable::canonical = 1;
    return 'r:' . Storable::freeze(\$v);
}

1;
