package Test2::Harness::Job::Dir;
use strict;
use warnings;

our $VERSION = '0.001070';

use File::Spec();

use Carp qw/croak/;
use Time::HiRes qw/time/;
use List::Util qw/first/;
use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::Util qw/maybe_read_file open_file/;

use Test2::Harness::Event;

use Test2::Harness::Util::File::Stream;
use Test2::Harness::Util::File::JSONL;
use Test2::Harness::Util::File::Value;

use Test2::Harness::Util::TapParser qw{
    parse_stdout_tap
    parse_stderr_tap
};

use Test2::Harness::Util::HashBase qw{
    -run_id -job_id -job_root
    -events_file -_events_buffer -_events_index
    -stderr_file -_stderr_buffer -_stderr_index -_stderr_id
    -stdout_file -_stdout_buffer -_stdout_index -_stdout_id
    -start_file  -start_exists   -_start_buffer
    -exit_file   -_exit_done     -_exit_buffer

    -_file -file_file

    runner_exited
};

sub init {
    my $self = shift;

    croak "'run_id' is a required attribute"
        unless $self->{+RUN_ID};

    croak "'job_id' is a required attribute"
        unless $self->{+JOB_ID};

    croak "'job_root' is a required attribute"
        unless $self->{+JOB_ROOT};

    $self->{+_EVENTS_INDEX} = 0;
    $self->{+_STDOUT_INDEX} = 0;
    $self->{+_STDERR_INDEX} = 0;
    $self->{+_STDOUT_ID}    = 0;
    $self->{+_STDERR_ID}    = 0;
    $self->{+_EVENTS_BUFFER} ||= [];
    $self->{+_STDOUT_BUFFER} ||= [];
    $self->{+_STDERR_BUFFER} ||= [];
}

sub poll {
    my $self = shift;
    my ($max) = @_;

    $self->_fill_buffers($max);

    my (@out, @new);

    # If we have a max number of events then we need to pass that along to the
    # inner-pollers, but we need to pass around how many MORE we need, this sub
    # will return the amount we still need.
    # If this finds that we do not need any more it will exit the loop instead
    # of returning a number.
    my $check = defined($max) ? sub {
        no warnings 'exiting';
        my $want = $max - scalar(@out) - scalar(@new);
        last if $want < 1;
        return $want;
    } : sub { undef };

    while(!defined($max) || @out < $max) {
        # Micro-optimization, 'start' only ever has 1 thing, so do not enter
        # the sub if we do not need to.
        push @new => $self->_poll_start($check->()) if $self->{+_START_BUFFER};

        # Do not re-order these. Everything syncs to event, so put it last. We
        # want STDOUT to appear before STDERR typically We will only work so
        # hard to order stdout/stderr, this is as far as we go.
        push @new => $self->_poll_stdout($check->());
        push @new => $self->_poll_stderr($check->());
        push @new => $self->_poll_event($check->());

        # 'exit' MUST come last, so do not even think about grabbing
        # them until @new is empty.
        # Micro-optimization, 'exit' only ever has 1 thing, so do
        # not enter the subs if we do not need to.
        push @new => $self->_poll_exit($check->()) if !@new && defined $self->{+_EXIT_BUFFER};

        last unless @new;

        push @out => @new;
        @new = ();
    }

    return map { Test2::Harness::Event->new(%{$_}) } @out;
}

sub file {
    my $self = shift;
    return $self->{+_FILE} if $self->{+_FILE};

    my $fh = $self->_open_file('file');
    return 'UNKNOWN' unless $fh->exists;

    return $self->{+_FILE} = $fh->read_line;
}

my %FILE_MAP = (
    'events.jsonl' => [EVENTS_FILE, \&open_file],
    'stdout'       => [STDOUT_FILE, \&open_file],
    'stderr'       => [STDERR_FILE, \&open_file],
    'start'        => [START_FILE,  'Test2::Harness::Util::File::Value'],
    'exit'         => [EXIT_FILE,   'Test2::Harness::Util::File::Value'],
    'file'         => [FILE_FILE,   'Test2::Harness::Util::File::Value'],
);

sub _open_file {
    my $self = shift;
    my ($file) = @_;

    my $map = $FILE_MAP{$file} or croak "'$file' is not a known job file";
    my ($key, $type) = @$map;

    return $self->{$key} if $self->{$key};

    my $path = File::Spec->catfile($self->{+JOB_ROOT}, $file);
    my $out;

    return $self->{$key} = $type->new(name => $path)
        unless ref $type;

    return undef unless -e $path;
    return $self->{$key} = $type->($path, '<:utf8');
}

sub _fill_stream_buffers {
    my $self = shift;
    my ($max) = @_;

    my $events_buff = $self->{+_EVENTS_BUFFER} ||= [];
    my $stdout_buff = $self->{+_STDOUT_BUFFER} ||= [];
    my $stderr_buff = $self->{+_STDERR_BUFFER} ||= [];

    my $events_file = $self->{+EVENTS_FILE} || $self->_open_file('events.jsonl');
    my $stdout_file = $self->{+STDOUT_FILE} || $self->_open_file('stdout');
    my $stderr_file = $self->{+STDERR_FILE} || $self->_open_file('stderr');

    my @sets = grep { defined $_->[0] } (
        [$events_file, $events_buff],
        [$stdout_file, $stdout_buff],
        [$stderr_file, $stderr_buff],
    );

    return unless @sets;

    # Cache the result of the exists check on success, files can come into
    # existence at any time though so continue to check if it fails.
    while (!$max || @$events_buff + @$stderr_buff + @$stdout_buff < $max) {
        my $added = 0;
        for my $set (@sets) {
            my ($file, $buff) = @$set;

            my $pos = tell($file);
            my $line = <$file>;
            if (defined($line) && ($self->{+_EXIT_DONE} || substr($line, -1) eq "\n")) {
                push @$buff => $line;
                seek($file, 0, 1) if eof($file); # Reset EOF.
                $added++;
            }
            else {
                seek($file, $pos, 0);
            }
        }
        last unless $added;
    }
}

sub _fill_buffers {
    my $self = shift;
    my ($max) = @_;
    # NOTE 1: 'max' will only effect stdout, stderr, and events.jsonl, the
    # other files only have 1 value each so they will not eat too much memory.
    #
    # NOTE 2: 'max' only effects how many items are ADDED to the buffer, not
    # how many are in the buffer, that is good enough, poll() will take care of
    # the actual event limiting. We only use this here to make sure the buffer
    # grows slowly, this is important if max is used to avoid eating memory. We
    # still need to add to the buffers each time though in case we are waiting
    # for a sync event before we flush.

    # Do not read anything until the start file is present and read.
    unless ($self->{+START_EXISTS}) {
        my $start_file = $self->{+START_FILE} || $self->_open_file('start');
        return unless $start_file->exists;
        $self->{+_START_BUFFER} = $start_file->read_line or return;
        $self->{+START_EXISTS} = 1;
    }

    $self->_fill_stream_buffers($max);

    # Do not look for exit until we are done with the other streams
    return if $self->{+_EXIT_DONE} || @{$self->{+_STDOUT_BUFFER}} || @{$self->{+_STDERR_BUFFER}} || @{$self->{+_EVENTS_BUFFER}};

    my $ended = 0;
    my $exit_file = $self->{+EXIT_FILE} || $self->_open_file('exit');

    if ($exit_file->exists) {
        my $line = $exit_file->read_line;
        if (defined($line)) {
            $self->{+_EXIT_BUFFER} = $line;
            $self->{+_EXIT_DONE} = 1;
            $ended++;
        }
    }
    elsif ($self->{+RUNNER_EXITED}) {
        $self->{+_EXIT_BUFFER} = '-1';
        $self->{+_EXIT_DONE} = 1;
        $ended++;
    }

    return unless $ended;

    # If we found exit we need one last buffer fill on the other sources.
    # If we do not do this we have a race condition. Ignore the max for this.
    $self->_fill_stream_buffers();
}

sub _poll_start {
    my $self = shift;
    # Intentionally ignoring the max argument, this only ever returns 1 item,
    # and would not be called if max was 0.

    return unless defined $self->{+_START_BUFFER};
    my $value = delete $self->{+_START_BUFFER};

    return $self->_process_start_line($value);
}

sub _poll_exit {
    my $self = shift;
    # Intentionally ignoring the max argument, this only ever returns 1 item,
    # and would not be called if max was 0.

    return unless defined $self->{+_EXIT_BUFFER};
    my $value = delete $self->{+_EXIT_BUFFER};

    return $self->_process_exit_line($value);
}

sub _poll_event {
    my $self = shift;
    # Intentionally ignoring the max argument, this only ever returns 1 item,
    # and would not be called if max was 0.

    my $buffer = $self->{+_EVENTS_BUFFER};
    return unless @$buffer;

    my $event_data = ref($buffer->[0]) eq "HASH"
        ? $buffer->[0]
        : decode_json($buffer->[0]);
    my $id = $event_data->{stream_id};

    # We need to wait for these to catch up.
    return if $id > $self->{+_STDOUT_INDEX};
    return if $id > $self->{+_STDERR_INDEX};

    # All caught up, time for the event!
    shift @$buffer;
    $self->{+_EVENTS_INDEX} = $id;

    return $self->_process_events_line($event_data);
}

sub _poll_stdout {
    my $self = shift;
    my ($max) = @_;

    return if $self->{+_STDOUT_INDEX} > $self->{+_EVENTS_INDEX};

    my $buffer = $self->{+_STDOUT_BUFFER};
    return unless @$buffer;

    my @out;
    while (@$buffer) {
        my $line = shift @$buffer;
        chomp($line);

        my $esync = 0;
        if ($line =~ s/T2-HARNESS-ESYNC: (\d+)$//) {
            $self->{+_STDOUT_INDEX} = $1;
            $esync = 1;
        }

        last if $esync && !length($line);

        my $id = $self->{+_STDOUT_ID}; # Do not bump yet!

        my @event_datas = $self->_process_stdout_line($line);

        for my $event_data (@event_datas) {
            if(my $sid = $event_data->{stream_id}) {
                $self->{+_STDOUT_INDEX} = $sid;
                push @{$self->{+_EVENTS_BUFFER}} => $event_data;
                last;
            }

            # Now we bump it!
            $self->{+_STDOUT_ID}++;
            push @out => $event_data;
        }

        last if $esync || ($max && @out >= $max);
    }

    return $self->merge_info(\@out);
}

sub _poll_stderr {
    my $self = shift;
    my ($max) = @_;

    my @out;

    until ($self->{+_STDERR_INDEX} > $self->{+_EVENTS_INDEX} || ($max && @out >= $max)) {
        my $buffer = $self->{+_STDERR_BUFFER} or last;

        my @lines;
        while (@$buffer) {
            my $line = shift @$buffer;
            chomp($line);

            if ($line =~ s/T2-HARNESS-ESYNC: (\d+)$//) {
                $self->{+_STDERR_INDEX} = $1;
                push @lines => $line if length($line);
                last;
            }

            push @lines => $line;
        }

        last unless @lines;

        my $id = $self->{+_STDERR_ID}++;
        push @out => $self->_process_stderr_line(join "\n" => @lines);
    }

    return $self->merge_info(\@out);
}

sub merge_info {
    my $self = shift;
    my ($events) = @_;

    my @out;
    my $current;

    for my $e (@$events) {
        my $f = $e->{facet_data};
        my $no_merge = first { $_ ne 'info' } keys %$f;
        $no_merge ||= @{$f->{info}} > 1;

        if ($no_merge) {
            $current = undef;
            push @out => $e;
            next;
        }

        if ($current && $f->{info}->[0]->{tag} eq $current->{info}->[0]->{tag}) {
            $current->{info}->[0]->{details} .= "\n" . $f->{info}->[0]->{details};
            next;
        }

        push @out => $e;
        $current = $f;
        next;
    }

    return @out;
}

sub _process_events_line {
    my $self = shift;
    my ($event_data) = @_;

    $event_data->{job_id} = $self->{+JOB_ID};
    $event_data->{run_id} = $self->{+RUN_ID};
    $event_data->{event_id} ||= $event_data->{facet_data}->{about}->{uuid} ||= gen_uuid();

    return $event_data;
}

sub _process_stderr_line {
    my $self = shift;
    my ($line) = @_;

    chomp($line);

    my $facet_data;
    $facet_data = parse_stderr_tap($line);
    $facet_data ||= {info => [{details => $line, tag => 'STDERR', debug => 1}]};

    my $event_id = $facet_data->{about}->{uuid} ||= gen_uuid();

    return {
        job_id     => $self->{+JOB_ID},
        run_id     => $self->{+RUN_ID},
        event_id   => $event_id,
        facet_data => $facet_data,
    };
}

sub _process_stdout_line {
    my $self = shift;
    my ($line) = @_;

    chomp($line);

    my @event_datas;

    if ($line =~ s/T2-HARNESS-EVENT: (\d+) (.+)$//) {
        my ($sid, $json) = ($1, $2);

        my $event_data = decode_json($json);
        $event_data->{stream_id} = $sid;
        $event_data->{event_id} ||= $event_data->{facet_data}->{about}->{uuid} ||= gen_uuid();
        push @event_datas => $event_data;
    }

    if (defined $line) {
        my $facet_data;

        # Sometimes clever scripts mix events and directly printed TAP... sigh.
        $facet_data = parse_stdout_tap($line);

        $facet_data ||= {info => [{details => $line, tag => 'STDOUT', debug => 0}]};

        my $event_id = $facet_data->{about}->{uuid} ||= gen_uuid();

        unshift @event_datas => {facet_data => $facet_data, event_id => $event_id};
    }

    return map {{ %{$_}, job_id => $self->{+JOB_ID}, run_id => $self->{+RUN_ID} }} @event_datas;
}

sub _process_start_line {
    my $self = shift;
    my ($value) = @_;

    chomp($value);

    my $event_id = gen_uuid();

    return {
        event_id => $event_id,
        job_id   => $self->{+JOB_ID},
        run_id   => $self->{+RUN_ID},
        stamp    => $value,

        facet_data => {
            about             => {uuid => $event_id},
            harness_job_start => {
                details => "Job $self->{+JOB_ID} started at $value",
                job_id  => $self->{+JOB_ID},
                stamp   => $value,
                file    => $self->file,
            },
        }
    };
}

sub _process_exit_line {
    my $self = shift;
    my ($value) = @_;

    chomp($value);

    my $stdout = maybe_read_file(File::Spec->catfile($self->{+JOB_ROOT}, "stdout"));
    my $stderr = maybe_read_file(File::Spec->catfile($self->{+JOB_ROOT}, "stderr"));

    my $event_id = gen_uuid();

    return {
        event_id => $event_id,
        job_id   => $self->{+JOB_ID},
        run_id   => $self->{+RUN_ID},

        facet_data => {
            about            => {uuid => $event_id},
            harness_job_exit => {
                details => "Test script exited $value",
                exit    => $value,
                job_id  => $self->{+JOB_ID},
                file    => $self->file,
                stdout  => $stdout,
                stderr  => $stderr,
            },
        }
    };
}

sub have_buffer {
    my $self = shift;

    # These are scalar buffers
    return 1 if defined $self->{+_START_BUFFER};
    return 1 if defined $self->{+_EXIT_BUFFER};

    # These are array buffers
    return 1 if @{$self->{+_EVENTS_BUFFER}};
    return 1 if @{$self->{+_STDOUT_BUFFER}};
    return 1 if @{$self->{+_STDERR_BUFFER}};

    return 0;
}

1;


__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Job::Dir - Job Directory Parser, read events from an active
jobs output directory.

=head1 DESCRIPTION

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
