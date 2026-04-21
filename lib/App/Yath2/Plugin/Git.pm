package App::Yath2::Plugin::Git;
use strict;
use warnings;

our $VERSION = '2.000011';

use Role::Tiny::With;
with 'App::Yath2::Role::Plugin';

use Object::HashBase qw{};

use Getopt::Yath;

option_group {prefix => 'git', group => 'git', category => "Git Options"} => sub {
    option 'git' => (
        type        => 'Bool',
        prefix      => undef,
        description => "Enable the git plugin",
    );

    option change_base => (
        type           => 'Scalar',
        description    => "Find files changed by all commits in the current branch from most recent stopping when a commit is found that is also present in the history of the branch/commit specified as the change base.",
        long_examples  => [" master", " HEAD^", " df22abe4"],
    );
};

# HAS_* constants gate on the two optional CPAN dependencies. We
# probe once at load time so repeated lookups are cheap, and we
# surface the result via constants per the project style rules.
use constant HAS_IPC_CMD => eval { require IPC::Cmd; 1 } ? 1 : 0;
use constant HAS_CAPTURE_TINY => eval { require Capture::Tiny; 1 } ? 1 : 0;

# Resolved path to the git binary, or undef if neither $ENV{GIT_COMMAND}
# nor IPC::Cmd::can_run('git') turn one up. Captured at load time so
# later lookups in run_fields are instantaneous.
my $GIT_CMD;
if ($ENV{GIT_COMMAND}) {
    $GIT_CMD = $ENV{GIT_COMMAND};
}
elsif (HAS_IPC_CMD) {
    $GIT_CMD = IPC::Cmd::can_run('git');
}

sub git_cmd { $ENV{GIT_COMMAND} || $GIT_CMD }

# Run the git binary with @args and return the captured stdout.
# Returns undef when git isn't available at all. Dies with the
# captured stderr when git exits non-zero (so the caller knows the
# command itself failed rather than just "no git").
sub git_output {
    my $class = shift;
    my (@args) = @_;

    my $cmd = $class->git_cmd or return undef;
    return undef unless HAS_CAPTURE_TINY;

    my ($stdout, $stderr, $exit) = Capture::Tiny::capture(sub { system($cmd, @args) });
    die "git command failed: $stderr\n" if $exit;

    return $stdout;
}

# Probe git for the four values we care about (long sha, short sha,
# status, branch). Env vars can override any of them so CI systems
# that already know the answers don't pay the fork/exec tax. Returns
# an empty list if we cannot determine the long sha -- without that,
# a git field would be misleading.
sub run_fields {
    my $class = shift;

    my $long_sha  = $ENV{GIT_LONG_SHA};
    my $short_sha = $ENV{GIT_SHORT_SHA};
    my $status    = $ENV{GIT_STATUS};
    my $branch    = $ENV{GIT_BRANCH};

    my @sets = (
        [\$long_sha,  'rev-parse', 'HEAD'],
        [\$short_sha, 'rev-parse', '--short', 'HEAD'],
        [\$status,    'status',    '-s'],
        [\$branch,    'rev-parse', '--abbrev-ref', 'HEAD'],
    );

    for my $set (@sets) {
        my ($var, @args) = @$set;
        next if $$var;    # already set via env

        my $out;
        my $ok = eval { $out = $class->git_output(@args); 1 };
        # A missing repo or broken git invocation is expected --
        # swallow it and move on. Per CLAUDE.md this is one of the
        # allowed "optional module / feature detection" eval cases.
        next unless $ok;
        next unless defined $out;
        $$var = $out;
        chomp($$var);
    }

    return unless $long_sha;

    my %data;
    $data{sha}    = $long_sha;
    $data{status} = $status if $status;

    my $field = {
        name => 'git',
        data => \%data,
    };

    if ($branch) {
        $data{branch}     = $branch;
        $field->{details} = $branch;
        $field->{raw}     = $long_sha;
    }
    else {
        $short_sha ||= substr($long_sha, 0, 16);
        $field->{details} = $short_sha;
        $field->{raw}     = $long_sha;
    }

    return ($field);
}

# Dispatched by Test2::Harness2 when a run is queued. Called as a
# class method (the harness passes the plugin handle which for
# stateless plugins is the class name); returning an empty list when
# there's no git info to contribute is fine.
sub run_queued {
    my $class = shift;
    my ($run) = @_;

    my @fields = $class->run_fields;
    return unless @fields;
    return @fields;
}

# --- Change tracking -------------------------------------------------
#
# The "diff from base" machinery mirrors old/. It's used by
# downstream plugins (e.g. Cover) that narrow test selection to
# files touched by the current branch's commits. Lives on the Git
# plugin so it has direct access to git_output / git_cmd.

sub changed_diff {
    my $class = shift;
    my ($settings) = @_;

    my $base = eval { $settings->git->change_base };
    return $class->_changed_diff($base);
}

sub _changed_diff {
    my $class = shift;
    my ($base) = @_;

    my $cmd = $class->git_cmd or return;

    my $from = 'HEAD';

    if ($base) {
        $from .= "^" while system($cmd => 'merge-base', '--is-ancestor', $from, $base);
        return $class->_diff_from($from);
    }

    my @files = $class->_diff_from($from);
    return @files if @files;

    return $class->_diff_from("${from}^");
}

sub _diff_from {
    my $class = shift;
    my ($from) = @_;
    my $cmd = $class->git_cmd or return;

    return (diff => $class->git_output('diff', '-U1000000', '-W', '--minimal', $from));
}

sub TO_JSON { ref($_[0]) || "$_[0]" }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Plugin::Git - Plugin to attach git metadata to a run.

=head1 DESCRIPTION

Attaches git metadata (long sha, short sha, branch, status) to a run
when git is available and the cwd is inside a git checkout. Enable
with C<-pGit> or C<--plugin=Git>.

When git isn't installed, or the cwd isn't a git checkout, the
plugin quietly contributes nothing -- it does not error out and does
not block the run.

=head1 SYNOPSIS

    $ yath test -pGit ...

=head1 READING THE DATA

The data is attached to the run's C<fields> list under C<< name => 'git' >>,
carrying C<sha>, optional C<status>, and when HEAD is on a named
branch, C<branch>.

=head1 OPTIONAL DEPENDENCIES

=over 4

=item L<IPC::Cmd> -- used to locate the C<git> binary via C<can_run('git')>.

=item L<Capture::Tiny> -- used to capture git stdout/stderr.

=back

Both are optional. If either is absent the plugin degrades silently:
it records no git field instead of throwing.

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
