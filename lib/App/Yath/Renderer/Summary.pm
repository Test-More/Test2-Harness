package App::Yath::Renderer::Summary;
use strict;
use warnings;

use Test2::Util::Table qw/table/;
use Getopt::Yath::Term qw/USE_COLOR/;
use Test2::Harness::Util qw/clean_path/;
use Test2::Harness::Util::JSON qw/json_true json_false/;

use List::Util qw/max/;

our $VERSION = '2.000005';

use parent 'App::Yath::Renderer';
use Test2::Harness::Util::HashBase qw{
    <file
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

sub args_from_settings {
    my $class = shift;
    my %params = @_;
    return $params{settings}->summary->all;
}

sub weight { -99 }

sub exit_hook {
    my $self = shift;
    my ($auditor) = @_;

    my $final_data = $auditor->final_data;
    my $summary    = $auditor->summary;

    $self->render_final_data($final_data);
    $self->render_summary($summary);
    $self->write_summary_file($summary, $final_data);
}

sub render_event {}

sub render_summary {
    my $self = shift;
    my ($summary) = @_;

    my $pass         = $summary->{pass};
    my $time_data    = $summary->{time_data};
    my $cpu_usage    = $summary->{cpu_usage};
    my $failures     = $summary->{failures};
    my $tests_seen   = $summary->{tests_seen};
    my $asserts_seen = $summary->{asserts_seen};

    return if $self->quiet > 1;

    my @summary = (
        $failures ? ("     Fail Count: $failures") : (),
        "     File Count: $tests_seen",
        "Assertion Count: $asserts_seen",
        $time_data
        ? (
            sprintf("      Wall Time: %.2f seconds",                                                       $time_data->{wall}),
            sprintf("       CPU Time: %.2f seconds (usr: %.2fs | sys: %.2fs | cusr: %.2fs | csys: %.2fs)", @{$time_data}{qw/cpu user system cuser csystem/}),
            sprintf("      CPU Usage: %i%%",                                                               $cpu_usage),
            )
        : (),
    );

    my $res = "    -->  Result: " . (defined($pass) ? $pass ? 'PASSED' : 'FAILED' : 'N/A') . "  <--";
    if ($self->color && USE_COLOR) {
        my $color = $self->theme->get_term_color(tag => defined($pass) ? $pass ? 'passed' : 'failed' : 'skipped');
        my $reset = $self->theme->get_term_color('reset');
        $res = "$color$res$reset";
    }
    push @summary => $res;

    my $msg    = "Yath Result Summary";
    my $length = max map { length($_) } @summary;
    my $prefix = ($length - length($msg)) / 2;

    print "\n";
    print " " x $prefix;
    print "$msg\n";
    print "-" x $length;
    print "\n";
    print join "\n" => @summary;
    print "\n";
}

sub render_final_data {
    my $self = shift;
    my ($final_data) = @_;

    return if $self->quiet > 1;

    if (my $rows = $final_data->{retried}) {
        print "\nThe following jobs failed at least once:\n";
        print join "\n" => table(
            header => ['Job ID', 'Times Run', 'Test File', "Succeeded Eventually?"],
            rows   => [sort { $a->[2] cmp $b->[2] } @$rows],
        );
        print "\n";
    }

    if (my $rows = $final_data->{failed}) {
        print "\nThe following jobs failed:\n";
        print join "\n" => table(
            collapse => 1,
            header   => ['Job ID', 'Test File', 'Subtests'],
            rows     => [map { my $r = [@{$_}]; $r->[2] = join("\n", @{$r->[2]}) if $r->[2]; $r } sort { $a->[1] cmp $b->[1] } @$rows],
        );
        print "\n";
    }

    if (my $rows = $final_data->{halted}) {
        print "\nThe following jobs requested all testing be halted:\n";
        print join "\n" => table(
            header => ['Job ID', 'Test File', "Reason"],
            rows   => [sort { $a->[1] cmp $b->[1] } @$rows],
        );
        print "\n";
    }

    if (my $rows = $final_data->{unseen}) {
        print "\nThe following jobs never ran:\n";
        print join "\n" => table(
            header => ['Job ID', 'Test File'],
            rows   => [sort { $a->[1] cmp $b->[1] } @$rows],
        );
        print "\n";
    }
}

sub write_summary_file {
    my $self = shift;
    my ($summary, $final_data) = @_;

    my $file = $self->{+FILE} or return;

    my $pass         = $summary->{pass};
    my $time_data    = $summary->{time_data};
    my $cpu_usage    = $summary->{cpu_usage};
    my $failures     = $summary->{failures};
    my $tests_seen   = $summary->{tests_seen};
    my $asserts_seen = $summary->{asserts_seen};

    my %data = (
        %$final_data,

        pass => $pass ? json_true : json_false,

        total_failures => $failures     // 0,
        total_tests    => $tests_seen   // 0,
        total_asserts  => $asserts_seen // 0,

        cpu_usage => $cpu_usage,

        times => $time_data,
    );

    require Test2::Harness::Util::File::JSON;
    my $jfile = Test2::Harness::Util::File::JSON->new(name => $file);
    $jfile->write(\%data);

    print "\nWrote summary file: $file\n\n";

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Renderer::Summary - FIXME

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

