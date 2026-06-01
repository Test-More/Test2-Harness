package App::Yath2::Command::test;
use v5.38;

our $VERSION = '2.000000';

use Cwd ();
use File::Basename qw/basename/;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep time/;

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Util::Term qw/term_size/;

use Test2::Harness2;
use Test2::Harness2::Run;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::Zstd::FrameBuffer;
use Test2::Harness2::Util::JSON qw/decode_json/;

use App::Yath2::TestFile;
use App::Yath2::Renderer::Text::EventPainter;

use Object::HashBase qw{
    <args
    <app
    <verbose
    +svc_fh
    +svc_fb
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::test - Scan test files and run them through the harness.

=head1 DESCRIPTION

The C<test> command behaves much like the C<t2h2_run> development driver: it
starts a harness service, queues a run of the given test files, and streams each
job's state (and, with C<-v>, its events) as it happens.

The difference is the producer step: each file is scanned by
L<App::Yath2::TestFile> (shebang + C<HARNESS2:> directives) into a complete
L<Test2::Harness2::Run::Job>. The run is assembled here, serialized, and handed
to the harness as proper job specs rather than bare paths.

(The harness does not yet act on the scanned directives; that comes later. The
data rides along on each job in the meantime.)

=head1 SYNOPSIS

    yath test t/foo.t t/bar.t
    yath test -v  t/foo.t      # also paint each job's events
    yath test -vv t/foo.t      # also record/show stray events

=cut

sub init ($self) {
    $self->{+ARGS} //= [];
    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $exit = $cmd->run

Parse arguments, scan the files into a run, queue it, stream results, and return
a process exit code (0 = all jobs passed, 1 = a failure or usage error).

=back

=cut

sub run ($self) {
    my ($verbose, $files) = $self->_parse_argv;

    unless (@$files) {
        print STDERR "Usage: yath test [-v|-vv] TEST_FILE...\n";
        return 1;
    }

    $self->{+VERBOSE} = $verbose;

    my $run   = $self->_build_run($files);
    my $specs = [map { $_->TO_JSON } @{$run->jobs}];

    my $project = basename(Cwd::getcwd()) || 'run';

    my $h = Test2::Harness2->new(project => $project, workdir => tempdir(CLEANUP => 1));
    $h->start;

    my $mon = $h->subscribe;

    my $resp = $h->queue_run(
        run_uuid => $run->run_uuid,
        jobs     => $specs,
        stray    => $verbose >= 2 ? 1 : 0,
    );

    unless ($resp->{ok}) {
        print STDERR "Failed to queue run: " . ($resp->{error} // 'unknown error') . "\n";
        $h->shutdown;
        return 1;
    }

    $h->no_more_runs;

    return $self->_render_loop($h, $mon, $resp);
}

=head1 PRIVATE METHODS

=cut

=over 4

=item ($verbose, \@files) = $self->_parse_argv

Split the argument list into a verbosity count (C<-v> / C<-vv>) and the test
file paths.

=item $run = $self->_build_run(\@files)

Scan each file into a L<Test2::Harness2::Run::Job> and assemble a
L<Test2::Harness2::Run> with a fresh run identity.

=item $exit = $self->_render_loop($h, $mon, $resp)

Poll the monitor, print job state transitions (and paint events when verbose),
and return the aggregate pass/fail exit code.

=item $self->_tail_service_events($h)

Print newly captured lines from the service's own events file.

=item $name = $self->_job_name($mon, $uuid)

A short label for a job (its file name, falling back to the uuid).

=item $self->_paint_events($painter, $path, $width)

Paint every event in a finished job's events file.

=back

=cut

sub _parse_argv ($self) {
    my $verbose = 0;
    my @files;

    for my $arg (@{$self->{+ARGS}}) {
        if ($arg =~ /\A-(v+)\z/) {
            $verbose += length $1;
            next;
        }
        push @files, $arg;
    }

    return ($verbose, \@files);
}

sub _build_run ($self, $files) {
    # run_ord is provisional here; the harness assigns the authoritative one when
    # the run is queued.
    my $run = Test2::Harness2::Run->new(run_uuid => gen_uuid(), run_ord => 1);

    my $ord = 1;
    for my $file (@$files) {
        my $tf = App::Yath2::TestFile->new(file => $file);
        $run->add_job($tf->build_job(
            run_uuid => $run->run_uuid,
            run_ord  => $run->run_ord,
            job_uuid => gen_uuid(),
            job_ord  => $ord++,
        ));
    }

    return $run;
}

sub _render_loop ($self, $h, $mon, $resp) {
    my %want    = map { $_ => 1 } @{$resp->{job_uuids}};
    my $painter = App::Yath2::Renderer::Text::EventPainter->new(color => (-t STDOUT ? 1 : 0));
    my $width   = term_size() || 80;

    my $fail     = 0;
    my $deadline = time + 3600;

    while (keys %want && time < $deadline) {
        $h->poll_state;
        $self->_tail_service_events($h);

        say $self->_job_name($mon, $_) . ": starting"   for grep { $want{$_} } $mon->new_collectors;
        say $self->_job_name($mon, $_) . ": diagnosing" for grep { $want{$_} } $mon->new_diagnosing;
        say $self->_job_name($mon, $_) . ": failing"    for grep { $want{$_} } $mon->new_failing;
        say $self->_job_name($mon, $_) . ": completed"  for grep { $want{$_} } $mon->new_completed;

        for my $uuid ($mon->new_finalized) {
            next unless delete $want{$uuid};
            my $state = $mon->final_state($uuid);
            my $pass  = $state && $state->{pass};
            $fail ||= !$pass;
            say $self->_job_name($mon, $uuid) . ": " . ($pass ? 'PASS' : 'FAIL');

            $self->_paint_events($painter, $mon->events_file($uuid), $width) if $self->{+VERBOSE};
        }

        sleep 0.02;
    }

    $h->shutdown;
    $self->_tail_service_events($h);    # flush any remaining captured service output

    return $fail ? 1 : 0;
}

sub _tail_service_events ($self, $h) {
    my $path = $h->service_events_file;
    return unless defined $path;

    unless ($self->{+SVC_FH}) {
        return unless -e $path;
        open(my $fh, '<:raw', $path) or return;
        $self->{+SVC_FH} = $fh;
        $self->{+SVC_FB} = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    }

    while (1) {
        my $buf = '';
        my $n   = sysread($self->{+SVC_FH}, $buf, 65536);
        last unless $n;
        $self->{+SVC_FB}->push_bytes($buf);
    }

    for my $rec ($self->{+SVC_FB}->drain) {
        my $f = decode_json($rec->{payload})->{facet_data};
        for my $info (@{$f->{info} // []}) {
            my $text = $info->{details} // '';
            $text =~ s/\s+\z//;
            say "service: $text" if length $text;
        }
    }

    return;
}

sub _job_name ($self, $mon, $uuid) {
    my $c = $mon->collector($uuid) or return $uuid;
    return $c->{name} // $uuid;
}

sub _paint_events ($self, $painter, $path, $width) {
    return unless $path && -e $path;
    my $reader = open_zstd_reader($path);
    while (defined(my $line = $reader->readline)) {
        chomp $line;
        next unless length $line;
        say for $painter->paint(decode_json($line), tags => 1, left_pad => 2, max_width => $width);
    }
    return;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
