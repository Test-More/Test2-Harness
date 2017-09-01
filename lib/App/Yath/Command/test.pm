package App::Yath::Command::test;
use strict;
use warnings;

our $VERSION = '0.001005';

use Test2::Harness::Feeder::Run;
use Test2::Harness::Run::Runner;
use Test2::Harness::Run;

use parent 'App::Yath::CommandShared::Harness';
use Test2::Harness::Util::HashBase;

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
        no_stream  => $settings->{no_stream},
        no_fork    => $settings->{no_fork},
        times      => $settings->{times},
    );

    my $runner = Test2::Harness::Run::Runner->new(
        dir => $settings->{dir},
        run => $run,
    );

    my $pid = $runner->spawn;

    my $queue_file = $runner->queue_file;
    sleep 0.02 until -e $queue_file;
    for my $file ($run->find_files) {
        $runner->enqueue({file => $file});
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
