package App::Yath::Options::Runner;
use strict;
use warnings;

our $VERSION = '1.000090';

use Test2::Util qw/IS_WIN32/;
use Test2::Harness::Util qw/clean_path/;
use File::Spec;

use App::Yath::Options;

my $DEFAULT_COVER_ARGS = '-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl';

option_group {prefix => 'runner', category => "Runner Options"} => sub {
    option use_fork => (
        alt         => ['fork'],
        description => "(default: on, except on windows) Normally tests are run by forking, which allows for features like preloading. This will turn off the behavior globally (which is not compatible with preloading). This is slower, it is better to tag misbehaving tests with the '# HARNESS-NO-PRELOAD' comment in their header to disable forking only for those tests.",
        env_vars => [qw/!T2_NO_FORK T2_HARNESS_FORK !T2_HARNESS_NO_FORK YATH_FORK !YATH_NO_FORK/],
        default     => sub {
            return 0 if IS_WIN32;
            return 1;
        },
    );

    option abort_on_bail => (
        type => 'b',
        default => 1,
        description => "Abort all testing if a bail-out is encountered (default: on)",
    );

    option use_timeout => (
        alt         => ['timeout'],
        description => "(default: on) Enable/disable timeouts",
        default     => 1,
    );

    option job_count => (
        type           => 's',
        short          => 'j',
        alt            => ['jobs'],
        description    => 'Set the number of concurrent jobs to run (Default: 1)',
        env_vars       => [qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/],
        clear_env_vars => 1,
        default        => 1,
    );

    option dump_depmap => (
        type => 'b',
        description => "When using staged preload, dump the depmap for each stage as json files",
        default => 0,
    );

    option includes => (
        name        => 'include',
        short       => 'I',
        type        => 'm',
        description => "Add a directory to your include paths",
    );

    option resources => (
        name => 'resource',
        short => 'R',
        type => 'm',
        description => "Use a resource module to assign resource assignments to individual tests",
        long_examples  => [' Port', ' +Test2::Harness::Runner::Resource::Port'],
        short_examples => [' Port'],

        normalize => sub {
            my $val = shift;

            $val = "Test2::Harness::Runner::Resource::$val"
            unless $val =~ s/^\+//;

            return $val;
        },
    );

    option tlib => (
        description => "(Default: off) Include 't/lib' in your module path",
        default     => 0,
        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;
            push @{$settings->runner->includes} => File::Spec->catdir('t', 'lib');
        },
    );

    option lib => (
        short => 'l',
        description => "(Default: include if it exists) Include 'lib' in your module path",
        default     => 1,
        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;
            push @{$settings->runner->includes} => 'lib';
            $settings->runner->lib(0);
            $settings->runner->blib(0);
        },
    );

    option blib => (
        short => 'b',
        description => "(Default: include if it exists) Include 'blib/lib' and 'blib/arch' in your module path",
        default     => 1,
        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;

            push @{$settings->runner->includes} => (
                File::Spec->catdir('blib', 'lib'),
                File::Spec->catdir('blib', 'arch'),
            );

            $settings->runner->lib(0);
            $settings->runner->blib(0);
        },
    );

    option unsafe_inc => (
        description => "perl is removing '.' from \@INC as a security concern. This option keeps things from breaking for now.",
        env_vars    => [qw/PERL_USE_UNSAFE_INC/],
        default     => 0,
    );

    option preloads => (
        type        => 'm',
        alt         => ['preload'],
        short       => 'P',
        description => 'Preload a module before running tests',
    );

    option preload_threshold => (
        short => 'W',
        alt => ['Pt'],
        type => 's',
        default => 0,
        description => "Only do preload if at least N tests are going to be run. In some cases a full preload takes longer than simply running the tests, this lets you specify a minimum number of test jobs that will be run for preload to happen. This has no effect for a persistent runner. The default is 0, and it means always preload."
    );

    option nytprof => (
        type => 'b',
        description => "Use Devel::NYTProf on tests. This will set addpid=1 for you. This works with or without fork.",
        long_examples => [''],
    );

    post \&cover_post_process;
    option cover => (
        type        => 'd',
        description => "Use Devel::Cover to calculate test coverage. This disables forking. If no args are specified the following are used: $DEFAULT_COVER_ARGS",
        long_examples => ['', '=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl'],
        action      => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;

            return $$slot = $DEFAULT_COVER_ARGS if $norm eq '1';
            return $$slot = $norm;
        },
    );

    option switch => (
        field        => 'switches',
        short        => 'S',
        type         => 'm',
        description  => 'Pass the specified switch to perl for each test. This is not compatible with preload.',
    );

    option event_timeout => (
        alt => ['et'],

        type => 's',
        default => 60,

        long_examples  => [' SECONDS'],
        short_examples => [' SECONDS'],
        description    => 'Kill test if no output is received within timeout period. (Default: 60 seconds). Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis. This prevents a hung test from running forever.',
    );

    option post_exit_timeout => (
        alt => ['pet'],

        type => 's',
        default => 15,

        long_examples  => [' SECONDS'],
        short_examples => [' SECONDS'],
        description    => 'Stop waiting post-exit after the timeout period. (Default: 15 seconds) Some tests fork and allow the parent to exit before writing all their output. If Test2::Harness detects an incomplete plan after the test exits it will monitor for more events until the timeout period. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.'
    );
};

sub cover_post_process {
    my %params   = @_;
    my $settings = $params{settings};

    if ($ENV{T2_DEVEL_COVER} && !$settings->runner->cover) {
        $settings->runner->field(cover => $ENV{T2_DEVEL_COVER} eq '1' ? $ENV{T2_DEVEL_COVER} : $DEFAULT_COVER_ARGS);
    }

    return unless $settings->runner->cover;

    # For nested things
    $ENV{T2_NO_FORK} = 1;
    $ENV{T2_DEVEL_COVER} = $settings->runner->cover;
    $settings->runner->field(use_fork => 0);

    return unless $settings->check_prefix('run');
    push @{$settings->run->load_import->{'@'}} => 'Devel::Cover';
    $settings->run->load_import->{'Devel::Cover'} = [split(/,/, $settings->runner->cover)];
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Runner - Runner options for Yath.

=head1 DESCRIPTION

This is where command line options for the runner are defined.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
