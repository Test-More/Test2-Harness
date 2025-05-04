package App::Yath::Options::Display;
use strict;
use warnings;

our $VERSION = '1.000158';

use Test2::Harness::Util qw/mod2file/;

use App::Yath::Options;

option_group {prefix => 'display', category => "Display Options"} => sub {
    option color => (
        description => "Turn color on, default is true if STDOUT is a TTY.",
        default     => sub { -t STDOUT ? 1 : 0 },
    );

    option quiet => (
        short       => 'q',
        type        => 'c',
        description => "Be very quiet.",
        default     => 0,
    );

    option verbose => (
        short       => 'v',
        type        => 'c',
        description => "Be more verbose",
        default     => 0,
    );

    option no_wrap => (
        type        => 'b',
        description => "Do not do fancy text-wrapping, let the terminal handle it",
        default     => 0,
    );

    option show_times => (
        short       => 'T',
        description => 'Show the timing data for each job',
    );

    option hide_runner_output => (
        description => 'Hide output from the runner, showing only test output. (See Also truncate_runner_output)',
        default     => 0,
    );

    option truncate_runner_output => (
        description => 'Only show runner output that was generated after the current command. This is only useful with a persistent runner.',
        default     => 0,
    );

    option term_width => (
        type          => 's',
        alt           => ['term-size'],
        description   => 'Alternative to setting $TABLE_TERM_SIZE. Setting this will override the terminal width detection to the number of characters specified.',
        long_examples => [' 80', ' 200'],

        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;
            $ENV{TABLE_TERM_SIZE} = $norm;
        },
    );

    option 'progress' => (
        default => sub { -t STDOUT ? 1 : 0 },

        description => "Toggle progress indicators. On by default if STDOUT is a TTY. You can use --no-progress to disable the 'events seen' counter and buffered event pre-display",
    );

    option renderers => (
        alt  => ['renderer'],
        type => 'H',

        description => 'Specify renderers, (Default: "Formatter=Test2"). Use "+" to give a fully qualified module name. Without "+" "Test2::Harness::Renderer::" will be prepended to your argument.',

        long_examples  => [' +My::Renderer', ' Renderer=arg1,arg2,...'],
        short_examples => [' +My::Renderer', ' Renderer=arg1,arg2,...'],

        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;

            my ($class, $args) = @$norm;

            $class = "Test2::Harness::Renderer::$class"
                unless $class =~ s/^\+//;

            my $file = mod2file($class);
            my $ok   = eval { require $file; 1 };
            warn "Failed to load renderer '$class': $@" unless $ok;

            $handler->($slot, [$class, $args]);
        },
    );

    post 100 => sub {
        my %params   = @_;
        my $settings = $params{settings};

        my $display   = $settings->display;
        my $renderers = $display->renderers;

        my $quiet   = $display->quiet;
        my $verbose = $display->verbose;

        die "The 'quiet' and 'verbose' options may not be used together.\n"
            if $verbose && $quiet;

        if ($quiet) {
            delete $renderers->{'Test2::Harness::Renderer::Formatter'};
            @{$renderers->{'@'}} = grep { $_ ne 'Test2::Harness::Renderer::Formatter' } @{$renderers->{'@'}};
            return;
        }

        my @args = map { $_ => $settings->formatter->$_ } qw{
                formatter
                show_run_info
                show_job_info
                show_job_launch
                show_job_end
            };

        push @args => map { $_ => $settings->display->$_ } qw{
                progress
                color
                quiet
                verbose
                show_times
            };

        if (my $formatter_args = $renderers->{'Test2::Harness::Renderer::Formatter'}) {
            @$formatter_args = @args unless @$formatter_args;
            return;
        }

        return if $renderers->{'@'} && @{$renderers->{'@'}};

        push @{$renderers->{'@'}} => 'Test2::Harness::Renderer::Formatter';
        $renderers->{'Test2::Harness::Renderer::Formatter'} = \@args;
    };
};

option_group {prefix => 'formatter', category => "Formatter Options"} => sub {
    option formatter => (
        type                => 's',
    );

    option 'qvf' => (
        description => '[Q]uiet, but [V]erbose on [F]ailure. Hide all output from tests when they pass, except to say they passed. If a test fails then ALL output from the test is verbosely output.',
    );

    option show_job_end => (
        description => 'Show output when a job ends. (Default: on)',
        default     => 1,
    );

    option show_job_info => (
        description         => 'Show the job configuration when a job starts. (Default: off, unless -vv)',
        default             => 0,
    );

    option show_job_launch => (
        description         => "Show output for the start of a job. (Default: off unless -v)",
        default             => 0,
    );

    option show_run_info => (
        description         => 'Show the run configuration when a run starts. (Default: off, unless -vv)',
        default             => 0,
    );

    post 90 => sub {
        my %params   = @_;
        my $settings = $params{settings};

        $settings->formatter->field(formatter => $settings->formatter->qvf ? 'QVF' : 'Test2')
            unless defined $settings->formatter->formatter;

        $settings->formatter->field(show_job_launch => 1)
            if $settings->display->verbose > 0;

        if ($settings->display->verbose > 1) {
            $settings->formatter->field(show_job_info => 1);
            $settings->formatter->field(show_run_info => 1);
        }
    };
};

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Display - Display options for Yath.

=head1 DESCRIPTION

This is where display options are defined.

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
