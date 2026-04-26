package App::Yath2::Renderer::Summary;
use strict;
use warnings;

use Test2::Util::Table qw/table/;
use Test2::Harness2::Util qw/clean_path render_duration/;
use Test2::Harness2::Util::JSON qw/json_true json_false/;

use List::Util qw/max/;

our $VERSION = '2.000011';

use parent 'App::Yath2::Renderer';
use Object::HashBase qw{
    <file
    +_run_end
    +_failed_jobs
};

use Getopt::Yath;

option_group {group => 'summary', category => "Summary Options"} => sub {
    option summary => (
        field    => 'file',
        type     => 'Auto',
        autofill => sub { 'summary.json' },

        description => "Write out a summary json file, if no path is provided 'summary.json' will be used. The .json extension is added automatically if omitted.",

        long_examples => ['', '=/path/to/summary.json'],

        normalize => sub {
            my $val = shift;
            $val .= '.json' unless $val =~ m/\.json$/;
            return clean_path($val);
        },

        applicable => sub {
            my ($option, $options) = @_;

            return 1 if $options->have_group('renderer');
            return 0;
        },
    );
};

sub desired_filters { () }    # must see harness_run_end and harness_job_end — no pre-filtering

sub args_from_settings {
    my $class = shift;
    my %params = @_;
    my $settings = $params{settings};
    return unless $settings->check_group('summary');
    return $settings->summary->all;
}

sub init {
    my $self = shift;
    $self->SUPER::init();
    $self->{+_FAILED_JOBS} //= [];
}

sub weight { -99 }

sub render_event {
    my $self  = shift;
    my ($event) = @_;

    my $f = $event->{facet_data} // {};

    if (my $re = $f->{harness_run_end}) {
        $self->{+_RUN_END} = $re;
    }

    if (my $je = $f->{harness_job_end}) {
        push @{$self->{+_FAILED_JOBS}} => [$je->{job_id}, $je->{rel_file} // $je->{file}]
            if $je->{fail};
    }
}

sub finish {
    my $self = shift;

    my $run_end = $self->{+_RUN_END} // {};

    $self->render_summary($run_end);
    $self->write_summary_file($run_end);
}

sub render_summary {
    my $self = shift;
    my ($run_end) = @_;

    my $pass         = $run_end->{pass};
    my $pass_count   = $run_end->{pass_count} // 0;
    my $fail_count   = $run_end->{fail_count} // 0;
    my $total        = $pass_count + $fail_count;
    my $wall_time    = $run_end->{wall_time};
    my $cum_job_time = $run_end->{cumulative_job_time};
    my $cpu_times    = $run_end->{cpu_times};
    my $cpu_total    = $run_end->{cpu_total};
    my $cpu_usage    = $run_end->{cpu_usage};

    if (my $rows = $self->{+_FAILED_JOBS}) {
        if (@$rows) {
            print "\nThe following jobs failed:\n";
            print join "\n" => table(
                header => ['Job ID', 'Test File'],
                rows   => [sort { $a->[1] cmp $b->[1] } @$rows],
            );
            print "\n";
        }
    }

    my @summary = (
        $fail_count ? ("     Fail Count: $fail_count") : (),
        "     File Count: $total",
        (defined $wall_time
            ? sprintf("  Run Wall Time: %s", render_duration($wall_time))
            : ()),
        (defined $cum_job_time || $cpu_times)
        ? (
            "Aggregate Job Stats:",
            (defined $cum_job_time
                ? sprintf("    Cumulative Job Time: %s", render_duration($cum_job_time))
                : ()),
            ($cpu_times
                ? (
                    sprintf(
                        "               CPU Time: %s (usr: %s | sys: %s | cusr: %s | csys: %s)",
                        render_duration($cpu_total),
                        map { render_duration($_) } @{$cpu_times}[0 .. 3]
                    ),
                    sprintf("              CPU Usage: %i%%", $cpu_usage),
                )
                : ()
            ),
          )
        : (),
    );

    my $res = "    -->  Result: " . (defined($pass) ? $pass ? 'PASSED' : 'FAILED' : 'N/A') . "  <--";
    push @summary => $res;

    my $msg    = "Yath Result Summary";
    my $length = max map { length($_) } @summary;
    my $prefix = int(($length - length($msg)) / 2);

    print "\n";
    print " " x $prefix;
    print "$msg\n";
    print "-" x $length;
    print "\n";
    print join "\n" => @summary;
    print "\n";
}

sub write_summary_file {
    my $self = shift;
    my ($run_end) = @_;

    my $file = $self->{+FILE} or return;

    my $pass       = $run_end->{pass};
    my $pass_count = $run_end->{pass_count} // 0;
    my $fail_count = $run_end->{fail_count} // 0;

    my %data = (
        pass => $pass ? json_true : json_false,

        total_failures => $fail_count,
        total_tests    => $pass_count + $fail_count,

        failed => $self->{+_FAILED_JOBS},

        (defined $run_end->{wall_time}            ? (wall_time            => $run_end->{wall_time})            : ()),
        (defined $run_end->{cumulative_job_time}  ? (cumulative_job_time  => $run_end->{cumulative_job_time})  : ()),
        (defined $run_end->{cpu_total}            ? (cpu_total            => $run_end->{cpu_total})            : ()),
        (defined $run_end->{cpu_usage}            ? (cpu_usage            => $run_end->{cpu_usage})            : ()),
        (defined $run_end->{cpu_times}            ? (cpu_times            => $run_end->{cpu_times})            : ()),
    );

    require Test2::Harness2::Util::File::JSON;
    my $jfile = Test2::Harness2::Util::File::JSON->new(name => $file);
    $jfile->write(\%data);

    print "\nWrote summary file: $file\n\n";

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::Summary - FIXME

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


=pod

=cut POD NEEDS AUDIT

