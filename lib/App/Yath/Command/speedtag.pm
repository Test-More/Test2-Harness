package App::Yath::Command::speedtag;
use strict;
use warnings;

our $VERSION = '0.001100';

use Test2::Harness::Util::File::JSONL;

use App::Yath::Options;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/-log_file -max_short -max_medium/;

include_options(
    'App::Yath::Options::Debug',
);

sub group { 'log' }

sub summary { "Tag tests with duration (short medium long) using a source log" }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2] max_short_duration_seconds max_medium_duration_seconds" }

sub description {
    return <<"    EOT";
This command will read the test durations from a log and tag/retag all tests
from the log based on the max durations for each type.
    EOT
}

sub init {
    my $self = shift;

    $self->{+MAX_SHORT}  //= 15;
    $self->{+MAX_MEDIUM} //= 30;
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $args     = $self->args;

    shift @$args if @$args && $args->[0] eq '--';

    $self->{+LOG_FILE} = shift @$args or die "You must specify a log file";
    die "'$self->{+LOG_FILE}' is not a valid log file" unless -f $self->{+LOG_FILE};
    die "'$self->{+LOG_FILE}' does not look like a log file" unless $self->{+LOG_FILE} =~ m/\.jsonl(\.(gz|bz2))?$/;

    $self->{+MAX_SHORT}  = shift @$args if @$args;
    $self->{+MAX_MEDIUM} = shift @$args if @$args;

    die "max short duration must be an integer, got '$self->{+MAX_SHORT}'"  unless $self->{+MAX_SHORT}  && $self->{+MAX_SHORT} =~ m/^\d+$/;
    die "max short duration must be an integer, got '$self->{+MAX_MEDIUM}'" unless $self->{+MAX_MEDIUM} && $self->{+MAX_MEDIUM} =~ m/^\d+$/;

    my $stream = Test2::Harness::Util::File::JSONL->new(name => $self->{+LOG_FILE});

    while(1) {
        my @events = $stream->poll(max => 1000) or last;

        for my $event (@events) {
            my $stamp  = $event->{stamp}      or next;
            my $job_id = $event->{job_id}     or next;
            my $f      = $event->{facet_data} or next;

            next unless $f->{harness_job_end};

            my $job = {};
            $job->{file} = $f->{harness_job_end}->{rel_file} if $f->{harness_job_end} && $f->{harness_job_end}->{rel_file};
            $job->{time} = $f->{harness_job_end}->{times}->{totals}->{total} if $f->{harness_job_end} && $f->{harness_job_end}->{times};

            next unless $job->{file} && $job->{time};

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
