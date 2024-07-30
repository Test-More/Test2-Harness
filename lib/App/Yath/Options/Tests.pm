package App::Yath::Options::Tests;
use strict;
use warnings;

our $VERSION = '2.000001';

use Importer Importer => 'import';
use Getopt::Yath;

our @EXPORT_OK = qw/ set_dot_args /;

use Test2::Harness::TestSettings;
my $DEFAULT_COVER_ARGS = Test2::Harness::TestSettings->default_cover_args;

###############################################################################
# *********** NOTE !!!! ***************************************************** #
# Everything in here should be null unless it is specified as --opt or        #
# --no-opt                                                                    #
###############################################################################

option_group {group => 'tests', category => 'Test Options', maybe => 1} => sub {
    option env_vars => (
        type        => 'Map',
        alt         => ['env-var'],
        short       => 'E',
        description => 'Set environment variables',
    );

    option use_fork => (
        type          => 'Bool',
        alt           => ['fork'],
        description   => "(default: on, except on windows) Normally tests are run by forking, which allows for features like preloading. This will turn off the behavior globally (which is not compatible with preloading). This is slower, it is better to tag misbehaving tests with the '# HARNESS-NO-PRELOAD' comment in their header to disable forking only for those tests.",
        from_env_vars => [qw/!T2_NO_FORK T2_HARNESS_FORK !T2_HARNESS_NO_FORK YATH_FORK !YATH_NO_FORK/],
    );

    option load => (
        type  => 'List',
        short => 'm',
        alt   => ['load-module'],

        description => 'Load a module in each test (after fork). The "import" method is not called.',
    );

    option load_import => (
        type  => 'Map',
        short => 'M',
        alt   => ['loadim'],

        long_examples  => [' Module', ' Module=import_arg1,arg2,...', qq/ '{"Data::Dumper":["Dumper"]}'/],
        short_examples => [' Module', ' Module=import_arg1,arg2,...', qq/ '{"Data::Dumper":["Dumper"]}'/],

        description => 'Load a module in each test (after fork). Import is called.',
        normalize   => sub { $_[0] => [split /,/, $_[1]] },

        trigger => sub {
            my $opt    = shift;
            my %params = @_;

            return unless $params{action} eq 'set';

            my $mod = $params{val}->[0];
            push @{$params{ref}->{'@'}} => $mod unless $params{ref}->{$mod};
        },
    );

    option use_timeout => (
        type        => 'Bool',
        alt         => ['timeout'],
        description => "(default: on) Enable/disable timeouts",
    );

    option includes => (
        type        => 'PathList',
        name        => 'include',
        short       => 'I',
        description => "Add a directory to your include paths",
    );

    option tlib => (
        type        => 'Bool',
        description => "(Default: off) Include 't/lib' in your module path (These will come after paths you specify with -D or -I)",
    );

    option lib => (
        type        => 'Bool',
        short       => 'l',
        description => "(Default: include if it exists) Include 'lib' in your module path (These will come after paths you specify with -D or -I)",
    );

    option blib => (
        type        => 'Bool',
        short       => 'b',
        description => "(Default: include if it exists) Include 'blib/lib' and 'blib/arch' in your module path (These will come after paths you specify with -D or -I)",
    );

    option cover => (
        type     => 'Auto',
        autofill => $DEFAULT_COVER_ARGS,

        from_env_vars => [qw/T2_DEVEL_COVER/],
        set_env_vars  => [qw/T2_DEVEL_COVER/],

        description   => "Use Devel::Cover to calculate test coverage. This disables forking. If no args are specified the following are used: $DEFAULT_COVER_ARGS",
        long_examples => ['', "=$DEFAULT_COVER_ARGS"],
    );

    option switches => (
        type        => 'List',
        alt         => ['switch'],
        short       => 'S',
        description => 'Pass the specified switch to perl for each test. This is not compatible with preload.',
    );

    option event_timeout => (
        alt            => ['et'],
        type           => 'Scalar',
        long_examples  => [' SECONDS'],
        short_examples => [' SECONDS'],
        description    => 'Kill test if no output is received within timeout period. (Default: 60 seconds). Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis. This prevents a hung test from running forever.',
    );

    option post_exit_timeout => (
        alt            => ['pet'],
        type           => 'Scalar',
        long_examples  => [' SECONDS'],
        short_examples => [' SECONDS'],
        description    => 'Stop waiting post-exit after the timeout period. (Default: 15 seconds) Some tests fork and allow the parent to exit before writing all their output. If Test2::Harness detects an incomplete plan after the test exits it will monitor for more events until the timeout period. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.'
    );

    option unsafe_inc => (
        type          => 'Bool',
        from_env_vars => [qw/PERL_USE_UNSAFE_INC/],
        set_env_vars  => [qw/PERL_USE_UNSAFE_INC/],
        description   => "perl is removing '.' from \@INC as a security concern. This option keeps things from breaking for now.",
    );

    option stream => (
        type   => 'Bool',
        alt    => ['use-stream'],
        alt_no => ['TAP'],

        description => "The TAP format is lossy and clunky. Test2::Harness normally uses a newer streaming format to receive test results. There are old/legacy tests where this causes problems, in which case setting --TAP or --no-stream can help.",
    );

    option test_args => (
        type  => 'List',
        alt   => ['test-arg'],
        field => 'args',

        description => 'Arguments to pass in as @ARGV for all tests that are run. These can be provided easier using the \'::\' argument separator.'
    );

    option input => (
        type        => 'Scalar',
        description => 'Input string to be used as standard input for ALL tests. See also: --input-file',
    );

    option input_file => (
        type => 'Scalar',

        description => 'Use the specified file as standard input to ALL tests',

        trigger => sub {
            my $opt = shift;
            my %params = @_;
            return unless $params{action} eq 'set';

            my ($file) = @{$params{val}};
            die "Input file not found: $file\n" unless -f $file;

            my $settings = $params{settings};
            if ($settings->tests->input) {
                warn "Input file is overriding a --input string.\n";
                $settings->tests->field(input => undef);
            }
        },
    );

    option event_uuids => (
        type => 'Bool',

        description => 'Use Test2::Plugin::UUID inside tests (default: on)',
    );

    option mem_usage => (
        type => 'Bool',

        description => 'Use Test2::Plugin::MemUsage inside tests (default: on)',
    );

    option allow_retry => (
        type        => 'Bool',
        description => "Toggle retry capabilities on and off (default: on)",
    );

    option retry => (
        type  => 'Scalar',
        short => 'r',

        description => 'Run any jobs that failed a second time. NOTE: --retry=1 means failing tests will be attempted twice!',
    );

    option retry_isolated => (
        type => 'Bool',
        alt  => ['retry-iso'],

        description => 'If true then any job retries will be done in isolation (as though -j1 was set)',
    );
};

sub set_dot_args {
    my $class = shift;
    my ($settings, $dot_args) = @_;

    my $oldvals = $settings->tests->args // [];
    unshift @$dot_args => @$oldvals;
    $settings->tests->option(args => $dot_args);

    return;
}



1;

__END__


=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Tests - Options common to all commands that run tests.

=head1 DESCRIPTION

Options common to all commands that run tests.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
