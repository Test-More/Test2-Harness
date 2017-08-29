package Test2::Harness::Util::JSON;
use strict;
use warnings;

our $VERSION = '0.001001';

BEGIN {
    local $@ = undef;
    my $ok = eval {
        require JSON::MaybeXS;
        JSON::MaybeXS->import('JSON');
        1;
    };

    unless($ok) {
        require JSON::PP;
        *JSON = sub() { 'JSON::PP' };
    }
}

our @EXPORT = qw{JSON encode_json decode_json encode_pretty_json encode_canon_json};
BEGIN { require Exporter; our @ISA = qw(Exporter) }

my $json = JSON->new->utf8(1)->convert_blessed(1);
my $canon = JSON->new->utf8(1)->canonical(1)->convert_blessed(1);
my $pretty = JSON->new->utf8(1)->pretty(1)->canonical(1)->convert_blessed(1);

sub encode_json { $json->encode(@_) }
sub encode_canon_json { $canon->encode(@_) }
sub encode_pretty_json { $pretty->encode(@_) }

sub decode_json {
    my ($input) = @_;
    my $data;
    my $ok = eval { $data = $json->decode($input); 1 };
    my $error = $@;
    return $data if $ok;
    die "JSON decode error: $error$input\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::JSON - Utility class to help Test2::Harness pick the best
JSON implementation.

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
