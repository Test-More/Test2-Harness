package App::Yath::Command::speedtag;
use strict;
use warnings;

our $VERSION = '0.001100';

use Test2::Util qw/pkg_to_file/;
use Test2::Util::Times qw/render_duration/;

use Test2::Harness::Watcher::TimeTracker;
use Test2::Harness::Feeder::JSONL;
use Test2::Harness::Run;
use Test2::Harness;

use Term::Table;

use List::Util qw/min max/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/-max_short -max_medium/;

sub group { 'log' }

sub summary { "Tag tests with duration (short medium long) using a source log" }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2] max_short_duration_seconds max_medium_duration_seconds" }

sub description {
    return <<"    EOT";
This command will read the test durations from a log and tag/retag all tests
from the log based on the max durations for each type.
    EOT
}

sub has_runner  { 0 }
sub has_logger  { 0 }
sub has_display { 0 }
sub show_bench  { 0 }

sub handle_list_args {
    my $self = shift;
    my ($list) = @_;

    my $settings = $self->{+SETTINGS};

    my ($log, $max_short, $max_medium, @bad) = @$list;

    die "Too many arguments\n" if @bad;

    $self->{+MAX_SHORT}  = $max_short  || 15;
    $self->{+MAX_MEDIUM} = $max_medium || 30;

    $settings->{log_file} = $log;

    die "You must specify a log file.\n"
        unless $log;

    die "Invalid log file: '$log'"
        unless -f $log;
}

sub feeder {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $feeder = Test2::Harness::Feeder::JSONL->new(file => $settings->{log_file});

    return ($feeder);
}

sub run_command {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $feeder = $self->feeder;

    my %jobs;

    while (1) {
        my @events = $feeder->poll(1000) or last;
        for my $event (@events) {
            my $stamp  = $event->{stamp}      or next;
            my $job_id = $event->{job_id}     or next;
            my $f      = $event->{facet_data} or next;

            my $job = $jobs{$job_id} ||= {};
            $job->{file} //= File::Spec->abs2rel($f->{harness_job}->{file})    if $f->{harness_job}     && $f->{harness_job}->{file};
            $job->{time} //= $f->{harness_job_end}->{times}->{totals}->{total} if $f->{harness_job_end} && $f->{harness_job_end}->{times};

            next unless $job->{file} && $job->{time};
            delete $jobs{$job_id};

            my $dur;
            if ($job->{time} < $self->{+MAX_SHORT}) {
                $dur = 'short';
            }
            elsif ($job->{time} < $self->{+MAX_MEDIUM}) {
                $dur = 'medium';
            }
            else {
                $dur = 'long';
            }

            my $fh;
            unless (open($fh, '<', $job->{file})) {
                warn "Could not open file $job->{file} for reading\n";
                next;
            }

            my @lines;
            my $injected;
            for my $line (<$fh>) {
                if ($line =~ m/^(\s*)#(\s*)HARNESS-(CAT(EGORY)?|DUR(ATION))-(LONG|MEDIUM|SHORT)$/i) {
                    next if $injected++;
                    $line = "${1}#${2}HARNESS-DURATION-" . uc($dur) . "\n";
                }
                push @lines => $line;
            }
            unless ($injected) {
                my $new_line = "# HARNESS-DURATION-" . uc($dur) . "\n";
                my @header;
                while (@lines && $lines[0] =~ m/^(#|use\s|package\s)/) {
                    push @header => shift @lines;
                }

                unshift @lines => (@header, $new_line);
            }

            close($fh);
            unless (open($fh, '>', $job->{file})) {
                warn "Could not open file $job->{file} for writing\n";
                next;
            }

            print $fh @lines;
            close($fh);

            print "Tagged '$dur': $job->{file}\n";
        }
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::speedtag - Tag tests with proper duration tags based on a log

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 COMMAND LINE USAGE

B<THIS SECTION IS AUTO-GENERATED AT BUILD>

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
