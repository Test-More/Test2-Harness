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
use Test2::Harness::Util::JSON qw/encode_ascii_json_file encode_ascii_json/;
use Test2::Util::UUID qw/gen_uuid/;

use parent 'App::Yath::Renderer';
use Test2::Harness::Util::HashBase qw{
    <pid
    <write_pipe
    <stopped
};

use Getopt::Yath;

include_options(
    'App::Yath::Options::Yath',
    'App::Yath::Options::DB',
    'App::Yath::Options::Publish',
    'App::Yath::Options::WebClient' => [qw/url/],
);

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
            "-mApp::Yath::Schema::RunProcessor",                       # Load processor
            "-mGetopt::Yath::Settings",                                # Load settings lib
            '-e' => <<"            EOT",                               # Run it.
exit(
    App::Yath::Schema::RunProcessor->process_stdin(
        Getopt::Yath::Settings->FROM_JSON_FILE(\$ARGV[0], unlink => 1)
    )
);
            EOT
            encode_ascii_json_file($self->{+SETTINGS}),                # Pass settings in as arg
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
        $self->{+STOPPED} = ['SIGPIPE'];
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

