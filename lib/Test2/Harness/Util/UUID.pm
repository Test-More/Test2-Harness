package Test2::Harness::Util::UUID;
use strict;
use warnings;

our $VERSION = '1.000155';

use Data::UUID;
use Importer 'Importer' => 'import';

our @EXPORT = qw/gen_uuid/;
our @EXPORT_OK = qw/UG gen_uuid/;

my ($UG, $UG_PID);
sub UG {
    return $UG if $UG && $UG_PID && $UG_PID == $$;

    $UG_PID = $$;
    return $UG = Data::UUID->new;
}

sub gen_uuid { UG()->create_str() }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::UUID - Utils for generating UUIDs.

=head1 DESCRIPTION

This module provides a consistent UUID source for all of Test2::Harness.

=head1 SYNOPSIS

    use Test2::Harness::Util::UUID qw/gen_uuid/;

    my $uuid = gen_uuid;

=head1 EXPORTS

=over 4

=item $uuid = gen_uuid()

Generate a UUID.

=back

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
