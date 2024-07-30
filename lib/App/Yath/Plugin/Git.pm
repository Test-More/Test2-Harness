package App::Yath::Plugin::Git;
use strict;
use warnings;

our $VERSION = '2.000001';

use IPC::Cmd qw/can_run/;
use Capture::Tiny qw/capture/;

use parent 'App::Yath::Plugin';

use Getopt::Yath;

option_group {prefix => 'git', group => 'git', category => "Git Options"} => sub {
    option 'git' => (
        type => 'Bool',
        prefix => undef,
        description => "Enable the git plugin",
    );

    option change_base => (
        type => 'Scalar',
        description => "Find files changed by all commits in the current branch from most recent stopping when a commit is found that is also present in the history of the branch/commit specified as the change base.",
        long_examples  => [" master", " HEAD^", " df22abe4"],
    );
};

my $GIT_CMD = can_run('git');
sub git_cmd { $ENV{GIT_COMMAND} || $GIT_CMD }

sub git_output {
    my $class = shift;
    my (@args) = @_;

    my $cmd = $class->git_cmd or return undef;

    my ($stdout, $stderr, $exit) = capture { system($cmd, @args) };
    die "git command failed: $stderr\n" if $exit;

    return $stdout;
}

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
        next if $$var;    # Already set
        $$var = $class->git_output(@args) or next;
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
        $data{branch} = $branch;
        $field->{details} = $branch;
        $field->{raw} = $long_sha;
    }
    else {
        $short_sha ||= substr($long_sha, 0, 16);
        $field->{details} = $short_sha;
        $field->{raw} = $long_sha;
    }

    return ($field);
}

sub run_queued {
    my $class = shift;
    my ($run) = @_;

    my @fields = $class->run_fields();

    $run->send_event(facet_data => {harness_run_fields => \@fields}) if @fields;

    return;
}

sub changed_diff {
    my $class = shift;
    my ($settings) = @_;

    $class->_changed_diff($settings->git->change_base);
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

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Plugin::Git - Plugin to attach git data to a test run.

=head1 DESCRIPTION

This plugin will attach git data to your test logs if any is available.

=head1 SYNOPSIS

    $ yath test -pGit ...

=head1 READING THE DATA

The data is attached to the 'run' entry in the log file. This can be seen
directly in the json data, database, or server.

The data will include the long sha, short sha, branch name, and a brief status.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
