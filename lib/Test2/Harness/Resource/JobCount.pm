package Test2::Harness::Resource::JobCount;
use strict;
use warnings;

use Carp qw/croak/;
use List::Util qw/max min/;

use parent 'Test2::Harness::Resource';
use Test2::Harness::Util::HashBase qw{
    <slots
    <job_slots

    <used
    <assignments
};

sub is_job_limiter { 1 }

sub resource_name   { 'jobcount' }
sub resource_io_tag { 'JOBCOUNT' }

sub init {
    my $self = shift;
    $self->SUPER::init();

    die "'slots' is a require attribute and must be set higher to 0"     unless $self->{+SLOTS};
    die "'job_slots' is a require attribute and must be set higher to 0" unless $self->{+JOB_SLOTS};

    $self->{+USED} = 0;
    $self->{+ASSIGNMENTS} = {};
}

# Always applicable
sub applicable { 1 }

sub available {
    my $self = shift;
    my ($id, $job) = @_;

    my $run_count = $self->{+JOB_SLOTS};
    my $min_slots = $job->test_file->check_min_slots // 1;
    my $max_slots = $job->test_file->check_max_slots // $min_slots;

    return -1 if $run_count < $min_slots;
    return -1 if $self->{+SLOTS} < $min_slots;

    my $free = $self->{+SLOTS} - $self->{+USED};
    return 0 if $free < 1;
    return 0 if $free < $min_slots;

    return min($max_slots, $free);
}

sub assign {
    my $self = shift;
    my ($id, $job, $env) = @_;

    croak "'env' hash was not provided" unless $env;

    my $count = $self->available($id, $job);

    $self->{+USED} += $count;
    $self->{+ASSIGNMENTS}->{$id} = {
        job   => $job,
        count => $count,
    };

    $env->{T2_HARNESS_MY_JOB_CONCURRENCY} = $count;

    return $env;
}

sub release {
    my $self = shift;
    my ($id, $job) = @_;

    my $assign = delete $self->{+ASSIGNMENTS}->{$id} or die "Invalid release ID: $id";
    my $count = $assign->{count};

    $self->{+USED} -= $count;

    return $id;
}

sub status_data { () }

sub status_lines {
#    my $self = shift;
#
#    my $data = $self->status_data || return;
#    return unless @$data;
#
#    my $out = "";
#
#    for my $group (@$data) {
#        my $gout = "\n";
#        $gout .= "**** $group->{title} ****\n\n" if defined $group->{title};
#
#        for my $table (@{$group->{tables} || []}) {
#            my $rows = $table->{rows};
#
#            if (my $format = $table->{format}) {
#                my $rows2 = [];
#
#                for my $row (@$rows) {
#                    my $row2 = [];
#                    for (my $i = 0; $i < @$row; $i++) {
#                        my $val = $row->[$i];
#                        my $fmt = $format->[$i];
#
#                        $val = defined($val) ? render_duration($val) : '--'
#                            if $fmt && $fmt eq 'duration';
#
#                        push @$row2 => $val;
#                    }
#                    push @$rows2 => $row2;
#                }
#
#                $rows = $rows2;
#            }
#
#            next unless $rows && @$rows;
#
#            my $tt = Term::Table->new(
#                header => $table->{header},
#                rows   => $rows,
#
#                sanitize     => 1,
#                collapse     => 1,
#                auto_columns => 1,
#
#                %{$table->{term_table_opts} || {}},
#            );
#
#            $gout .= "** $table->{title} **\n" if defined $table->{title};
#            $gout .= "$_\n" for $tt->render;
#            $gout .= "\n";
#        }
#
#        if ($group->{lines} && @{$group->{lines}}) {
#            $gout .= "$_\n" for @{$group->{lines}};
#            $gout .= "\n";
#        }
#
#        $out .= $gout;
#    }
#
#    return $out;
}

1;
