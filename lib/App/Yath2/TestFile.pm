package App::Yath2::TestFile;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec ();
use List::Util qw/any uniq/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/open_file clean_path/;
use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase qw{
    <file <absolute <relative
    +_scanned +_shbang
    +features +switches
    +category +duration +stage
    +conflicts
    +retry +retry_isolated
    <smoke <isolation
    +non_perl +is_binary
    +event_timeout +post_exit_timeout
    +min_slots +max_slots
    +meta
    <ch_dir
    <comment

    <input <env_vars <test_args <job_class <queue_args
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::TestFile';

# {{{ Construction

sub init {
    my $self = shift;

    my $file = $self->{+FILE};
    croak "'file' is a required attribute" unless defined $file && length $file;

    # Canonicalize the path before storing so a later chdir does not
    # redirect the launch. clean_path returns an absolute, normalized
    # form. Mirrors reference/legacy/.../TestFile.pm:67-71.
    $file = clean_path($file, 0);
    $self->{+FILE} = $file;

    croak "Invalid test file '$file'" unless -f $file;

    $self->{+ABSOLUTE} //= File::Spec->rel2abs($file);
    $self->{+RELATIVE} //= File::Spec->abs2rel($file);

    # is_binary classification needs to share a stat cache with the -f
    # check above. -B _ uses the cached stat from the most recent
    # filesystem test (the croak's -f leaves _ populated for us). The
    # is_executable check that follows derives from $self->{+ABSOLUTE},
    # which we just set above.
    if (-B _ && !-z _) {
        $self->{+IS_BINARY} = 1;
        $self->{+NON_PERL}  = 1;
        die "Cannot run binary test file '$file': file is not executable.\n"
            unless $self->is_executable;
    }

    $self->{+QUEUE_ARGS} //= [];

    # Seed every role default into the corresponding HashBase slot so
    # the slot reader returns the documented default instead of undef
    # when the caller does not supply one. defaults() builds fresh
    # sub-containers per call so each instance has its own arrayref /
    # hashref.
    my $defaults = $self->defaults;
    for my $k (keys %$defaults) {
        $self->{$k} //= $defaults->{$k};
    }
}

# }}} Construction

# {{{ Mutators
#
# Mirrors the legacy / old2 setter surface so finders, plugins, and
# CLI overrides can adjust scan results before queueing. Each mutator
# scans first (so the override is applied to fully-populated data)
# then writes the new value into the corresponding HashBase slot.

sub set_duration  { $_[0]->scan; $_[0]->{+DURATION}  = lc($_[1]) }
sub set_category  { $_[0]->scan; $_[0]->{+CATEGORY}  = lc($_[1]) }
sub set_stage     { $_[0]->scan; $_[0]->{+STAGE}     = $_[1] }
sub set_min_slots { $_[0]->scan; $_[0]->{+MIN_SLOTS} = $_[1] }
sub set_max_slots { $_[0]->scan; $_[0]->{+MAX_SLOTS} = $_[1] }

sub set_input      { $_[0]->{+INPUT}      = $_[1] }
sub set_env_vars   { $_[0]->{+ENV_VARS}   = $_[1] }
sub set_test_args  { $_[0]->{+TEST_ARGS}  = $_[1] }
sub set_job_class  { $_[0]->{+JOB_CLASS}  = $_[1] }
sub set_queue_args { $_[0]->{+QUEUE_ARGS} = $_[1] }

sub set_retry {
    my $self = shift;
    my $val  = @_ ? $_[0] : 1;
    $self->scan;
    $self->{+RETRY} = $val;
}

sub set_retry_isolated {
    my $self = shift;
    my $val  = @_ ? $_[0] : 1;
    $self->scan;
    $self->{+RETRY_ISOLATED} = $val;
}

sub set_smoke {
    my $self = shift;
    my $val  = @_ ? $_[0] : 1;
    $self->scan;
    $self->{+FEATURES}{smoke} = $val;
}

# }}} Mutators

# {{{ check_feature override
#
# The role's check_feature is a pure data lookup. The scanner-aware
# override here adds the "fork/preload need a perl interpreter and
# only -w switches" safety net documented in TEST_FILE_AUDIT.md §2.7.
# Mirrors the legacy / old2 logic that was previously baked into
# test_settings; current 2.0 hoisted it into check_feature.

sub check_feature {
    my ($self, $feature, $default) = @_;
    $self->scan;

    if (defined $feature && ($feature eq 'fork' || $feature eq 'preload')) {
        return 0 if $self->{+NON_PERL} || $self->{+IS_BINARY};
        return 0 if any { $_ !~ m/^-w$/ } @{$self->{+SWITCHES} || []};
    }

    # Defer to the role's pure-data lookup for the actual answer.
    return $self->Test2::Harness2::Role::TestFile::check_feature($feature, $default);
}

# Scanner-aware classifiers that mirror the legacy fallbacks (long
# duration when timeouts are off, isolation category when the
# isolation feature is set).

sub check_duration {
    my $self = shift;
    $self->scan;
    return $self->{+DURATION} if defined $self->{+DURATION};
    return 'long' unless $self->check_feature('timeout');
    return 'medium';
}

sub check_category {
    my $self = shift;
    $self->scan;
    return $self->{+CATEGORY} if defined $self->{+CATEGORY};
    return 'isolation'        if $self->check_feature('isolation');
    return 'general';
}

sub check_stage     { $_[0]->scan; $_[0]->{+STAGE} }
sub check_min_slots { $_[0]->scan; $_[0]->{+MIN_SLOTS} }
sub check_max_slots { $_[0]->scan; $_[0]->{+MAX_SLOTS} }

# }}} check_feature override

# {{{ Auto-scanning data accessors
#
# Override the role's scanned-data accessors to trigger scan() on
# first read, mirroring legacy / old2 lazy-scan semantics. Plain
# attribute slots (file, comment, env_vars, etc.) do not auto-scan;
# only the slots populated by the directive parser do.

sub meta {
    my $self = shift;
    $self->scan;
    return $self->{+META};
}

sub meta_get {
    my ($self, $key) = @_;
    $self->scan;
    my $hash = $self->{+META} // {};
    return () unless defined $key && $hash->{$key};
    return @{$hash->{$key}};
}

sub conflicts {
    my $self = shift;
    $self->scan;
    return $self->{+CONFLICTS};
}

sub features {
    my $self = shift;
    $self->scan;
    return $self->{+FEATURES};
}

sub switches {
    my $self = shift;
    $self->scan;
    return $self->{+SWITCHES};
}

sub retry             { $_[0]->scan; $_[0]->{+RETRY} }
sub retry_isolated    { $_[0]->scan; $_[0]->{+RETRY_ISOLATED} }
sub event_timeout     { $_[0]->scan; $_[0]->{+EVENT_TIMEOUT} }
sub post_exit_timeout { $_[0]->scan; $_[0]->{+POST_EXIT_TIMEOUT} }
sub non_perl          { $_[0]->scan; $_[0]->{+NON_PERL} }
sub is_binary         { $_[0]->scan; $_[0]->{+IS_BINARY} }
sub category          { $_[0]->scan; $_[0]->{+CATEGORY} }
sub duration          { $_[0]->scan; $_[0]->{+DURATION} }
sub stage             { $_[0]->scan; $_[0]->{+STAGE} }
sub min_slots         { $_[0]->scan; $_[0]->{+MIN_SLOTS} }
sub max_slots         { $_[0]->scan; $_[0]->{+MAX_SLOTS} }

# }}} Auto-scanning data accessors

# {{{ Scanning

sub scan {
    my $self = shift;
    $self->_scan();
    return;
}

sub _scan {
    my $self = shift;

    return if $self->{+_SCANNED}++;
    return unless -e $self->{+ABSOLUTE};

    if (-B _ && !-z _) {
        $self->{+IS_BINARY} = 1;
        $self->{+NON_PERL}  = 1;
        return;
    }

    return if $self->{+IS_BINARY};

    # Use the accessor (not the slot) so a non-perl test with a custom
    # comment char is honoured even if the consumer did not seed the
    # slot. comment() falls through to the role default ('#') when
    # nothing has set it. Pitfall #14.
    my $comment = $self->comment // '#';

    my $retry_set;
    my $job_slots_set;
    my $fh = open_file($self->{+ABSOLUTE});
    for (my $ln = 1; my $line = <$fh>; $ln++) {
        chomp($line);
        next if $line =~ m/^\s*$/;

        if ($ln == 1 && $line =~ m/^#!/) {
            my $shbang = $self->_parse_shbang($line);
            if ($shbang && %$shbang) {
                $self->{+_SHBANG}  = $shbang;
                $self->{+SWITCHES} = $shbang->{switches} if $shbang->{switches};
                $self->{+NON_PERL} = 1                   if $shbang->{non_perl};
                next;
            }
        }

        # The "this is a generated yath runner test" short-circuit is
        # a yath concern; previously it lived in the harness's scanner.
        # It now lives here, in the producer side, where it belongs.
        # Pitfall #9.
        if ($line =~ m/^\s*#\s*THIS IS A GENERATED YATH RUNNER TEST/) {
            $self->{+FEATURES}{run} = 0;
            next;
        }

        next if $line =~ m/^\s*\Q$comment\E/ && $line !~ m/^\s*\Q$comment\E\s*HARNESS-.+/;
        next if $line =~ m/^\s*(?:use|require|BEGIN|package)\b/;
        last unless $line =~ m/^\s*\Q$comment\E\s*HARNESS-(.+)$/;

        my ($dir, $rest) = split /[-\s]+/, $1, 2;
        $dir = lc($dir);
        my @args;
        if ($dir eq 'meta') {
            if (defined $rest) {
                @args = split /\s+/,  $rest, 2;
                @args = split /[-]+/, $rest, 2 if @args == 1;
                $args[1] =~ s/\s+(?:#.*)?$// if defined $args[1];
            }
        }
        elsif ($rest) {
            $rest =~ s/\s+(?:#.*)?$//;
            @args = split /[-\s]+/, $rest;
        }

        if ($dir eq 'no') {
            my $feature = lc(join '_' => @args);
            if ($feature eq 'retry') {
                $self->{+RETRY} = 0;
                $retry_set = 1;
            }
            else {
                $self->{+FEATURES}{$feature} = 0;
            }
        }
        elsif ($dir eq 'yes' || $dir eq 'use') {
            my $feature = lc(join '_' => @args);
            $self->{+FEATURES}{$feature} = 1;
        }
        elsif ($dir eq 'smoke') {
            $self->{+FEATURES}{smoke} = 1;
        }
        elsif ($dir eq 'retry') {
            if (@args) {
                for my $arg (@args) {
                    if ($arg =~ m/^\d+$/) {
                        $self->{+RETRY} = int $arg;
                        $retry_set = 1;
                    }
                    elsif ($arg =~ m/^iso/i) {
                        $self->{+RETRY}          = 1 unless $retry_set;
                        $self->{+RETRY_ISOLATED} = 1;
                        $retry_set               = 1;
                    }
                    else {
                        warn "Unknown 'HARNESS-RETRY' argument '$arg' at $self->{+FILE} line $ln.\n";
                    }
                }
            }
            elsif (!$retry_set) {
                $self->{+RETRY} = 1;
                $retry_set = 1;
            }
        }
        elsif ($dir eq 'stage') {
            my ($name) = @args;
            $self->{+STAGE} = $name;
        }
        elsif ($dir eq 'duration' || $dir eq 'dur') {
            my ($name) = @args;
            $self->{+DURATION} = lc($name);
        }
        elsif ($dir eq 'category' || $dir eq 'cat') {
            my ($name) = @args;
            $name = lc($name);
            if ($name =~ m/^(?:long|medium|short)$/) {
                $self->{+DURATION} = $name;
            }
            else {
                $self->{+CATEGORY} = $name;
            }
        }
        elsif ($dir eq 'timeout') {
            my ($type, $num, $extra) = @args;
            $type = lc($type);
            $num  = lc($num) if defined $num;

            ($type, $num) = ('postexit', $extra)
                if $type eq 'post' && defined $num && $num eq 'exit';

            if ($type !~ m/^(?:event|postexit)$/) {
                warn "'" . uc($type) . "' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at $self->{+FILE} line $ln.\n";
                next;
            }

            if ($type eq 'event') {
                $self->{+EVENT_TIMEOUT} = $num;
            }
            else {
                $self->{+POST_EXIT_TIMEOUT} = $num;
            }
        }
        elsif ($dir eq 'job' && defined $rest && $rest =~ m/slots\s+(\d+)(?:\s+(\d+))?$/i) {
            # Legacy uses //= against a fresh %headers hash so the first
            # JOB-SLOTS wins. init() pre-seeds MIN_SLOTS from role
            # defaults, so a scan-local tracker carries the "first-wins"
            # semantic. Pitfall #5; Q3.4 = (c).
            next if $job_slots_set;
            $self->{+MIN_SLOTS} = $1;
            $self->{+MAX_SLOTS} = $2 || $1;
            $job_slots_set      = 1;
        }
        elsif ($dir eq 'conflicts') {
            $self->{+CONFLICTS} ||= [];
            push @{$self->{+CONFLICTS}} => map { lc($_) } @args;
            @{$self->{+CONFLICTS}} = uniq @{$self->{+CONFLICTS}};
        }
        elsif ($dir eq 'meta') {
            my ($key, $val) = @args;
            $key = lc($key);
            push @{$self->{+META}{$key}} => $val;
        }
        else {
            warn "Unknown harness directive '$dir' at $self->{+FILE} line $ln.\n";
        }
    }

    return;
}

sub _parse_shbang {
    my $self = shift;
    my $line = shift;

    return {} if !defined $line;

    my %shbang;

    # NOTE: dashes are intentionally included with the switches.
    my $shbang_re = qr{
        ^
          \#!.*perl.*?        # the perl path
          (?: \s (-.+) )?     # the switches, maybe
          \s*
        $
    }xi;

    if ($line =~ $shbang_re) {
        my @switches;
        @switches         = grep { m/\S/ } split /\s+/, $1 if defined $1;
        $shbang{switches} = \@switches;
        $shbang{line}     = $line;
    }
    elsif ($line =~ m/^#!/ && $line !~ m/perl/i) {
        $shbang{line}     = $line;
        $shbang{non_perl} = 1;
    }

    return \%shbang;
}

# }}} Scanning

# {{{ Queue payload (queue_item)
#
# The yath-side equivalent of legacy's queue_item / old2's
# test_settings. Produces the runner-queue payload: classifiers,
# feature toggles, retry policy, env/input/test_args overrides, plus
# a fresh job_id (gen_uuid). Mirrors reference/legacy/.../TestFile.pm
# queue_item; env_vars merge order is preserved as-is (caller's env
# wins except where the test file defines the same key).

sub queue_item {
    my $self = shift;
    my ($job_name, $run_id, %inject) = @_;

    die "The '$self->{+FILE}' test specifies that it should not be run by Test2::Harness.\n"
        unless $self->check_feature(run => 1);

    my $category  = $self->check_category;
    my $duration  = $self->check_duration;
    my $stage     = $self->check_stage;
    my $min_slots = $self->check_min_slots;
    my $max_slots = $self->check_max_slots;

    my $smoke     = $self->check_feature(smoke     => 0);
    my $fork      = $self->check_feature(fork      => 1);
    my $preload   = $self->check_feature(preload   => 1);
    my $timeout   = $self->check_feature(timeout   => 1);
    my $stream    = $self->check_feature(stream    => 1);
    my $io_events = $self->check_feature(io_events => 1);

    my $retry          = $self->retry;
    my $retry_isolated = $self->retry_isolated;

    my $binary   = $self->{+IS_BINARY} ? 1 : 0;
    my $non_perl = $self->{+NON_PERL}  ? 1 : 0;

    my $et  = $self->event_timeout;
    my $pet = $self->post_exit_timeout;

    my $job_class = $self->{+JOB_CLASS};
    my $input     = $self->{+INPUT};
    my $test_args = $self->{+TEST_ARGS};

    # env_vars merge: caller's $inject{env_vars} provides the base,
    # the test file's env_vars layered on top. The test file wins for
    # any key it defines; everything else from the caller passes
    # through. Mirrors reference/legacy/.../TestFile.pm:435-439 --
    # keep this ordering as-is (Pitfall #10).
    my $env_vars = $self->{+ENV_VARS};
    if ($env_vars) {
        my $mix = delete $inject{env_vars};
        $env_vars = {%$mix, %$env_vars} if $mix;
    }

    return {
        binary    => $binary,
        category  => $category,
        conflicts => [$self->conflicts_list],
        duration  => $duration,
        file      => $self->file,
        rel_file  => $self->relative,
        job_id    => gen_uuid(),
        job_name  => $job_name,
        run_id    => $run_id,
        non_perl  => $non_perl,
        stage     => $stage,
        stamp     => time,
        switches  => $self->switches,

        use_fork    => $fork,
        use_preload => $preload,
        use_stream  => $stream,
        use_timeout => $timeout,

        smoke     => $smoke,
        io_events => $io_events,
        rank      => $self->rank,

        defined($input)          ? (input             => $input)          : (),
        defined($env_vars)       ? (env_vars          => $env_vars)       : (),
        defined($test_args)      ? (test_args         => $test_args)      : (),
        defined($job_class)      ? (job_class         => $job_class)      : (),
        defined($retry)          ? (retry             => $retry)          : (),
        defined($retry_isolated) ? (retry_isolated    => $retry_isolated) : (),
        defined($et)             ? (event_timeout     => $et)             : (),
        defined($pet)            ? (post_exit_timeout => $pet)            : (),
        defined($min_slots)      ? (min_slots         => $min_slots)      : (),
        defined($max_slots)      ? (max_slots         => $max_slots)      : (),

        @{$self->{+QUEUE_ARGS}},

        %inject,
    };
}

# }}} Queue payload (queue_item)

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::TestFile - Yath-side, scanner-aware TestFile producer.

=head1 DESCRIPTION

C<App::Yath2::TestFile> is the producer-side TestFile object: it
scans the file's shebang and C<HARNESS-*> directives, applies CLI
overrides through a setter surface, and builds the runner-queue
payload. Yath constructs these instances at finder / queue time.
After scanning + override, instances are typically serialized to a
hashref via the role's L<TO_JSON|Test2::Harness2::Role::TestFile/TO_JSON>
and shipped to the harness, which rehydrates a static
L<Test2::Harness2::TestFile> on the receiving side.

The harness library does not depend on this class; it knows only
the role contract.

=head1 SYNOPSIS

    use App::Yath2::TestFile;

    my $tf = App::Yath2::TestFile->new(file => 't/foo.t');

    $tf->set_duration('short');           # CLI override
    $tf->set_retry(3);                    # CLI override

    my $payload = $tf->queue_item(undef, $run_id);

    # ... or hand off via TO_JSON for a serialized harness queue
    my $hash = $tf->TO_JSON;

=head1 ATTRIBUTES

In addition to every attribute documented on
L<Test2::Harness2::Role::TestFile/ATTRIBUTES>, this class carries
queue-time data that the harness itself never needs to see:

=over 4

=item input

Stdin to feed the test process.

=item env_vars

Hashref of extra environment variables for the test process. Merged
with caller-supplied env at C<queue_item> time; the test file wins
for any key it defines.

=item test_args

Arguments to pass to the test script after C<-->.

=item job_class

Alternate Job subclass for the runner.

=item queue_args

Arrayref of extra key/value pairs spliced into the queue payload.

=back

=head1 METHODS

=over 4

=item $tf->scan

Read the shebang and C<HARNESS-*> directives from the file. Idempotent;
results are cached.

=item $tf->set_duration($dur)

=item $tf->set_category($cat)

=item $tf->set_stage($stage)

=item $tf->set_min_slots($n)

=item $tf->set_max_slots($n)

=item $tf->set_retry($n?)

=item $tf->set_retry_isolated($bool?)

=item $tf->set_smoke($bool?)

CLI / plugin override hooks. Each calls C<scan> first (so the
override is applied to fully-populated data) then writes the new
value into the corresponding slot. C<set_retry>, C<set_retry_isolated>,
and C<set_smoke> default to C<1> when called with no argument.

=item $tf->set_input($val)

=item $tf->set_env_vars($hashref)

=item $tf->set_test_args($arrayref)

=item $tf->set_job_class($class)

=item $tf->set_queue_args($arrayref)

Plain setters for the queue-time slots; no scan side effect (these
do not influence directive parsing).

=item $hashref = $tf->queue_item($job_name, $run_id, %inject)

Build the runner-queue payload. Mints a fresh C<job_id> via
C<Test2::Util::UUID::gen_uuid>; merges caller-supplied env with the
test file's env (test file wins per key); splices in C<queue_args>
and C<%inject>. Dies if the test file's C<run> feature is set to a
falsy value.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
