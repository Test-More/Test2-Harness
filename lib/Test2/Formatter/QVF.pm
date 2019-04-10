package Test2::Formatter::QVF;
use strict;
use warnings;

our $VERSION = '0.001074';

BEGIN { require Test2::Formatter::Test2; our @ISA = qw(Test2::Formatter::Test2) }

use Test2::Util::HashBase qw{
    -job_buffers
};

sub init {
    my $self = shift;
    $self->SUPER::init();
    $self->{+VERBOSE} = 100;
}

sub write {
    my ($self, $e, $num, $f) = @_;
    $f ||= $e->facet_data;

    my $job_id = $f->{harness}->{job_id};

    push @{$self->{+JOB_BUFFERS}->{$job_id}} => [$e, $num, $f]
        if $job_id;

    my $show = $self->update_active_disp($f);

    if ($f->{harness_job_end} || !$job_id) {
        $show = 1;

        my $buffer = delete $self->{+JOB_BUFFERS}->{$job_id};

        if($f->{harness_job_end}->{fail}) {
            $self->SUPER::write(@{$_}) for @$buffer;
        }
        else {
            $self->SUPER::write($e, $num, $f)
        }
    }

    $self->{+ECOUNT}++;

    return unless $self->{+TTY};
    return unless $self->{+PROGRESS};

    $show ||= 1 unless $self->{+ECOUNT} % 10;

    if ($show) {
        # Local is expensive! Only do it if we really need to.
        local($\, $,) = (undef, '') if $\ || $,;

        my $io = $self->{+IO};
        if ($self->{+_BUFFERED}) {
            print $io "\r\e[K";
            $self->{+_BUFFERED} = 0;
        }

        print $io $self->render_ecount($f);
        $self->{+_BUFFERED} = 1;
    }

    return;
}

1;
