package App::Yath::Server::Controller::RunField;
use strict;
use warnings;

our $VERSION = '2.000001';

use List::Util qw/max/;
use Text::Xslate(qw/mark_raw/);
use App::Yath::Util qw/share_dir/;
use App::Yath::Server::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;


use parent 'App::Yath::Server::Controller';
use Test2::Harness::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    my $user = $req->user;

    die error(404 => 'Missing route') unless $route;

    my $it = $route->{id} or die error(404 => 'No id');
    my $schema = $self->schema;
    my $field = $schema->resultset('RunField')->find({run_field_id => $it}) or die error(404 => 'Invalid Field');

    if (my $act = $route->{action}) {
        if ($act eq 'delete') {
            $field->delete;
        }
    }

    $res->content_type('application/json');
    $res->raw_body($field);
    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Controller::RunField - Controller for fetching run fields

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

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
