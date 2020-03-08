package App::Yath::Plugin::Git;
use strict;
use warnings;

our $VERSION = '1.000011';

use IPC::Cmd qw/can_run/;
use Test2::Harness::Util::IPC qw/run_cmd/;
use parent 'App::Yath::Plugin';

sub inject_run_data {
    my $class  = shift;
    my %params = @_;

    my $meta   = $params{meta};
    my $fields = $params{fields};

    my $long_sha  = $ENV{GIT_LONG_SHA};
    my $short_sha = $ENV{GIT_SHORT_SHA};
    my $status    = $ENV{GIT_STATUS};
    my $branch    = $ENV{GIT_BRANCH};

    if (my $cmd = $ENV{GIT_COMMAND} || can_run('git')) {
        my @sets = (
            [\$long_sha, 'rev-parse', 'HEAD'],
            [\$short_sha, 'rev-parse', '--short', 'HEAD'],
            [\$status, 'status', '-s'],
            [\$branch, 'rev-parse', '--abbrev-ref', 'HEAD'],
        );

        for my $set (@sets) {
            my ($var, @args) = @$set;
            next if $$var; # Already set

            my ($rh, $wh, $irh, $iwh);
            pipe($rh, $wh) or die "No pipe: $!";
            pipe($irh, $iwh) or die "No pipe: $!";
            my $pid = run_cmd(stderr => $iwh, stdout => $wh, command => [$cmd, @args]);
            waitpid($pid, 0);
            next if $?;
            close($wh);
            chomp($$var = join "\n" => <$rh>);
        }
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
