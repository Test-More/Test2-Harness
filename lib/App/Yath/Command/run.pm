package App::Yath::Command::run;
use strict;
use warnings;

our $VERSION = '0.001100';

use App::Yath::Options;

use Test2::Harness::Run;
use Test2::Harness::Util::Queue;
use Test2::Harness::Util::File::JSON;
use Test2::Harness::IPC;

use App::Yath::Util qw/find_pfile/;
use Test2::Harness::Util qw/open_file/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Harness::Util qw/mod2file open_file/;
use Test2::Util::Table qw/table/;

use File::Spec;

use Carp qw/croak/;

use parent 'App::Yath::Command::test';
use Test2::Harness::Util::HashBase qw/+pfile_data/;

include_options(
    'App::Yath::Options::Debug',
    'App::Yath::Options::Display',
    'App::Yath::Options::Logging',
    'App::Yath::Options::PreCommand',
    'App::Yath::Options::Run',
);

sub group { 'persist' }

sub summary { "Run tests using the persistent test runner" }
sub cli_args { "[--] [test files/dirs] [::] [arguments to test scripts]" }

sub description {
    return <<"    EOT";
This command will run tests through an already started persistent instance. See
the start command for details on how to launch a persistant instance.
    EOT
}

sub pfile_data {
    my $self = shift;
    return $self->{+PFILE_DATA} if $self->{+PFILE_DATA};

    my $pfile = find_pfile()
        or die "No persistent harness was found for the current path.\n";

    return $self->{+PFILE_DATA} = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();
}

sub workdir {
    my $self = shift;
    return $self->pfile_data->{dir};
}

sub build_run_item {
    my $self = shift;
    my ($run) = @_;

    my $settings = $self->{+SETTINGS};

    my $run_queue = $self->run_queue;
    $run_queue->enqueue($run->queue_item($settings->yath->plugins));
}

sub start_runner {
    my $self = shift;
    return Test2::Harness::IPC::Process->new(pid => $self->pfile_data->{pid});
}

sub write_settings_to {}

1;
