package App::Yath::Plugin::Cover;
use strict;
use warnings;

our $VERSION = '1.000073';

use Test2::Harness::Util qw/clean_path mod2file/;
use Test2::Harness::Util::JSON qw/encode_json/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use parent 'App::Yath::Plugin';
use Test2::Harness::Util::HashBase qw/-aggregator -no_aggregate +metrics/;

use App::Yath::Options;

option_group {prefix => 'cover', category => "Cover Options"} => sub {
    post \&post_process;

    option types => (
        alt => ['cover-type'],
        type => 'm',
        default => sub { [qw/pl pm/] },
    );

    option dirs => (
        alt => ['cover-dir'],
        type => 'm',
        default => sub { ['lib'] },

        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;
            push @$$slot => glob($norm);
        },
    );

    option exclude_private => (
        type => 'b',
        default => 0,
        description => "",
    );

    option files => (
        type => 'b',
        description => "Use Test2::Plugin::Cover to collect coverage data for what files are touched by what tests. Unlike Devel::Cover this has very little performance impact (About 4% difference)",
    );

    option metrics => (
        type => 'b',
        description => '',
    );

    option write => (
        type => 'd',
        normalize => \&clean_path,
        long_examples => ['', '=coverage.json'],
        description => "Create a json file of all coverage data seen during the run (This implies --cover-files).",
        action      => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;

            return $$slot = clean_path("coverage.json") if $raw eq '1';
            return $$slot = $norm;
        },
    );

    option aggregator => (
        type => 's',
        description => 'Choose an aggregator (default Test2::Harness::Log::CoverageAggregator)',
        default => 'Test2::Harness::Log::CoverageAggregator',
    );

    option class => (
        type => 's',
        description => 'Choose a Test2::Plugin::Cover subclass',
        default => 'Test2::Plugin::Cover',
    );
};

sub spawn_args {
    my $self = shift;
    my ($settings) = @_;

    return () unless $settings->cover->files || $settings->cover->metrics || $settings->cover->write;

    my $class = $settings->cover->class;
    return ('-M' . $class . '=disabled,1');
}

sub post_process {
    my %params   = @_;
    my $settings = $params{settings};

    my $cover = $settings->cover;

    if ($cover->files || $cover->write || $cover->metrics) {
        my $cover_class = $cover->class // 'Test2::Plugin::Cover';

        eval { require(mod2file($cover_class)); 1 } or die "Could not enable file coverage, could not load '$cover_class': $@";
        push @{$settings->run->load_import->{'@'}} => $cover_class;
        $settings->run->load_import->{$cover_class} = [];
    }
}

sub handle_event {
    my $self = shift;
    return if $self->{+NO_AGGREGATE};
    my ($e, $settings) = @_;

    unless ($self->{+AGGREGATOR}) {
        my $do_cover = $settings->cover->files;
        my $file = $settings->cover->write;
        my $metrics = $settings->cover->metrics;

        unless ($file || $metrics || $do_cover) {
            $self->{+NO_AGGREGATE} = 1;
            return;
        }

        my $agg = $settings->cover->aggregator // 'Test2::Harness::Log::CoverageAggregator';
        require(mod2file($agg));
        $self->{+AGGREGATOR} = $agg->new();
    }

    my $fd = $e->{facet_data};

    $self->{+AGGREGATOR}->process_event($e)
        if $fd->{coverage} || $fd->{harness_job_end} || $fd->{harness_job_start};

    return;
}

sub metrics {
    my $self = shift;
    my ($settings) = @_;

    my $cover = $settings->cover;

    return unless $cover->metrics;

    my $aggregator = $self->{+AGGREGATOR};

    return $self->{+METRICS} //= $aggregator->build_metrics(
        dirs            => $cover->dirs,
        types           => $cover->types,
        exclude_private => $cover->exclude_private,
    );
}

sub _percentages {
    my $self = shift;
    my ($metrics) = @_;

    return unless $metrics;

    my @out;

    for my $metric (sort keys %$metrics) {
        my $data = $metrics->{$metric} or next;
        my ($total, $tested) = @{$data}{qw/total tested/};
        push @out => [$metric, $total, $tested, $total ? (int(($tested / $total) * 100) . '%') : '100%'];
    }

    return \@out;
}

sub teardown {
    my $self = shift;
    my ($settings, $renderers, $logger) = @_;

    my $cover      = $settings->cover;
    my $aggregator = $self->{+AGGREGATOR} or return;
    my $metrics    = $self->metrics($settings) if $cover->metrics;
    my $coverage   = $aggregator->coverage;

    my $percentages = $self->_percentages($metrics);
    my $raw         = join ", ", map { "$_->[0]: $_->[2]/$_->[1] ($_->[3])" } @$percentages;
    my $details     = join ", ", map { "$_->[0] $_->[3]" } @$percentages;

    $details = "coverage" unless length $details;

    require Test2::Harness::Event;
    my $e = Test2::Harness::Event->new(
        job_id     => 0,
        stamp      => time,
        event_id   => gen_uuid(),
        run_id     => $settings->run->run_id,
        facet_data => {
            about => { details => 'Aggregated Coverage Data' },
            run_fields => [
                {name => 'coverage', details => $details, data => $coverage, $raw ? (raw => $raw) : ()},
            ],
        },
    );

    print $logger $e->as_json, "\n" if $logger;

    $_->render_event($e) for @$renderers;
}

sub finalize {
    my $self = shift;
    my ($settings) = @_;

    my $cover     = $settings->cover;
    my $file      = $cover->write;
    my $metrics = $cover->metrics;

    return unless $file || $metrics;
    print "\nCoverage:\n";

    my $aggregator = $self->{+AGGREGATOR};

    if ($metrics) {
        my $data = $self->metrics($settings);

        require Term::Table;
        my $table = Term::Table->new(
            header => [qw/METRIC TOTAL TESTED PERCENTAGE/],
            rows   => $self->_percentages($data),
        );
        print map { "$_\n" } $table->render;
    }

    if ($file) {
        my $coverage = $aggregator->coverage;

        if (open(my $fh, '>', $file)) {
            print $fh encode_json($coverage);
            close($fh);
            print "Wrote coverage file: $file\n";
        }
        else {
            warn "Could not write coverage file '$file': $!";
        }
    }

    print "\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Plugin::Cover - Plugin to collect and report basic coverage data

=head1 DESCRIPTION

Simple coverage data, file and sub coverage only. Use L<Devel::Cover> if you
want deep coverage stats.

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
