package App::Yath::Util;
use strict;
use warnings;

our $VERSION = '0.001001';

use Carp qw/confess/;

use Importer Importer => 'import';

our @EXPORT_OK = qw/load_command fully_qualify/;

sub load_command {
    my ($cmd_name) = @_;
    my $cmd_class  = "App::Yath::Command::$cmd_name";
    my $cmd_file   = "App/Yath/Command/$cmd_name.pm";

    if (!eval { require $cmd_file; 1 }) {
        my $load_error = $@ || 'unknown error';

        confess "yath command '$cmd_name' not found. (did you forget to install $cmd_class?)"
            if $load_error =~ m{Can't locate \Q$cmd_file in \@INC\E};

        die $load_error;
    }

    return $cmd_class;
}

sub fully_qualify {
    my ($base, $in) = @_;

    $in =~ m/^(\+)?(.*)$/;
    return $2 if $1;
    return "$base\::$in";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Util - Common utils for yath.

=head1 DESCRIPTION

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
