package Test2::Harness::UI::Util;
use strict;
use warnings;

our $VERSION = '0.000028';

use Carp qw/croak/;

use File::ShareDir();

use Importer Importer => 'import';

our @EXPORT = qw/share_dir share_file/;

sub share_file {
    my ($file) = @_;

    return File::ShareDir::dist_file('Test2-Harness-UI' => $file)
        unless 'dev' eq ($ENV{T2_HARNESS_UI_ENV} || '');

    my $path = "share/$file";
    croak "Could not find '$file'" unless -e $path;

    return $path;
}

sub share_dir {
    my ($dir) = @_;

    my $path;

    if ('dev' eq ($ENV{T2_HARNESS_UI_ENV} || '')) {
        $path = "share/$dir";
    }
    else {
        my $root = File::ShareDir::dist_dir('Test2-Harness-UI');
        $path = "$root/$dir";
    }

    croak "Could not find '$dir'" unless -d $path;

    return $path;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Util - General Utilities

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
