package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '0.001007';

use Test2::Harness::Util::TestFile;
use Test2::Harness::Feeder::Run;
use Test2::Harness::Run::Runner;
use Test2::Harness::Run::Queue;
use Test2::Harness::Run;

use Time::HiRes qw/time/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub has_jobs    { 1 }
sub has_runner  { 1 }
sub has_logger  { 1 }
sub has_display { 1 }

sub summary { "run tests" }
sub cli_args { "[--] [test files/dirs] [::] [arguments to test scripts]" }

sub description {
    return <<"    EOT";
This yath command (which is also the default command) will run all the test
files for the current project. If no test files are specified this command will
look for the 't', and 't2' dirctories, as well as the 'test.pl' file.

This command is always recursive when given directories.

This command will add 'lib', 'blib/arch' and 'blib/lib' to the perl path for
you by default.

Any command line argument that is not an option will be treated as a test file
or directory of test files to be run.

If you wish to specify the ARGV for tests you may append them after '::'. This
is mainly useful for Test::Class::Moose and similar tools. EVERY test run will
get the same ARGV.
    EOT
}

sub handle_list_args {
    my $self = shift;
    my ($list) = @_;

    my $settings = $self->{+SETTINGS} ||= {};

    $settings->{search} = $list;

    my $has_search = $settings->{search} && @{$settings->{search}};

    unless ($has_search) {
        my @dirs = grep { -d $_ } './t', './t2';
        my @files = grep { -f $_ } 'test.pl';

        $settings->{search} = [@dirs, @files];
    }
}


sub feeder {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $run = $self->make_run_from_settings(finite => 1);

    my $runner = Test2::Harness::Run::Runner->new(
        dir => $settings->{dir},
        run => $run,
    );

    my $queue = $runner->queue;
    $queue->start;

    my $pid = $runner->spawn;

    my $job_id = 1;
    for my $tf ($run->find_files) {
        $queue->enqueue($tf->queue_item($job_id++));
    }

    $queue->end;

    my $feeder = Test2::Harness::Feeder::Run->new(
        run      => $run,
        runner   => $runner,
        dir      => $settings->{dir},
        keep_dir => $settings->{keep_dir},
    );

    return ($feeder, $runner, $pid);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::test - Command to run tests

=head1 DESCRIPTION

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
