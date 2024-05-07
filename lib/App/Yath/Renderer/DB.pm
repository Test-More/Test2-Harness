package App::Yath::Renderer::DB;
use strict;
use warnings;

our $VERSION = '2.000000';

# This module does not directly use these, but the process it spawns does. Load
# them here anyway so that any errors can be reported before we fork.
use Getopt::Yath::Settings;
use App::Yath::Schema::RunProcessor;

use Atomic::Pipe;

use Time::HiRes qw/time/;

use Test2::Harness::Util qw/clean_path/;
use Test2::Harness::IPC::Util qw/start_process/;
use Test2::Harness::Util::JSON qw/encode_ascii_json/;
use App::Yath::Schema::UUID qw/gen_uuid/;

use parent 'App::Yath::Renderer';
use Test2::Harness::Util::HashBase qw{
    <pid
    <write_pipe
    <stopped

    +resource_interval
    +resources
    <last_resource_stamp
};

use Getopt::Yath;

include_options(
    'App::Yath::Options::Yath',
    'App::Yath::Options::DB',
    'App::Yath::Options::Upload',
    'App::Yath::Options::WebClient',
);

option_group {group => 'db', prefix => 'db', category => "Database Options"} => sub {
    option resources => (
        type => 'Auto',
        description => 'Send resource info (for supported resources) to the database at the specified interval in seconds (5 if not specified)',
        long_examples => ['', '=5'],
        autofill => 5,
    );
};

sub start {
    my $self = shift;

    my ($r, $w) = Atomic::Pipe->pair;

    $w->resize($w->max_size);
    $w->wh->autoflush(1);

    $self->{+WRITE_PIPE} = $w->wh;

    my %seen;
    $self->{+PID} = start_process(
        [
            $^X,                                                       # perl
            (map { ("-I$_") } grep { -d $_ && !$seen{$_}++ } @INC),    # Use the dev libs specified
            "-mApp::Yath::Schema::RunProcessor",                  # Load processor
            "-mGetopt::Yath::Settings",                                # Load settings lib
            '-e' => <<"            EOT",                               # Run it.
exit(
    App::Yath::Schema::RunProcessor->process_stdin(
        Getopt::Yath::Settings->FROM_JSON(\$ARGV[0])
    )
);
            EOT
            encode_ascii_json($self->{+SETTINGS}),                     # Pass settings in as arg
        ],
        sub {
            close(STDIN);
            open(STDIN, '<&', $r->rh) or die "Could not open STDIN to pipe: $!";
            $w->close;
        }
    );

    $r->close;

    return;
}

sub render_event {
    my $self = shift;
    my ($e) = @_;

    return if $self->{+STOPPED};

    my $spipe = 0;
    local $SIG{PIPE} = sub {
        warn "Caught SIGPIPE while writing to the database";
        $spipe++;
        $self->{+STOPPED} = 'SIGPIPE';
        close($self->{+WRITE_PIPE});
        $self->{+WRITE_PIPE} = undef;
    };

    my $ok = eval {
        print {$self->{+WRITE_PIPE}} encode_ascii_json($e), "\n";
        1;
    };

    die $@ unless $ok || $spipe;

    return;
}

sub step {
    my $self = shift;

    $self->send_resources();
}

sub signal {
    my $self = shift;
    my ($sig) = @_;

    return if $self->{+STOPPED};

    $self->_stop("SIG$SIG");
    $self->_close();

    kill($sig, $self->{+PID});

    $self->_wait();

    return $sig;
}

sub _stop {
    my $self = shift;
    my ($why) = @_;

    push @{$self->{+STOPPED} //= []} => $why;
}

sub _close {
    my $self = shift;

    my $p = delete $self->{+WRITE_PIPE} or return;
    close($p);
}

sub _wait {
    my $self = shift;

    my $pid = delete $self->{+PID} or return;
    waitpid($pid, 0);
}

sub finish {
    my $self = shift;

    $self->_stop('finish');
    $self->_close();
    $self->_wait();

    return;
}

sub resource_interval {
    my $self = shift;
    return $self->{+RESOURCE_INTERVAL} //= $self->settings->db->resources;
}

sub resources {
    my $self = shift;
    return $self->{+RESOURCES} if $self->{+RESOURCES};

    die "FIXME";

    my $state = $self->state;
    $state->poll;

    return $self->{+RESOURCES} = [grep { $_ && $_->can('status_data') } @{$state->resources}];
}

sub send_resources {
    my $self = shift;

    my $interval = $self->resource_interval or return;
    my $resources = $self->resources or return;
    return unless @$resources;

    my $stamp = time;

    if (my $last = $self->{+LAST_RESOURCE_STAMP}) {
        my $delta = $stamp - $last;
        return unless $delta >= $interval;
    }

    unless(eval { $self->_send_resources($stamp => $resources); 1 }) {
        my $err = $@;
        warn "Non fatal error, could not send resource info to YathUI: $err";
        return;
    }

    return $self->{+LAST_RESOURCE_STAMP} = $stamp;
}

sub _send_resources {
    my $self = shift;
    my ($stamp, $resources) = @_;

    my $batch_id = gen_uuid();
    my $ord = 0;
    my @items;
    for my $res (@$resources) {
        my $data = $res->status_data or next;

        my $item = {
            resource_id       => gen_uuid(),
            resource_batch_id => $batch_id,
            batch_ord         => $ord++,
            module            => ref($res) || $res,
            data              => encode_ascii_json($data),
        };

        push @items => $item;
    }

    return unless @items;

    $self->render_event({facet_data => {db_resources => {stamp => $stamp, batch_id => $batch_id, items => \@items}}});

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Renderer::DB - FIXME

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

