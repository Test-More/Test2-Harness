package Test2::Harness::Renderer::Formatter;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp qw/croak/;

use File::Spec;

use Storable qw/dclone/;

use Test2::Harness::Util qw/fqmod mod2file/;
use Test2::Harness::Util::JSON qw/encode_pretty_json/;

BEGIN { require Test2::Harness::Renderer; our @ISA = ('Test2::Harness::Renderer') }
use Test2::Harness::Util::HashBase qw{
    -io -io_err
    -formatter
    -show_run_info
    -show_job_info
    -show_job_launch
    -show_job_end
    -do_step
    -interactive
};

sub init {
    my $self = shift;

    my $settings = $self->{+SETTINGS};

    my $formatter = $self->{+FORMATTER} //= 'Test2';
    my $f_class   = fqmod('Test2::Formatter', $formatter);
    my $f_file    = mod2file($f_class);
    require $f_file;

    my $io = $self->{+IO} || $self->{output} || \*STDOUT;
    unless (ref $io) {
        open(my $fh, '>', $io) or die "Could not open file '$io' for writing: $!";
        $self->{+IO} = $fh;
    }

    my $io_err = $self->{+IO_ERR} || $self->{output} || \*STDERR;
    unless (ref $io_err) {
        open(my $fh, '>', $io_err) or die "Could not open file '$io_err' for writing: $!";
        $self->{+IO_ERR} = $fh;
    }

    $self->{+INTERACTIVE} = 1 if $settings->debug->interactive;
    $self->{+INTERACTIVE} //= 1 if $ENV{YATH_INTERACTIVE};

    $self->{+FORMATTER} = $f_class->new(
        io            => $self->{+IO},
        progress      => $self->{+PROGRESS},
        handles       => [$self->{+IO}, $self->{+IO_ERR}, $self->{+IO}],
        verbose       => $settings->display->verbose,
        color         => $settings->display->color,
        no_wrap       => $settings->display->no_wrap,
        interactive   => $self->{+INTERACTIVE},
        is_persistent => $self->{+COMMAND_CLASS}->group eq 'persist' ? 1 : 0,
    );

    $self->{+DO_STEP} = $self->{+FORMATTER}->can('step') ? 1 : 0;

    $self->{+SHOW_JOB_END} = 1 unless defined $self->{+SHOW_JOB_END};
}

sub step {
    my $self = shift;
    return unless $self->{+DO_STEP};
    $self->{+FORMATTER}->step;
}

sub render_event {
    my $self = shift;
    my ($event) = @_;

    # We modify the event, which would be bad if there were multiple renderers,
    # so we deep clone it.
    $event = dclone($event);

    my $settings = $self->{+SETTINGS};

    my $f = $event->{facet_data}; # Optimization

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
                tag       => $f->{harness_job_launch}->{retry} ? 'RETRY' : 'LAUNCH',
                debug     => 0,
                important => 1,
                details   => File::Spec->abs2rel($job->{file}),
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
        my $retry = $f->{harness_job_end}->{retry};

        my $job_id = $f->{harness}->{job_id} ||= $job->{job_id};

        # Make the times important if they were requested
        if ($settings->display->show_times && $f->{info}) {
            for my $info (@{$f->{info}}) {
                next unless $info->{tag} eq 'TIME';
                $info->{important} = 1;
            }
        }

        if ($self->{+SHOW_JOB_END}) {
            my $name = File::Spec->abs2rel($file);
            $name .= "  -  $skip" if $skip;

            my $tag = 'PASSED';
            $tag = 'SKIPPED'  if $skip;
            $tag = 'FAILED'   if $fail;
            $tag = 'TO RETRY' if $retry;

            unshift @{$f->{info}} => {
                tag       => $tag,
                debug     => $fail,
                important => 1,
                details   => $name,
            };
        }
    }

    my $num = $f->{assert} && $f->{assert}->{number} ? $f->{assert}->{number} : undef;

    $self->{+FORMATTER}->write($event, $num, $f);
}

sub finish {
    my $self = shift;
    $self->{+FORMATTER}->finalize();
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Renderer::Formatter - Renderer that uses any Test2::Formatter
for rendering.

=head1 DESCRIPTION

This renderer simply acts as a communication layer between the harness and any
Test2 formatter that you wish to use to display results. Not all formatters
will produce useful output for harness events.

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
