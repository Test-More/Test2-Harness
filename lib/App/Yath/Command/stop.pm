package App::Yath::Command::stop;
use strict;
use warnings;

our $VERSION = '1.000134';

use Time::HiRes qw/sleep/;

use File::Spec();

use Test2::Harness::Util::File::JSON();
use Test2::Harness::Util::Queue();

use Test2::Harness::Util qw/open_file/;
use App::Yath::Util qw/find_pfile/;
use File::Path qw/remove_tree/;

use parent 'App::Yath::Command::run';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub summary { "Stop the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will stop a persistent instance, and output any log contents.
    EOT
}

sub pfile_params { (no_fatal => 1) }

sub run {
    my $self = shift;

    $self->App::Yath::Command::test::terminate_queue();

    $_->teardown($self->settings) for @{$self->settings->harness->plugins};

    sleep(0.02) while kill(0, $self->pfile_data->{pid});

    my $pfile = $self->pfile;
    unlink($pfile) if -f $pfile;

    remove_tree($self->workdir, {safe => 1, keep_root => 0}) if -d $self->workdir;

    print "\n\nRunner stopped\n\n" unless $self->settings->display->quiet;
    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

