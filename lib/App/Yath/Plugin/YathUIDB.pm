package App::Yath::Plugin::YathUIDB;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::UI::Util qw/config_from_settings/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::Util qw/mod2file looks_like_uuid/;

use Getopt::Yath;
use parent 'App::Yath::Plugin';

option_group {prefix => 'yathui-db', category => "YathUI Options"} => sub {
    option config => (
        type => 's',
        description => "Module that implements 'MODULE->yath_ui_config(%params)' which should return a Test2::Harness::UI::Config instance.",
    );

    option driver => (
        type => 's',
        description => "DBI Driver to use",
        long_examples => [' Pg', 'mysql', 'MariaDB'],
    );

    option name => (
        type => 's',
        description => 'Name of the database to use for yathui',
    );

    option user => (
        type => 's',
        description => 'Username to use when connecting to the db',
    );

    option pass => (
        type => 's',
        description => 'Password to use when connecting to the db',
    );

    option dsn => (
        type => 's',
        description => 'DSN to use when connecting to the db',
    );

    option host => (
        type => 's',
        description => 'hostname to use when connecting to the db',
    );

    option port => (
        type => 's',
        description => 'port to use when connecting to the db',
    );

    option socket => (
        type => 's',
        description => 'socket to use when connecting to the db',
    );

    option flush_interval => (
        type => 's',
        long_examples => [' 2', ' 1.5'],
        description => 'When buffering DB writes, force a flush when an event is recieved at least N seconds after the last flush.',
    );

    option buffering => (
        type => 's',
        long_examples => [ ' none', ' job', ' diag', ' run' ],
        description => 'Type of buffering to use, if "none" then events are written to the db one at a time, which is SLOW',
        default => 'diag',
    );

    option coverage => (
        type => 'b',
        description => 'Pull coverage data directly from the database (default: off)',
        default => 0,
    );

    option durations => (
        type => 'b',
        description => 'Pull duration data directly from the database (default: off)',
        default => 0,
    );

    option duration_limit => (
        type => 's',
        description => 'Limit the number of runs to look at for durations data (default: 10)',
        default => 25,
    );

    option publisher => (
        type => 's',
        description => 'When using coverage or duration data, only use data uploaded by this user',
    );
};

sub get_coverage_searches {
    my ($plugin, $settings, $changes) = @_;

    my ($changes_exclude_loads, $changes_exclude_opens);
    if ($settings->check_prefix('finder')) {
        my $finder = $settings->finder;
        $changes_exclude_loads = $finder->changes_exclude_loads;
        $changes_exclude_opens = $finder->changes_exclude_opens;
    }

    my @searches;
    for my $source_file (keys %$changes) {
        my $changed_sub_map = $changes->{$source_file};
        my @changed_subs = keys %$changed_sub_map;

        my $search = {'source_file.filename' => $source_file};
        unless ($changed_sub_map->{'*'} || !@changed_subs) {
            my %seen;

            my @inject;
            push @inject => '*'  unless $changes_exclude_loads;
            push @inject => '<>' unless $changes_exclude_opens;

            $search->{'source_sub.subname'} = {'IN' => [grep { !$seen{$_}++} @inject, @changed_subs]};
        }

        push @searches => $search;
    }

    return @searches;
}

sub get_coverage_rows {
    my ($plugin, $settings, $changes) = @_;

    my $ydb = $settings->prefix('yathui-db') or return;
    return unless $ydb->coverage;

    my $config  = config_from_settings($settings);
    my $schema  = $config->schema;
    my $pname   = $settings->yathui->project                            or die "yathui-project is required.\n";
    my $project = $schema->resultset('Project')->find({name => $pname}) or die "Invalid project '$pname'.\n";
    my $run = $project->last_covered_run(user => $ydb->publisher) or return;

    my @searches = $plugin->get_coverage_searches($settings, $changes) or return;
    return $run->expanded_coverages({'-or' => \@searches});
}

my %CATEGORIES = (
    '*'  => 'loads',
    '<>' => 'opens',
);
sub test_map_from_coverage_rows {
    my ($plugin, $coverages) = @_;

    my %tests;
    while (my $cover = $coverages->next()) {
        my $test = $cover->test_filename or next;

        if (my $manager = $cover->manager_package) {
            unless ($tests{$test}) {
                if (eval { require(mod2file($manager)); 1 }) {
                    $tests{$test} = {manager => $manager, subs => [], loads => [], opens => []};
                }
                else {
                    warn "Error loading manager '$manager'. Running entire test '$test'.\nError:\n====\n$@\n====\n";
                    $tests{$test} = 0;
                    next;
                }
            }

            my $cat = $CATEGORIES{$cover->source_subname} // 'subs';
            push @{$tests{$test}->{$cat}} => @{$cover->metadata};
        }
        else {
            $tests{$test} //= 0;
        }
    }

    return \%tests;
}

sub get_coverage_tests {
    my ($plugin, $settings, $changes) = @_;

    my $ydb = $settings->prefix('yathui-db') or return;
    return unless $ydb->coverage;

    my $coverages = $plugin->get_coverage_rows($settings, $changes) or return;

    my $tests = $plugin->test_map_from_coverage_rows($coverages);

    return $plugin->search_entries_from_test_map($tests, $changes, $settings);
}

sub search_entries_from_test_map {
    my ($plugin, $tests, $changes, $settings) = @_;

    my @out;
    for my $test (keys %$tests) {
        my $meta = $tests->{$test};
        my $manager = $meta ? delete $meta->{manager} : undef;

        unless ($meta && $manager) {
            push @out => $test;
            next;
        }

        unless (eval { push @out => [ $test, $manager->test_parameters($test, $meta, $changes, undef, $settings) ]; 1 }) {
            warn "Error processing coverage data for '$test' using manager '$manager'. Running entire test to be safe.\nError:\n====\n$@\n====\n";
            push @out => $test;
        }
    }

    return @out;
}

sub duration_data {
    my ($plugin, $settings) = @_;
    my $ydb = $settings->prefix('yathui-db') or return;
    return unless $ydb->durations;

    my $config = config_from_settings($settings);
    my $schema = $config->schema;
    my $pname   = $settings->yathui->project                            or die "yathui-project is required.\n";
    my $project = $schema->resultset('Project')->find({name => $pname}) or die "Invalid project '$pname'.\n";

    my %args = (user => $ydb->publisher, limit => $ydb->duration_limit);
    if (my $yui = $settings->prefix('yathui')) {
        $args{short}  = $yui->medium_duration;
        $args{medium} = $yui->long_duration;

        # TODO
        #$args{median} = $yui->median_durations;
    }

    return $project->durations(%args);
}

sub grab_rerun {
    my $this = shift;
    my ($rerun, %params) = @_;

    return (0) if $rerun =~ m/\.jsonl(\.gz|\.bz2)?/;

    my $settings  = $params{settings};
    my $mode_hash = $params{mode_hash} //= {all => 1};

    my $config  = config_from_settings($settings);
    my $schema  = $config->schema;

    my ($ok, $err, $run);
    if ($rerun eq '1') {
        my $project_name = $settings->yathui->project;
        my $username = $settings->yathui->user // $ENV{USER};
        $ok = eval { $run = $schema->vague_run_search(query => {}, project_name => $project_name, username => $username); 1 };
        $err = $@;
    }
    elsif (looks_like_uuid($rerun)) {
        $ok = eval { $run = $schema->vague_run_search(query => {}, source => $rerun); 1 };
        $err = $@;
    }
    else {
        return (0);
    }

    unless ($run) {
        print $ok ? "No previous run found\n" : "Error getting rerun data from yathui database: $err\n";
        return (1);
    }

    print "Re-Running " . join(', ', sort keys %$mode_hash) . " tests from run id: " . $run->run_id . "\n";

    my $data = $run->rerun_data;

    return (1, $data);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Plugin::YathUIDB - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

=back

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

