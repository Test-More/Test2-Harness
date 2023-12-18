package App::Yath::Renderer;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness::Util::HashBase qw{
    <color
    <hide_runner_output
    <progress
    <quiet
    <show_times
    <term_width
    <truncate_runner_output
    <verbose
    <wrap
    <interactive
    <is_persistent
    <show_job_end
    <show_job_info
    <show_job_launch
    <show_run_info
    <show_run_fields
    <settings
};

sub init {
    my $self = shift;

    croak "'settings' is required" unless $self->{+SETTINGS};
}

sub render_event { croak "$_[0] forgot to override 'render_event()'" }

sub start  { }
sub step   { }
sub signal { }
sub finish { }

sub weight { 0 }

1;
