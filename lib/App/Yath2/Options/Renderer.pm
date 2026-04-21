package App::Yath2::Options::Renderer;
use strict;
use warnings;

our $VERSION = '2.000011';

use Test2::Harness2::Util qw/mod2file fqmod/;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Term',
);

option_group {group => 'renderer', category => "Renderer Options"} => sub {
    option quiet => (
        type        => 'Bool',
        short       => 'q',
        description => "Be very quiet.",
        default     => 0,
    );

    option verbose => (
        type         => 'Count',
        short        => 'v',
        description  => "Be more verbose",
        initialize   => 0,
        set_env_vars => [qw/T2_HARNESS_IS_VERBOSE HARNESS_IS_VERBOSE/],
    );

    option qvf => (
        type        => 'Bool',
        default     => 0,
        description => "Quiet on pass, verbose on failure.",
    );

    # TODO: Stage 12 — activate --theme when renderer scope expands
    # option theme => (
    #     type => 'Scalar',
    #     short => 't',
    #     description => "Select a theme for the renderer (not all renderers use this)",
    #     default     => 'App::Yath2::Theme::Default',
    #     normalize   => sub { fqmod($_[0], 'App::Yath2::Theme') },
    # );

    # TODO: Stage 12 — activate --wrap when renderer scope expands
    # option wrap => (
    #     type => 'Bool',
    #     default => 1,
    #     description => "When active (default) renderers should try to wrap text in a human-friendly way. When this is turned off they should just throw text at the terminal."
    # );

    # TODO: Stage 12 — activate --show-times when renderer scope expands
    # option show_times => (
    #     type => 'Bool',
    #     short => 'T',
    #     description => 'Show the timing data for each job.',
    # );

    # TODO: Stage 12 — activate --hide-runner-output when renderer scope expands
    # option hide_runner_output => (
    #     type        => 'Bool',
    #     default     => 0,
    #     description => 'Hide output from the runner, showing only test output. (See Also truncate_runner_output)',
    # );

    # TODO: Stage 12 — activate --truncate-runner-output when renderer scope expands
    # option truncate_runner_output => (
    #     type        => 'Bool',
    #     default     => 0,
    #     description => 'Only show runner output that was generated after the current command. This is only useful with a persistent runner.',
    # );

    option classes => (
        type  => 'Map',
        name  => 'renderers',
        field => 'classes',
        alt   => ['renderer'],
        short => 'r',

        description => 'Specify renderers. Use "+" to give a fully qualified module name. Without "+" "App::Yath2::Renderer::" will be prepended to your argument.',

        long_examples  => [' +My::Renderer', ' MyRenderer,MyOtherRenderer', ' MyRenderer=opt1,opt2'],
        short_examples => ['MyRenderer',     ' +My::Renderer',              ' MyRenderer,MyOtherRenderer'],
        initialize     => sub { {'App::Yath2::Renderer::Default' => [], 'App::Yath2::Renderer::Summary' => []} },

        normalize => sub {
            my $key = fqmod($_[0], 'App::Yath2::Renderer', no_require => 1);
            my $val = ref($_[1]) ? $_[1] : [split(',', $_[1] // '')];
            return ($key, $val);
        },
    );

    # TODO: Stage 12 — activate --show-job-end when renderer scope expands
    # option show_job_end => (
    #     type    => 'Bool',
    #     default => 1,
    #
    #     description => 'Show output when a job ends. (Default: on)',
    # );

    # TODO: Stage 12 — activate --show-job-info when renderer scope expands
    # option show_job_info => (
    #     type    => 'Bool',
    #     default => sub { my $v = $_[1]->renderer->verbose // 0; $v > 1 ? 1 : 0 },
    #
    #     description => 'Show the job configuration when a job starts. (Default: off, unless -vv)',
    # );

    # TODO: Stage 12 — activate --show-job-launch when renderer scope expands
    # option show_job_launch => (
    #     type    => 'Bool',
    #     default => sub { my $v = $_[1]->renderer->verbose // 0; $v ? 1 : 0 },
    #
    #     description => "Show output for the start of a job. (Default: off unless -v)",
    # );

    # TODO: Stage 12 — activate --show-run-info when renderer scope expands
    # option show_run_info => (
    #     type    => 'Bool',
    #     default => sub { my $v = $_[1]->renderer->verbose // 0; $v > 1 ? 1 : 0 },
    #
    #     description => 'Show the run configuration when a run starts. (Default: off, unless -vv)',
    # );

    # TODO: Stage 12 — activate --show-run-fields when renderer scope expands
    # option show_run_fields => (
    #     type    => 'Bool',
    #     default => sub { my $v = $_[1]->renderer->verbose // 0; $v > 1 ? 1 : 0 },
    #
    #     description => 'Show run fields. (Default: off, unless -vv)',
    # );

    # TODO: Stage 13 — activate --server when Server/UI scope is restored
    # option server => (
    #     type => 'Auto',
    #     autofill => 'Auto',
    #     description => "Start an ephemeral yath database and web server to view results",
    # );
};

sub init_renderers {
    my $class = shift;
    my ($settings, %params) = @_;

    my $rs = $settings->renderer;

    my $theme_class = $rs->theme;
    require(mod2file($theme_class));
    my $theme = $theme_class->new(use_color => $settings->term->color);

    my $is_qvf    = $rs->qvf || ($rs->verbose && $rs->quiet);
    my $r_classes = $rs->classes;

    my $term = -t STDOUT;

    $r_classes->{'App::Yath2::Renderer::ResetTerm'} //= [] if $term;

    if (my $eph = $rs->server) {
        $r_classes->{'App::Yath2::Renderer::Server'} //= [];
        if ($eph ne 'Auto' && $settings->check_group('server')) {
            $settings->server->option(ephemeral => $eph);
        }
    }

    my @renderers;
    for my $class (sort { $a->weight <=> $b->weight || $a cmp $b } map { require(mod2file($_)); $_ } keys %$r_classes) {
        # FIXME: Do these exist?
        $class = 'App::Yath2::Theme::QVF'     if $is_qvf  && $class eq 'App::Yath2::Theme::Default';
        $class = 'App::Yath2::Theme::Default' if !$is_qvf && $class eq 'App::Yath2::Theme::QVF';

        my $params = $r_classes->{$class};

        my $r = $class->new(
            $settings->renderer->all,
            $settings->term->all,
            @$params,
            %params,
            settings => $settings,
            theme    => $theme,
        );

        push @renderers => $r;
    }

    return \@renderers;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Renderer - FIXME

=head1 DESCRIPTION

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

