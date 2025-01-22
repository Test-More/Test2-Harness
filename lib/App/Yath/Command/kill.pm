package App::Yath::Command::kill;
use strict;
use warnings;

our $VERSION = '1.000157';

use Time::HiRes qw/sleep/;
use App::Yath::Util qw/find_pfile/;
use File::Path qw/remove_tree/;

use Test2::Harness::Util::File::JSON();

use parent 'App::Yath::Command::abort';
use Test2::Harness::Util::HashBase;

sub group { 'persist' }

sub summary { "Kill the runner and any running or pending tests" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will kill the active yath runner and any running or pending tests.
    EOT
}

sub pfile_params { (no_checks => 1) }

sub run {
    my $self = shift;

    my $data = $self->pfile_data();
    my $pfile = $data->{pfile_path};

    $self->App::Yath::Command::test::terminate_queue();

    $_->teardown($self->settings) for @{$self->settings->harness->plugins};

    $self->SUPER::run();

    sleep(0.02) while kill(0, $self->pfile_data->{pid});
    unlink($pfile) if -f $pfile;
    remove_tree($self->workdir, {safe => 1, keep_root => 0}) if -d $self->workdir;
    print "\n\nRunner stopped\n\n" unless $self->settings->display->quiet;

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

