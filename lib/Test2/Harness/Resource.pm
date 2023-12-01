package Test2::Harness::Resource;
use strict;
use warnings;

use Carp qw/croak/;

use Term::Table;

use Test2::Util::Times qw/render_duration/;

use Test2::Harness::Util qw/parse_exit/;
use Test2::Harness::IPC::Util qw/start_collected_process ipc_connect/;
use Test2::Harness::Util::JSON qw/decode_json encode_json/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util::HashBase qw{
    <is_subprocess
    <subprocess_pid
    <resource_id
};

sub init {
    my $self = shift;
    $self->{+RESOURCE_ID} //= gen_uuid();
}

sub spawns_process { 0 }
sub is_job_limiter { 0 }

sub setup   { }
sub tick    { }
sub cleanup { }

sub subprocess_args { () }

sub resource_name { 'Resource' }
sub resource_io_tag { 'RESOURCE' }

sub applicable     { croak "'$_[0]' does not implement 'applicable'" }
sub available      { croak "'$_[0]' does not implement 'available'" }
sub assign         { croak "'$_[0]' does not implement 'assign'" }
sub release        { croak "'$_[0]' does not implement 'release'" }
sub subprocess_run { croak "'$_[0]' does not implement 'subprocess_run'" }

sub sort_weight {
    my $class = shift;
    return 100 if $class->is_job_limiter;
    return 50;
}

sub subprocess_exited {
    my $self = shift;
    my %params = @_;

    my $pid       = $params{pid};
    my $exit      = $params{exit};
    my $scheduler = $params{scheduler};

    my $x = parse_exit($exit);

    warn "'$self' sub-process '$pid' exited (Code: $x->{err}, Signal: $x->{sig})"
        if $exit;
}

sub spawn_class {
    my $self = shift;
    return ref($self) || $self;
}

sub spawn_command {
    my $self   = shift;
    my %params = @_;

    my $class    = $self->spawn_class;
    my $instance = $params{instance};

    my %seen;
    return (
        $^X,                                                       # Call current perl
        (map { ("-I$_") } grep { -d $_ && !$seen{$_}++ } @INC),    # Use the dev libs specified
        "-m$class",                                                # Load Resource
        '-e' => "exit($class->_subprocess_run(\$ARGV[0]))",        # Run it.
        encode_json({parent_pid => $$, $self->subprocess_args}),        # json data
    );
}

sub spawn_process {
    my $self = shift;
    my %params = @_;

    my $scheduler = $params{scheduler} or die "'scheduler' is required";

    my @spawn_cmd = $self->spawn_command(%params);

    my $pid = start_collected_process(
        instance_ipc => $params{instance_ipc},
        io_pipes     => $ENV{T2_HARNESS_PIPE_COUNT},
        command      => \@spawn_cmd,
        root_pid     => $$,
        type         => 'resource',
        name         => $self->resourse_name,
        tag          => $self->resource_io_tag,
        setsid       => 0,
        forward_exit => 1,
    );

    $scheduler->register_child($pid => sub { $self->subprocess_exited(@_) });

    return $pid;
}

sub _subprocess_run {
    my $class = shift;
    my ($json) = @_;

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    my $params = decode_json($json);

    $0 = "yath-resource-" . $class->resourse_name(%$params);

    $class->subprocess_run(%$params);

    exit 0;
}

sub status_data { () }

sub status_lines {
    my $self = shift;

    my $data = $self->status_data || return;
    return unless @$data;

    my $out = "";

    for my $group (@$data) {
        my $gout = "\n";
        $gout .= "**** $group->{title} ****\n\n" if defined $group->{title};

        for my $table (@{$group->{tables} || []}) {
            my $rows = $table->{rows};

            if (my $format = $table->{format}) {
                my $rows2 = [];

                for my $row (@$rows) {
                    my $row2 = [];
                    for (my $i = 0; $i < @$row; $i++) {
                        my $val = $row->[$i];
                        my $fmt = $format->[$i];

                        $val = defined($val) ? render_duration($val) : '--'
                            if $fmt && $fmt eq 'duration';

                        push @$row2 => $val;
                    }
                    push @$rows2 => $row2;
                }

                $rows = $rows2;
            }

            next unless $rows && @$rows;

            my $tt = Term::Table->new(
                header => $table->{header},
                rows   => $rows,

                sanitize     => 1,
                collapse     => 1,
                auto_columns => 1,

                %{$table->{term_table_opts} || {}},
            );

            $gout .= "** $table->{title} **\n" if defined $table->{title};
            $gout .= "$_\n" for $tt->render;
            $gout .= "\n";
        }

        if ($group->{lines} && @{$group->{lines}}) {
            $gout .= "$_\n" for @{$group->{lines}};
            $gout .= "\n";
        }

        $out .= $gout;
    }

    return $out;
}

1;
