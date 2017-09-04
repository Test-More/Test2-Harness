package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '0.001005';

use Test2::Harness::Util::TestFile;
use Test2::Harness::Feeder::Run;
use Test2::Harness::Run::Runner;
use Test2::Harness::Run::Queue;
use Test2::Harness::Run;

use Time::HiRes qw/time/;

use parent 'App::Yath::CommandShared::Harness';
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

sub feeder {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $run = Test2::Harness::Run->new(
        run_id     => $settings->{run_id},
        job_count  => $settings->{job_count},
        switches   => $settings->{switches},
        libs       => $settings->{libs},
        lib        => $settings->{lib},
        blib       => $settings->{blib},
        preload    => $settings->{preload},
        args       => $settings->{test_args},
        input      => $settings->{input},
        chdir      => $settings->{chdir},
        search     => $settings->{search},
        unsafe_inc => $settings->{unsafe_inc},
        env_vars   => $settings->{env_vars},
        use_stream => $settings->{use_stream},
        use_fork   => $settings->{use_fork},
        times      => $settings->{times},
        verbose    => $settings->{verbose},
        finite     => 1,
    );

    my $runner = Test2::Harness::Run::Runner->new(
        dir => $settings->{dir},
        run => $run,
    );

    my $pid = $runner->spawn;

    my %queues = (
        general   => Test2::Harness::Run::Queue->new(file => $runner->general_queue_file),
        isolation => Test2::Harness::Run::Queue->new(file => $runner->isolate_queue_file),
        long      => Test2::Harness::Run::Queue->new(file => $runner->long_queue_file),
    );

    my @files = $run->find_files;
    sleep 0.02 until $runner->ready;

    for my $file (@files) {
        $file = File::Spec->rel2abs($file);
        my $tf = Test2::Harness::Util::TestFile->new(file => $file);

        my $queue_name = $tf->check_queue;
        if (!$queue_name) {
            # 'isolation' queue if isolation requested
            $queue_name = 'isolation' if $tf->check_feature('isolation');

            # 'long' queue for anything that cannot preload or fork
            $queue_name ||= 'long' unless $tf->check_feature(preload => 1);
            $queue_name ||= 'long' unless $tf->check_feature(fork    => 1);

            # 'long' for anything with no timeout
            $queue_name ||= 'long' unless $tf->check_feature(timeout => 1);

            # Default
            $queue_name ||= 'general';
        }

        my $queue = $queues{$queue_name};
        unless($queue) {
            warn "File '$file' wants queue '$queue_name', but there is no such queue. Using the 'general' queue";
            $queue_name = 'general';
            $queue = $queues{$queue_name};
        }

        my $item = {
            file        => $file,
            use_fork    => $tf->check_feature(fork => 1),
            use_timeout => $tf->check_feature(timeout => 1),
            use_preload => $tf->check_feature(preload => 1),
            switches    => $tf->switches,
            queue       => $queue_name,
            stamp       => time,
        };

        $queue->enqueue($item);
    }
    $runner->end_queue;

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
