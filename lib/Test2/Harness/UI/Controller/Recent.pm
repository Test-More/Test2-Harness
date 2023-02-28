package Test2::Harness::UI::Controller::Recent;
use strict;
use warnings;

our $VERSION = '0.000136';

use Data::GUID;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};

    my $res = resp(200);

    die error(404 => 'Missing route') unless $route;

    my $project_name = $route->{project};
    my $user_name    = $route->{user};
    my $count        = $route->{count} || 10;

    my $schema = $self->{+CONFIG}->schema;
    my $runs   = $schema->vague_run_search(
        username     => $user_name,
        project_name => $project_name,
        query        => {},
        attrs        => {order_by => {'-desc' => 'added'}, rows => $count},
        list         => 1,
    );

    my $data = [];

    while (my $run = $runs->next) {
        push @$data => $run->TO_JSON;
    }

    $res->content_type('application/json');
    $res->raw_body($data);
    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Recent

=head1 DESCRIPTION

=head1 SYNOPSIS

TODO

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

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
