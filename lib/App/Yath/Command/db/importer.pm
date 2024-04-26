package App::Yath::Command::db::importer;
use strict;
use warnings;

our $VERSION = '2.000000';

sub summary     { "Start an importer process that will wait for uploaded logs to import" }
sub description { "Start an importer process that will wait for uploaded logs to import" }
sub group       { "db" }

use App::Yath::Schema::Loader;

use App::Yath::Schema::Util qw/schema_config_from_settings/;

use parent 'App::Yath::Command';
use Getopt::Yath;

include_options(
    'App::Yath::Options::DB',
);

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $config = schema_config_from_settings($settings);

    $SIG{INT} = sub { exit 0 };
    $SIG{TERM} = sub { exit 0 };

    App::Yath::Schema::Importer->new(config => $config)->run;
}

1;

__END__

=head1 POD IS AUTO-GENERATED
