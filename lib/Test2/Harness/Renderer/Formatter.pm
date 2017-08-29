package Test2::Harness::Renderer::Formatter;
use strict;
use warnings;

our $VERSION = '0.001001';

use Carp qw/croak/;

use Test2::Harness::Util::JSON qw/encode_pretty_json/;

BEGIN { require Test2::Harness::Renderer; our @ISA = ('Test2::Harness::Renderer') }
use Test2::Harness::Util::HashBase qw{
    -formatter
    -show_run_info
    -show_job_info
    -show_job_launch
    -show_job_end
};

sub init {
    my $self = shift;

    croak "The 'formatter' attribute is required"
        unless $self->{+FORMATTER};

    $self->{+SHOW_JOB_END} = 1 unless defined $self->{+SHOW_JOB_END};
}

sub render_event {
    my $self = shift;
    my ($event) = @_;

    my $f = $event->{facet_data};

    $f->{harness} = {%$event};
    delete $f->{harness}->{facet_data};

    if ($self->{+SHOW_RUN_INFO} && $f->{harness_run}) {
        my $run = $f->{harness_run};

        push @{$f->{info}} => {
            tag       => 'RUN INFO',
            details   => encode_pretty_json($run),
        };
    }

    if ($f->{harness_job_launch}) {
        my $job = $f->{harness_job};

        $f->{harness}->{job_id} ||= $job->{job_id};

        if ($self->{+SHOW_JOB_LAUNCH}) {
            push @{$f->{info}} => {
                tag       => 'LAUNCH',
                debug     => 0,
                important => 1,
                details   => $job->file,
            };
        }

        if ($self->{+SHOW_JOB_INFO}) {
            push @{$f->{info}} => {
                tag     => 'JOB INFO',
                details => encode_pretty_json($job),
            };
        }
    }

    if ($f->{harness_job_end}) {
        my $job  = $f->{harness_job};
        my $skip = $f->{harness_job_end}->{skip};
        my $fail = $f->{harness_job_end}->{fail};
        my $file = $f->{harness_job_end}->{file};

        $f->{harness}->{job_id} ||= $job->{job_id};

        if ($self->{+SHOW_JOB_END}) {
            unshift @{$f->{info}} => {
                tag => $skip ? 'SKIPPED' : $fail ? 'FAILED' : 'PASSED',
                debug     => $fail,
                important => 1,
                details   => $file,
            };
            push @{$f->{info}} => {
                tag       => 'SKIPPED',
                debug     => 0,
                important => 1,
                details   => $skip,
            } if $skip;
        }
    }

    my $num = $f->{assert} && $f->{assert}->{number} ? $f->{assert}->{number} : undef;

    $self->{+FORMATTER}->write($event, $num, $f);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Renderer::Formatter - Renderer that uses any Test2::Formatter
for rendering.

=head1 DESCRIPTION

=back

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
