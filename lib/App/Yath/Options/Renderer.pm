package App::Yath::Options::Renderer;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util qw/mod2file fqmod/;

use Getopt::Yath;
include_options(
    'App::Yath::Options::Term',
);

option_group {group => 'renderer', category => "Renderer Options"} => sub {
    option quiet => (
        type        => 'Bool',
        short       => 'q',
        description => "Be very quiet.",
        default     => 0,
    );

    option verbose => (
        type        => 'Count',
        short       => 'v',
        description => "Be more verbose",
        initialize  => 0,
    );

    option qvf => (
        type        => 'Bool',
        default     => 0,
        description => "Toggles both 'quiet' and 'verbose' which a renderer should accept to mean 'quiet on success, verbose on failure'.",
        trigger     => sub {
            my $opt    = shift;
            my %params = @_;
            if ($params{action} eq 'set') {
                $params{group}->{quiet}   ||= 1;
                $params{group}->{verbose} ||= 1;
            }
            else {
                $params{group}->{quiet}   = 0;
                $params{group}->{verbose} = 0;
            }
        },
    );

    option wrap => (
        type => 'Bool',
        default => 1,
        description => "When active (default) renderers should try to wrap text in a human-friendly way. When this is turned off they should just throw text at the terminal."
    );

    option show_times => (
        type => 'Bool',
        short => 'T',
        description => 'Show the timing data for each job.',
    );

    option hide_runner_output => (
        type        => 'Bool',
        default     => 0,
        description => 'Hide output from the runner, showing only test output. (See Also truncate_runner_output)',
    );

    option truncate_runner_output => (
        type        => 'Bool',
        default     => 0,
        description => 'Only show runner output that was generated after the current command. This is only useful with a persistent runner.',
    );

    option classes => (
        type  => 'Map',
        name  => 'renderers',
        field => 'classes',
        alt   => ['renderer'],

        description => 'Specify renderers. Use "+" to give a fully qualified module name. Without "+" "App::Yath::Renderer::" will be prepended to your argument.',

        long_examples  => [' +My::Renderer', ' MyRenderer,MyOtherRenderer', ' MyRenderer=opt1,opt2', ' :{ MyRenderer :{ opt1 opt2 }: }:', '=:{ MyRenderer opt1,opt2,... }:'],
        short_examples => ['MyRenderer',     ' +My::Renderer', ' MyRenderer,MyOtherRenderer', ' MyRenderer=opt1,opt2', ' :{ MyRenderer :{ opt1 opt2 }: }:', '=:{ MyRenderer opt1,opt2,... }:'],
        initialize     => sub { {'App::Yath::Renderer::Default' => []} },

        normalize => sub { fqmod($_[0], 'App::Yath::Renderer'), ref($_[1]) ? $_[1] : [split(',', $_[1] // '')] },

        mod_adds_options => 1,
    );

    option show_job_end => (
        type    => 'Bool',
        default => 1,

        description => 'Show output when a job ends. (Default: on)',
    );

    option show_job_info => (
        type    => 'Bool',
        default => sub { my $v = $_[1]->renderer->verbose // 0; $v > 1 ? 1 : 0 },

        description => 'Show the job configuration when a job starts. (Default: off, unless -vv)',
    );

    option show_job_launch => (
        type    => 'Bool',
        default => sub { my $v = $_[1]->renderer->verbose // 0; $v ? 1 : 0 },

        description => "Show output for the start of a job. (Default: off unless -v)",
    );

    option show_run_info => (
        type    => 'Bool',
        default => sub { my $v = $_[1]->renderer->verbose // 0; $v > 1 ? 1 : 0 },

        description => 'Show the run configuration when a run starts. (Default: off, unless -vv)',
    );
};

sub init_renderers {
    my $class = shift;
    my ($settings, %params) = @_;

    my $rs = $settings->renderer;
    my $r_classes = $rs->classes;
    my @renderers;
    for my $class (keys %$r_classes) {
        my $params = $r_classes->{$class};
        require(mod2file($class));
        my $r = $class->new($settings->renderer->all, $settings->term->all, @$params, %params);
        $r->start();
        push @renderers => $r;
    }

    return \@renderers;
}

1;
