package Test2::Harness::UI::Controller::JobField;
use strict;
use warnings;

our $VERSION = '0.000136';

use Data::GUID;
use List::Util qw/max/;
use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Harness::UI::UUID qw/uuid_inflate/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    my $user = $req->user;

    die error(404 => 'Missing route') unless $route;

    my $it = $route->{id} or die error(404 => 'No id');
    $it = uuid_inflate($it) or die error(404 => "Invalid id");
    my $schema = $self->{+CONFIG}->schema;
    my $field = $schema->resultset('JobField')->search({job_field_id => $it})->first or die error(404 => 'Invalid Field');

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

Test2::Harness::UI::Controller::Run

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
