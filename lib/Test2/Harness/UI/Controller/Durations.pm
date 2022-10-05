package Test2::Harness::UI::Controller::Durations;
use strict;
use warnings;

our $VERSION = '0.000128';

use Data::GUID;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json encode_pretty_json/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Durations' }

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};

    my $res = resp(200);

    my $user = $req->user;

    die error(404 => 'Missing route') unless $route;
    my $project_name = $route->{project} or die error(404 => 'No project');
    my $short        = $route->{short} || 15;
    my $medium       = $route->{medium} || 30;
    my $median       = $route->{median} || 0;
    my $username     = $route->{user};

    my $schema  = $self->{+CONFIG}->schema;
    my $project = $schema->resultset('Project')->find({name => $project_name});

    my $data = {};
    if ($project) {
        $data = $project->durations(
            short  => $short,
            medium => $medium,
            median => $median,
            user   => $username,
        );
    }

    my $ct ||= lc($req->headers->{'content-type'} || $req->parameters->{'Content-Type'} || $req->parameters->{'content-type'} || 'text/html; charset=utf-8');
    $res->content_type($ct);

    if ($ct eq 'application/json') {
        $res->raw_body($data);
    }
    else {
        $res->raw_body("<pre>" . encode_pretty_json($data) . "</pre>");
    }

    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Durations

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
