use strict;
use warnings;

use Test2::V0;
use Test2::Harness::Settings;

# Load the module to make _post_process available
require App::Yath::Options::Finder;

subtest 'durations_threshold defaults to job_count + 1 when runner is present' => sub {
    my $settings = Test2::Harness::Settings->new();

    my $finder = $settings->define_prefix('finder');
    $finder->vivify_field('durations_threshold');
    $finder->vivify_field('rerun');
    $finder->vivify_field('rerun_modes');
    $finder->field(rerun_modes => []);
    $finder->vivify_field('default_search');
    $finder->vivify_field('default_at_search');
    $finder->vivify_field('extensions');
    $finder->field(default_search    => ['./t']);
    $finder->field(default_at_search => ['./xt']);
    $finder->field(extensions        => ['t']);

    my $runner = $settings->define_prefix('runner');
    $runner->vivify_field('job_count');
    $runner->field(job_count => 4);

    App::Yath::Options::Finder::_post_process(settings => $settings, options => undef);

    is(
        $settings->finder->durations_threshold,
        5,
        'durations_threshold = job_count(4) + 1 = 5 when runner prefix exists'
    );
};

subtest 'durations_threshold defaults to 1 without runner prefix' => sub {
    my $settings = Test2::Harness::Settings->new();

    my $finder = $settings->define_prefix('finder');
    $finder->vivify_field('durations_threshold');
    $finder->vivify_field('rerun');
    $finder->vivify_field('rerun_modes');
    $finder->field(rerun_modes => []);
    $finder->vivify_field('default_search');
    $finder->vivify_field('default_at_search');
    $finder->vivify_field('extensions');
    $finder->field(default_search    => ['./t']);
    $finder->field(default_at_search => ['./xt']);
    $finder->field(extensions        => ['t']);

    App::Yath::Options::Finder::_post_process(settings => $settings, options => undef);

    is(
        $settings->finder->durations_threshold,
        1,
        'durations_threshold = 1 when no runner prefix'
    );
};

subtest 'explicit durations_threshold is not overridden' => sub {
    my $settings = Test2::Harness::Settings->new();

    my $finder = $settings->define_prefix('finder');
    $finder->vivify_field('durations_threshold');
    $finder->field(durations_threshold => 10);
    $finder->vivify_field('rerun');
    $finder->vivify_field('rerun_modes');
    $finder->field(rerun_modes => []);
    $finder->vivify_field('default_search');
    $finder->vivify_field('default_at_search');
    $finder->vivify_field('extensions');
    $finder->field(default_search    => ['./t']);
    $finder->field(default_at_search => ['./xt']);
    $finder->field(extensions        => ['t']);

    my $runner = $settings->define_prefix('runner');
    $runner->vivify_field('job_count');
    $runner->field(job_count => 4);

    App::Yath::Options::Finder::_post_process(settings => $settings, options => undef);

    is(
        $settings->finder->durations_threshold,
        10,
        'explicit durations_threshold is preserved'
    );
};

done_testing;
