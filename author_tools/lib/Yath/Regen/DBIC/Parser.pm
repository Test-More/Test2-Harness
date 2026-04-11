package Yath::Regen::DBIC::Parser;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw/parse_dump/;

sub parse_dump {
    my ($content) = @_;

    # Find all package declarations. DBIC::Schema::Loader dumps have a primary
    # package (e.g. App::Yath::Schema::SQLite::User) followed by a secondary
    # declaration that names the Result class (e.g. App::Yath::Schema::Result::User).
    # The Result class is the one we want; it is the LAST package declaration.
    # The secondary declaration may be split across lines:
    #     package
    #         App::Yath::Schema::Result::User;
    my @packages;
    while ($content =~ /\bpackage\s+([\w:]+)\s*;/g) {
        push @packages, $1;
    }
    die "parse_dump: could not find package declaration\n" unless @packages;

    my $package = $packages[-1];

    my $captured = {
        package            => $package,
        components         => [],
        columns            => [],
        primary_key        => [],
        unique_constraints => [],
        relationships      => [],
        table              => undef,
    };

    # Build a unique sandbox package whose methods accumulate into $captured.
    my $sandbox = 'Yath::Regen::DBIC::Parser::_Sandbox' . int(rand(2**31));
    no strict 'refs';
    *{ "${sandbox}::load_components" } = sub { shift; push @{ $captured->{components} }, @_ };
    *{ "${sandbox}::table" }           = sub { shift; $captured->{table} = $_[0] };
    *{ "${sandbox}::add_columns" }     = sub {
        shift;
        my @args = @_;
        while (@args) {
            my $name = shift @args;
            my $spec = shift @args;
            push @{ $captured->{columns} }, { name => $name, spec => $spec };
        }
    };
    *{ "${sandbox}::set_primary_key" } = sub { shift; $captured->{primary_key} = [@_] };
    *{ "${sandbox}::add_unique_constraint" } = sub {
        shift;
        my ($name, $cols) = @_;
        push @{ $captured->{unique_constraints} }, { name => $name, cols => [@$cols] };
    };
    for my $kind (qw/has_many might_have belongs_to has_one/) {
        *{ "${sandbox}::${kind}" } = sub {
            shift;
            my ($name, $target, $cond, $attrs) = @_;
            push @{ $captured->{relationships} }, {
                kind   => $kind,
                name   => $name,
                target => $target,
                cond   => $cond,
                attrs  => $attrs // {},
            };
        };
    }
    use strict 'refs';

    # Rewrite ALL package declarations to point at the sandbox so every
    # __PACKAGE__->method call lands on our stubs. Strip `use parent` /
    # `use base` so we don't inherit DBIC. Strip trailing POD so eval
    # doesn't choke on __END__.
    my $munged = $content;
    $munged =~ s/\bpackage\s+[\w:]+\s*;/package $sandbox;/g;
    $munged =~ s/use\s+parent\s+[^;]+;//g;
    $munged =~ s/use\s+base\s+[^;]+;//g;
    $munged =~ s/^__END__\b.*//ms;

    local $@;
    my $ok = eval $munged;
    if (!$ok) {
        die "parse_dump eval failed for $package: $@\n";
    }

    return $captured;
}

1;
