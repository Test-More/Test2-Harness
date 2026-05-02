package Test2::Harness2::Collector::Util;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use POSIX qw/:sys_wait_h/;
use Role::Tiny ();
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Event;
use Test2::Harness2::Util qw/load_module tinysleep/;
use Test2::Harness2::Util::IPC qw/pid_is_running/;

use Exporter qw/import/;

our @EXPORT_OK = qw{
    spec_class
    validate_spec
    make_warn_handler
    kill_child
    win32_quote_arg
};

# Pure helpers extracted from Test2::Harness2::Collector. Kept here so
# the class file holds class-shaped code only. None of these functions
# require an instance and none mutate global state on the caller's
# behalf -- they are deliberately ordinary subs (the class is in
# Collector.pm; this is a utility module).

# Return the class name implied by a spec. Specs come in three shapes:
#   - blessed instance ($obj)        -> ref($obj)
#   - arrayref [Class, @args]        -> $arr->[0]
#   - bare class name string         -> the string itself
# Returns undef for anything else.
sub spec_class {
    my ($spec) = @_;

    return ref($spec) if blessed($spec);
    return $spec->[0] if ref($spec) eq 'ARRAY';
    return $spec      if !ref($spec);
    return undef;
}

# Validates a single spec for blessed/arrayref/string shape, loads the
# class (for non-blessed forms), and verifies it implements $role at
# the class level. Returns nothing; croaks on any problem.
sub validate_spec {
    my ($spec, $kind, $role) = @_;

    if (blessed($spec)) {
        croak ucfirst($kind) . " '" . ref($spec) . "' does not implement $role"
            unless Role::Tiny::does_role($spec, $role);
        return;
    }

    my $name;
    if (ref($spec) eq 'ARRAY') {
        $name = $spec->[0];
        croak ucfirst($kind) . " arrayref must begin with a class name"
            unless defined($name) && !ref($name);
    }
    elsif (!ref($spec)) {
        $name = $spec;
    }
    else {
        croak "Invalid $kind specification: " . ref($spec);
    }

    load_module($name);

    croak ucfirst($kind) . " '$name' does not implement $role"
        unless Role::Tiny::does_role($name, $role);
}

# Build a coderef suitable for `local $SIG{__WARN__}`. Each warning
# becomes a Test2::Harness2::Event with a single info facet
# (tag => WARNING) and is handed to $cb. Failures inside $cb fall back
# to STDERR rather than re-warning (which would re-enter this handler).
sub make_warn_handler {
    my ($cb) = @_;
    croak "make_warn_handler requires a callback" unless ref($cb) eq 'CODE';

    return sub {
        my ($msg) = @_;

        my $ok = eval {
            my $event = Test2::Harness2::Event->new(
                event_id   => gen_uuid(),
                stamp      => time,
                facet_data => {
                    info => [{tag => 'WARNING', details => $msg, debug => 1}],
                },
            );
            $cb->($event);
            1;
        };
        # Print STDERR rather than warn to avoid re-entering this handler.
        # This is only reached when the callback itself fails -- at that
        # point the warning has nowhere else to go.
        print STDERR "Failed to log warning event ($msg): $@\n" unless $ok;
    };
}

# Send TERM to $pid, wait up to kill_timeout seconds for it to exit,
# then send KILL and wait synchronously for the reap. Returns the
# wait-status integer ($?). Caller is responsible for a prior
# pid_is_running gate -- this function assumes the pid is alive at
# entry.
#
# Unix-only. The Win32 path lives in Test2::Harness2::Collector::Win32
# as the _kill_child_win32 method.
sub kill_child {
    my ($pid, %opts) = @_;

    croak "kill_child requires a pid" unless $pid;

    my $timeout = $opts{kill_timeout} // 15;

    kill('TERM', $pid);

    my $start = time;
    while (time - $start < $timeout) {
        my $rv = waitpid($pid, WNOHANG);
        return $? if $rv == $pid;
        tinysleep(0.1);
    }

    kill('KILL', $pid);
    waitpid($pid, 0);
    return $?;
}

# Quoted-string helper for Win32 CreateProcess command lines.
# Rules: if the argument contains spaces or double-quotes, wrap it in
# double-quotes and escape any embedded double-quotes with a backslash.
# Pure function -- safe to call on any platform.
sub win32_quote_arg {
    my ($arg) = @_;
    return $arg unless $arg =~ /[ \t"]/;
    $arg =~ s/"/\\"/g;
    return qq{"$arg"};
}

# Thin line-reader shim for regular file handles. Lets non-pipe handles
# use the same read interface the collector applies to Atomic::Pipe
# handles. read_lines returns a list of [line => $data] tuples for each
# line currently available, with a trailing undef once EOF has been
# reached.
package Test2::Harness2::Collector::Util::FileLineReader;
use strict;
use warnings;

sub new {
    my ($class, $fh) = @_;
    return bless {fh => $fh, eof => 0}, $class;
}

sub read_lines {
    my $self = shift;
    my $fh   = $self->{fh};

    return () if $self->{eof};

    my @lines;
    while (defined(my $line = <$fh>)) {
        chomp $line;
        push @lines => [line => $line];
    }

    # If readline returned undef we hit EOF
    if (eof($fh)) {
        $self->{eof} = 1;
        push @lines => undef;
    }

    return @lines;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Util - Pure helpers extracted from Test2::Harness2::Collector.

=head1 DESCRIPTION

Functions and one tiny class previously embedded in
L<Test2::Harness2::Collector>. None of them require a Collector
instance; pulling them into a util module leaves the class file with
class-shaped code only.

=head1 EXPORTS

Nothing is exported by default; request the helpers explicitly:

    use Test2::Harness2::Collector::Util qw/
        spec_class
        validate_spec
        make_warn_handler
        kill_child
        win32_quote_arg
    /;

=head1 FUNCTIONS

=over 4

=item $name = spec_class($spec)

Return the class name implied by a parser/auditor/observer/logger
spec. Specs are blessed instances, C<[Class, @args]> arrayrefs, or
bare class-name strings. Returns C<undef> for anything else.

=item validate_spec($spec, $kind, $role)

Validate a spec for shape (blessed/arrayref/string), load the class
for non-blessed forms, and verify it implements C<$role> at the class
level. Returns nothing; croaks on any problem. C<$kind> is a
human-readable label used in error messages (e.g. C<"logger">).

=item $coderef = make_warn_handler($cb)

Build a coderef suitable for C<local $SIG{__WARN__}>. Each warning
becomes a L<Test2::Harness2::Event> with a single C<info> facet
(C<tag =E<gt> 'WARNING'>) and is handed to C<$cb>. Failures inside
C<$cb> fall back to STDERR rather than re-warning, which would
re-enter this handler.

=item $wstat = kill_child($pid, kill_timeout =E<gt> $secs)

Send C<TERM> to C<$pid>, wait up to C<$secs> seconds (default 15) for
it to exit, then send C<KILL> and wait synchronously for the reap.
Returns the wait-status integer (C<$?>). Caller is responsible for
the prior C<pid_is_running> gate. Unix-only; the Win32 path lives in
L<Test2::Harness2::Collector::Win32>.

=item $quoted = win32_quote_arg($arg)

Quoted-string helper for Win32 CreateProcess command lines. If
C<$arg> contains spaces, tabs, or double-quotes, wrap it in
double-quotes and escape any embedded double-quotes with a
backslash. Pure function -- safe to call on any platform.

=back

=head1 CLASSES

=head2 Test2::Harness2::Collector::Util::FileLineReader

Thin line-reader shim for regular file handles. Lets non-pipe handles
use the same read interface the collector applies to L<Atomic::Pipe>
handles.

=over 4

=item $r = Test2::Harness2::Collector::Util::FileLineReader->new($fh)

=item @items = $r->read_lines

Return a list of C<[line =E<gt> $data]> tuples for each line currently
available on C<$fh>. Appends C<undef> once EOF has been reached so
callers can detect the end of the stream.

=back

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

See L<https://dev.perl.org/licenses/>

=cut
