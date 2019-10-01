package App::Yath::Options::Runner;
use strict;
use warnings;

our $VERSION = '0.001100';

use Test2::Util qw/IS_WIN32/;
use Test2::Harness::Util qw/clean_path/;

use App::Yath::Options;

option_group {prefix => 'runner', category => "Runner Options"} => sub {
    option use_fork => (
        alt         => ['fork'],
        description => "(default: on, except on windows) Normally tests are run by forking, which allows for features like preloading. This will turn off the behavior globally (which is not compatible with preloading). This is slower, it is better to tag misbehaving tests with the '# HARNESS-NO-PRELOAD' coment in their header to disable forking only for those tests.",
        default     => sub { !IS_WIN32 },
    );

    option use_timeout => (
        alt         => ['timeout'],
        description => "(default: on) Enable/disable timeouts",
        default     => 1,
    );

    option job_count => (
        type        => 's',
        short       => 'j',
        alt         => ['jobs'],
        description => 'Set the number of concurrent jobs to run (Default: 1)',
        default     => 1,
    );

    option includes => (
        name        => 'include',
        short       => 'I',
        type        => 'm',
        description => "Add a directory to your include paths",
        normalize   => \&clean_path,
    );

    option tlib => (
        description => "(Default: off) Include 't/lib' in your module path",
        default     => 0,
    );

    option lib => (
        description => "(Default: on) Include 'lib' in your module path",
        default     => 1,
    );

    option blib => (
        description => "(Default: on) Include 'blib/lib' and 'blib/arch' in your module path",
        default     => 1,
    );

    option unsafe_inc => (
        description => "perl is removing '.' from \@INC as a security concern. This option keeps things from breaking for now.",
        default     => sub {
            return $ENV{PERL_USE_UNSAFE_INC} if defined $ENV{PERL_USE_UNSAFE_INC};
            return 1;
        },
    );

    option preloads => (
        type        => 'm',
        alt         => ['preload'],
        short       => 'P',
        description => 'Preload a module before running tests',
    );

    option cover => (
        description  => 'Use Devel::Cover to calculate test coverage. This disables forking',
        post_process => \&cover_post_process,
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

    return unless $settings->runner->cover;
    eval { require Devel::Cover; 1 } or die "Cannot use --cover without Devel::Cover: $@";

    $settings->runner->use_fork = 0;

    unshift @{$settings->run->load_import //= []} => 'Devel::Cover=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl';
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Runner - Runner options for Yath.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
