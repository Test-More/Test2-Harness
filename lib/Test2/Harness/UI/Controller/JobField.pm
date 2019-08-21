package Test2::Harness::UI::Controller::JobField;
use strict;
use warnings;

our $VERSION = '0.000008';

use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub handle {
    my $self = shift;
    my ($route) = @_;

    my $req = $self->{+REQUEST};

    die error(404 => 'Missing route') unless $route;

    my $it = $route->{id} or die error(404 => 'No id');
    my $schema = $self->{+CONFIG}->schema;
    my $field = $schema->resultset('JobField')->search({job_field_id => $it})->first or die error(404 => 'Invalid Run');

    my $res = resp(200);
    $res->content_type('application/json');
    $res->raw_body($field);
    return $res;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::JobField

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
