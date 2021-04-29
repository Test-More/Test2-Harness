package App::Yath::Plugin::Git;
use strict;
use warnings;

our $VERSION = '1.000052';

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

    my $cmd = $class->git_cmd or return;

    my ($rh, $wh, $irh, $iwh);
    pipe($rh, $wh) or die "No pipe: $!";
    pipe($irh, $iwh) or die "No pipe: $!";
    my $pid = run_cmd(stderr => $iwh, stdout => $wh, command => [$cmd, @args]);

    close($wh);
    close($iwh);

    $rh->blocking(1);
    my @out = <$rh>;

    waitpid($pid, 0);
    if($?) {
        print STDERR <$irh>;
        return;
    }

    push @out => <$rh>;

    close($irh);

    return @out;
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
            chomp($$var = join "\n" => $class->git_output(@args));
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

sub _subs_from {
    my $class = shift;
    my ($from) = @_;
    my $cmd = $class->git_cmd or return;

    my %changed;

    # Only perl can parse perl, and nothing can parse perl diff. What this does
    # is take a diff of every file with 100% context so we see the entire file
    # with the +, minus, or space prefix. As we scan it we look for subs. We
    # track what files and subs we are in. When we see a change we
    # {$file}{$sub}++.
    #
    # This of course is broken if you make a change between
    # subs as it will attribute it to the previous sub, however tracking
    # indentation is equally flawed as things like heredocs and other special
    # perl things can also trigger that to prematurely think we are out of a
    # sub.
    #
    # PPI and similar do a better job parsing perl, but using them and also
    # tracking changes from the diff, or even asking them to parse a diff where
    # some lines are added and others removed is also a huge hassle.
    #
    # The current algorith is "good enough", not perfect.
    my ($file, $sub, $indent);
    for my $line ($class->git_output('diff', '-U1000000', '-W', '--minimal', $from)) {
        chomp($line);
        if ($line =~ m{^(?:---|\+\+\+) [ab]/(.*)$}) {
            my $maybe_file = $1;
            next if $maybe_file =~ m{/dev/null};
            $file = $maybe_file;
            $sub  = '*'; # Wildcard, changes to the code outside of a sub potentially effects all subs
            $changed{$file} //= {};
            next;
        }

        next unless $file;

        $line =~ m/^( |-|\+)(.*)$/ or next;
        my ($prefix, $statement) = ($1, $2, $3);
        my $changed = $prefix eq ' ' ? 0 : 1;

        if ($statement =~ m/^(\s*)sub\s+(\w+)/) {
            $indent = $1 // '';
            $sub = $2;

            # 1-line sub: sub foo { ... }
            if ($statement =~ m/}/) {
                $changed{$file}{$sub}++ if $changed;
                $sub = '*';
                $indent = undef;
                next;
            }
        }
        elsif(defined($indent) && $statement =~ m/^$indent\}/) {
            $indent = undef;
            $sub = "*";
        }

        next unless $sub;

        $changed{$file}{$sub}++ if $changed;
    }

    return map {([$_ => sort keys %{$changed{$_}}])} sort keys %changed;
}

sub changed_files {
    my $class = shift;
    my ($settings) = @_;

    $class->_changed_files($settings->git->change_base);
}

sub _changed_files {
    my $class = shift;
    my ($base) = @_;

    my $cmd = $class->git_cmd or return;

    my $from = 'HEAD';

    if ($base) {
        $from .= "^" while system($cmd => 'merge-base', '--is-ancestor', $from, $base);
        return $class->_subs_from($from);
    }

    my @files = $class->_subs_from($from);
    return @files if @files;

    return $class->_subs_from("${from}^");
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
