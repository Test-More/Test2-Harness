package App::Yath::Command::db::loader;
use strict;
use warnings;

our $VERSION = '2.000000';

use App::Yath::Schema::Loader;

use App::Yath::Schema::Util qw/schema_config_from_settings/;

sub summary     { "Load a dumped database" }
sub description { "Load a dumped database" }
sub group       { "db" }

use parent 'App::Yath::Command';
use Getopt::Yath;

include_options(
    'App::Yath::Options::DB',
);

option_group {group => 'loader', category => "Loader Options"} => sub {
    option dir => (
        type => 'Scalar',
        default => './dump',
        description => 'Directory of dump files to load (default ./dump)',
    );

    option procs => (
        type           => 'Scalar',
        short          => 'j',
        alt            => ['procs'],
        description    => 'Set the number of processes to use to load the database',
        notes          => "If System::Info is installed, this will default to the cpu core count, otherwise the default is 1.",
        long_examples  => [' 5'],
        short_examples => ['5'],
        from_env_vars  => [qw/LOAD_PROCS YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],

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

    my $loader = App::Yath::Schema::Loader->new(
        config => $config,
        procs  => $settings->loader->procs,
        dir    => $settings->loader->dir,
    );

    $loader->load();
}

1;

__END__

=head1 POD IS AUTO-GENERATED
