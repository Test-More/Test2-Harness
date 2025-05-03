package App::Yath::Renderer::Formatter;
use strict;
use warnings;

our $VERSION = '2.000005';

use Test2::Harness::Util::JSON qw/encode_pretty_json/;
use Test2::Harness::Util qw/mod2file fqmod/;
use Storable qw/dclone/;

use Getopt::Yath;

option_group {group => 'formatter', category => "Formatter Options"} => sub {
    option formatter => (
        type => 'Scalar',
        default     => 'Test2::Formatter::TAP',
        normalize   => sub { fqmod($_[0], 'Test2::Formatter') },
        description => "The Test2::Formatter to use",
    );
};

use parent 'App::Yath::Renderer';
use Test2::Harness::Util::HashBase qw{
    <formatter
    <io <io_err
    <do_step
};

sub step {
    my $self = shift;
    return unless $self->{+DO_STEP};
    $self->{+FORMATTER}->step;
}

sub finish {
    my $self = shift;

    $self->{+FORMATTER}->finalize();

    $self->SUPER::finish(@_);
}

sub init {
    my $self = shift;

    $self->SUPER::init();

    my $f_class = $self->formatter // $self->settings->formatter->formatter // 'Test2::Formatter::Test2';
    die "Invalid formatter class: $f_class" if ref($f_class);

    my $f_file = mod2file($f_class);
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

    $self->{+INTERACTIVE} //= 1 if $ENV{YATH_INTERACTIVE};

    $self->{+FORMATTER} = $f_class->new(
        io            => $io,
        handles       => [$io, $io_err, $io],
        color         => $self->color,
        interactive   => $self->interactive,
        is_persistent => $self->is_persistent,
        no_wrap       => $self->wrap ? 0 : 1,
        progress      => $self->progress,
        verbose       => $self->verbose,
        quiet         => $self->quiet,
        theme         => $self->theme,
    );

    $self->{+DO_STEP} = $self->{+FORMATTER}->can('step') ? 1 : 0;

    $self->{+SHOW_JOB_END} = 1 unless defined $self->{+SHOW_JOB_END};
}

sub render_event {
    my $self = shift;
    my ($event) = @_;

    # We modify the event, which would be bad if there were multiple renderers,
    # so we deep clone it.
    $event = dclone($event);

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

    if ($self->{+SHOW_RUN_FIELDS}) {
        if (my $fields = $f->{harness_run_fields}) {
            for my $field (@$fields) {
                push @{$f->{info}} => {
                    tag     => 'RUN  FLD',
                    details => encode_pretty_json($field),
                };
            }
        }
    }

    if ($f->{harness_job_launch}) {
        my $job = $f->{harness_job};

        $f->{harness}->{job_id} ||= $job->{job_id};

        if ($self->{+SHOW_JOB_LAUNCH}) {
            push @{$f->{info}} => {
                tag       => $f->{harness_job_launch}->{retry} ? 'RETRY' : 'LAUNCH',
                debug     => 0,
                important => 1,
                details   => File::Spec->abs2rel($job->{test_file}->{file}),
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
        if ($self->show_times && $f->{info}) {
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

    $self->render_final_data($f->{final_data}) if $f->{final_data};
}

sub TO_JSON {
    my $self = shift;

    my $data = $self->SUPER::TO_JSON();
    delete $data->{+FORMATTER};

    return $data;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Renderer::Formatter - FIXME

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

