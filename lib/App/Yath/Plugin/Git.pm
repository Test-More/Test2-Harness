package App::Yath::Plugin::Git;
use strict;
use warnings;

our $VERSION = '1.000000';

use IPC::Cmd qw/can_run/;
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

    if (my $cmd = can_run('git')) {
        chomp($long_sha  ||= `$cmd rev-parse HEAD`);
        chomp($short_sha ||= `$cmd rev-parse --short HEAD`);
        chomp($status    ||= `$cmd status -s`);
        chomp($branch    ||= `$cmd rev-parse --abbrev-ref HEAD`);
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

App::Yath::Plugin::Git - Plugin to attach git data to a rest run.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
