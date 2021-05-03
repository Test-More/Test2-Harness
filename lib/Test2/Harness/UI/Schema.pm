package Test2::Harness::UI::Schema;
use utf8;
use strict;
use warnings;
use Carp qw/confess/;

our $VERSION = '0.000064';

use base 'DBIx::Class::Schema';

confess "You must first load a Test2::Harness::UI::Schema::NAME module"
    unless $Test2::Harness::UI::Schema::LOADED;

BEGIN {
    $INC{'Test2/Harness/UI/Schema/Result/Coverage.pm'} = 1;
    package    #
        Test2::Harness::UI::Schema::Result::Coverage;
    @Test2::Harness::UI::Schema::Result::Coverage::ISA = ('DBIx::Class::Core');
    __PACKAGE__->table("coverage");
}

__PACKAGE__->load_namespaces;

require Test2::Harness::UI::Schema::Result::ApiKey;
require Test2::Harness::UI::Schema::Result::Email;
require Test2::Harness::UI::Schema::Result::EmailVerificationCode;
require Test2::Harness::UI::Schema::Result::Event;
require Test2::Harness::UI::Schema::Result::Job;
require Test2::Harness::UI::Schema::Result::LogFile;
require Test2::Harness::UI::Schema::Result::Permission;
require Test2::Harness::UI::Schema::Result::PrimaryEmail;
require Test2::Harness::UI::Schema::Result::Project;
require Test2::Harness::UI::Schema::Result::Run;
require Test2::Harness::UI::Schema::Result::SessionHost;
require Test2::Harness::UI::Schema::Result::Session;
require Test2::Harness::UI::Schema::Result::User;

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

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
