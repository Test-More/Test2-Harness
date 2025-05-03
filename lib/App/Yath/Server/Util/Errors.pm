package App::Yath::Server::Util::Errors;
use strict;
use warnings;

our $VERSION = '2.000005';

use Scalar::Util qw/blessed/;

use Importer Importer => 'import';

our @EXPORT = qw/is_error_code/;

sub is_error_code {
    my $thing = shift;
    return undef unless blessed($thing);
    return undef unless $thing->isa(__PACKAGE__);
    return $$thing;
}

for my $code (400 .. 405) {
    my $val = 0 + $code;
    my $ref = bless \$val, __PACKAGE__;
    my $name = "ERROR_$code";
    push @EXPORT => $name;

    no strict 'refs';
    *{$name} = sub() { $ref };
}

sub code { ${$_[0]} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Server::Util::Errors - Easily throw http codes

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

=pod

=cut POD NEEDS AUDIT

