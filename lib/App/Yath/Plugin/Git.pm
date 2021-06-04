package App::Yath::Plugin::Git;
use strict;
use warnings;

our $VERSION = '1.000058';

use IPC::Cmd qw/can_run/;
use Test2::Harness::Util::IPC qw/run_cmd/;
use parent 'App::Yath::Plugin';

use App::Yath::Options;

option_group {prefix => 'git', category => "Git Options"} => sub {
    option change_base => (
        type => 's',
        description => "Find files changed by all commits in the current branch from most recent stopping when a commit is found that is also present in the history of the branch/commit specified as the change base.",
        long_examples  => [" master", " HEAD^", " df22abe4"],
    );
};

my $GIT_CMD = can_run('git');
sub git_cmd { $ENV{GIT_COMMAND} || $GIT_CMD }

sub git_output {
    my $class = shift;
    my (@args) = @_;

    my $cmd = $class->git_cmd or return sub {()};

    my ($rh, $wh, $irh, $iwh);
    pipe($rh, $wh) or die "No pipe: $!";
    pipe($irh, $iwh) or die "No pipe: $!";
    my $pid = run_cmd(stderr => $iwh, stdout => $wh, command => [$cmd, @args]);

    close($wh);
    close($iwh);

    $rh->blocking(1);
    $irh->blocking(0);

    my $waited = 0;
    return sub {
        my $line = <$rh>;
        return $line if defined $line;

        unless ($waited++) {
            local $?;
            waitpid($pid, 0);
            print STDERR <$irh> if $?;
            close($irh);

            # Try again
            $line = <$rh>;
            return $line if defined $line;
        }

        close($rh);
        return;
    };
}

sub inject_run_data {
    my $class  = shift;
    my %params = @_;

    my $meta   = $params{meta};
    my $fields = $params{fields};

    my $long_sha  = $ENV{GIT_LONG_SHA};
    my $short_sha = $ENV{GIT_SHORT_SHA};
    my $status    = $ENV{GIT_STATUS};
    my $branch    = $ENV{GIT_BRANCH};

        my @sets = (
            [\$long_sha, 'rev-parse', 'HEAD'],
            [\$short_sha, 'rev-parse', '--short', 'HEAD'],
            [\$status, 'status', '-s'],
            [\$branch, 'rev-parse', '--abbrev-ref', 'HEAD'],
        );

        for my $set (@sets) {
            my ($var, @args) = @$set;
            next if $$var; # Already set
            my $output = $class->git_output(@args);

            my @lines;
            while (my $line = $output->()) {
                push @lines => $line;
            }

            chomp($$var = join "\n" => @lines);
        }

    return unless $long_sha;

    $meta->{git}->{sha}    = $long_sha;
    $meta->{git}->{status} = $status if $status;

    if ($branch) {
        $meta->{git}->{branch} = $branch;

        my $short = length($branch) > 20 ? substr($branch, 0, 20) : $branch;

        push @$fields => {name => 'git', details => $short, raw => $branch, data => $meta->{git}};
    }
    else {
        $short_sha ||= substr($long_sha, 0, 16);
        push @$fields => {name => 'git', details => $short_sha, raw => $long_sha, data => $meta->{git}};
    }

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

    return (line_sub => $class->git_output('diff', '-U1000000', '-W', '--minimal', $from));
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
directly in the json data. The data is also easily accessible with
L<Test2::Harness::UI>.

The data will include the long sha, short sha, branch name, and a brief status.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
