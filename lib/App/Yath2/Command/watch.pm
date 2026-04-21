package App::Yath2::Command::watch;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/tinysleep load_module/;

use App::Yath2::Daemon;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Renderer',
);

use Object::HashBase qw{
    <script
    <config
    <user_config
};

sub argv { $_[0]->{argv} }

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

sub _parse_argv {
    my ($argv) = @_;
    return parse_options($argv, skip_non_opts => 1, stops => ['--']);
}

# `yath watch`: attach to a running daemon and follow an existing
# run through the artifact-reading layer. Unlike `yath run`, this
# command does not queue a new run; it takes a run_id (or picks the
# most recent known run) and re-plays events from that run's
# artifacts as the run progresses.
sub run {
    my $self = shift;

    my $parsed = eval { _parse_argv([@{$self->argv}]) };
    unless (defined $parsed) {
        print STDERR "yath watch: option parse failed: $@\n";
        return 2;
    }

    my @positional = @{$parsed->{skipped} // []};
    push @positional => @{$parsed->{remains}} if $parsed->{remains};

    my ($daemon_workdir, $run_id);
    my @leftover;
    for my $a (@positional) {
        if    ($a =~ /^--daemon-workdir=(.*)$/) { $daemon_workdir = $1 }
        elsif ($a =~ /^--run-id=(.*)$/)         { $run_id         = $1 }
        else                                    { push @leftover => $a }
    }

    # A single leftover positional is taken as the run_id.
    if (!defined $run_id && @leftover == 1) {
        $run_id = shift @leftover;
    }
    if (@leftover) {
        print STDERR "yath watch: unexpected positional argument(s): @leftover\n";
        return 2;
    }

    my $settings = $parsed->{settings};
    my $mode = _resolve_mode($settings);

    my $spawn = eval { App::Yath2::Daemon::attach(daemon_workdir => $daemon_workdir) };
    unless ($spawn) {
        print STDERR "yath watch: cannot attach to daemon: $@";
        return 2;
    }

    # When no run_id is supplied, pick the single run the daemon
    # knows about; error cleanly if the daemon has zero or many.
    unless (defined $run_id) {
        my $status = eval { $spawn->status };
        my $queue  = ref($status) eq 'HASH' ? ($status->{queue} // []) : [];
        if (@$queue == 1) {
            $run_id = $queue->[0]->{run_id};
        }
        elsif (!@$queue) {
            print STDERR "yath watch: the daemon has no active runs; pass --run-id=ID to follow a completed run\n";
            return 2;
        }
        else {
            print STDERR "yath watch: multiple active runs; pass --run-id=ID to pick one:\n";
            print STDERR "  $_->{run_id}\n" for @$queue;
            return 2;
        }
    }

    my $renderers = eval { _load_renderers($settings) };
    unless (defined $renderers) {
        print STDERR "yath watch: renderer load failed: $@\n";
        return 2;
    }

    # If no renderers were picked by the settings layer, install the
    # Default terminal renderer so `yath watch` produces something
    # visible by default.
    unless (@$renderers) {
        require App::Yath2::Renderer::Default;
        push @$renderers => App::Yath2::Renderer::Default->new;
    }

    require App::Yath2::ArtifactReader;
    my $layer = App::Yath2::ArtifactReader->new(
        spawn     => $spawn,
        run_id    => $run_id,
        renderers => $renderers,
        mode      => $mode,
    );
    my $final = $layer->run;

    my $pass = $final->{pass_count} // 0;
    my $fail = $final->{fail_count} // 0;

    print STDOUT "yath watch: run=$run_id pass=$pass fail=$fail\n";

    return $fail ? 1 : 0;
}

sub _resolve_mode {
    my ($settings) = @_;
    my $rs = eval { $settings->renderer };
    return 'default' unless defined $rs;

    my $qvf     = eval { $rs->qvf };
    my $quiet   = eval { $rs->quiet };
    my $verbose = eval { $rs->verbose };

    return 'qvf'     if $qvf;
    return 'quiet'   if $quiet  && !$verbose;
    return 'verbose' if $verbose;
    return 'default';
}

sub _load_renderers {
    my ($settings) = @_;

    my $rs = eval { $settings->renderer };
    return [] unless defined $rs;

    my $classes = eval { $rs->classes };
    $classes = {} unless ref($classes) eq 'HASH';

    my @out;
    for my $class (sort keys %$classes) {
        my $args = $classes->{$class} // [];
        $args = [] unless ref($args) eq 'ARRAY';

        my $ok = eval { load_module($class); 1 };
        my $err = $@;
        die "renderer class '$class' failed to load: $err" unless $ok;

        my %h = @$args % 2 == 0 ? @$args : map { $_ => 1 } @$args;
        push @out => $class->new(%h);
    }

    return \@out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::watch - Follow a run on an attached daemon.

=head1 SYNOPSIS

    yath watch
    yath watch --run-id=abcd1234
    yath watch -v

=head1 DESCRIPTION

Attaches to a running daemon and drives the artifact-reading layer
against an existing run (picked from the daemon's queue, or
identified explicitly via C<--run-id=ID>). Renderers are loaded from
the standard C<Renderer> options; if none are configured the
Default terminal renderer is installed so C<yath watch> produces
visible output by default.

Exits 0 on all-pass; 1 on any failure; 2 on usage / attach error.

=cut
