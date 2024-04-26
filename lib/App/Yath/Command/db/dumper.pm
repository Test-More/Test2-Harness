package App::Yath::Command::db::dumper;
use strict;
use warnings;

our $VERSION = '2.000000';

use App::Yath::Schema::Dumper;

use App::Yath::Schema::Util qw/schema_config_from_settings/;

sub summary     { "Dump a Yath Database" }
sub description { "Dump a Yath Database" }
sub group       { "db" }

use parent 'App::Yath::Command';
use Getopt::Yath;

include_options(
    'App::Yath::Options::DB',
);

option_group {group => 'dumper', category => "Dumper Options"} => sub {
    option dir => (
        type => 'Scalar',
        default => './dump',
        description => 'Destination directory for dump files (default ./dump)',
    );

    option procs => (
        type           => 'Scalar',
        short          => 'j',
        alt            => ['procs'],
        description    => 'Set the number of processes to use to dump the database',
        notes          => "If System::Info is installed, this will default to the cpu core count, otherwise the default is 1.",
        long_examples  => [' 5'],
        short_examples => ['5'],
        from_env_vars  => [qw/DUMP_PROCS YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],

        default => sub { eval { require System::Info; System::Info->new->ncore } || 1 },

        trigger => sub {
            my $opt    = shift;
            my %params = @_;

            if ($params{action} eq 'set' || $params{action} eq 'initialize') {
                my ($val) = @{$params{val}};
                return unless $val && $val =~ m/:/;
                my ($jobs) = split /:/, $val;
                @{$params{val}} = ($jobs);
            }
        },
    );
};

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $config = schema_config_from_settings($settings);

    my $dumper = App::Yath::Schema::Dumper->new(
        config => $config,
        procs  => $settings->dumper->procs,
        dir    => $settings->dumper->dir,
    );

    $dumper->dump();
}

1;

__END__

=head1 POD IS AUTO-GENERATED
