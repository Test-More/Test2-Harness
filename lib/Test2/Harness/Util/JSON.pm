package Test2::Harness::Util::JSON;
use strict;
use warnings;

our $VERSION = '1.000000';

BEGIN {
    local $@ = undef;
    my $ok = eval {
        require JSON::MaybeXS;
        JSON::MaybeXS->import('JSON');
        1;

        if (JSON() eq 'JSON::PP') {
            *JSON_IS_PP = sub() { 1 };
            *JSON_IS_XS = sub() { 0 };
            *JSON_IS_CPANEL = sub() { 0 };
            *JSON_IS_CPANEL_OR_XS = sub() { 0 };
        }
        elsif (JSON() eq 'JSON::XS') {
            *JSON_IS_PP = sub() { 0 };
            *JSON_IS_XS = sub() { 1 };
            *JSON_IS_CPANEL = sub() { 0 };
            *JSON_IS_CPANEL_OR_XS = sub() { 1 };
        }
        elsif (JSON() eq 'Cpanel::JSON::XS') {
            *JSON_IS_PP = sub() { 0 };
            *JSON_IS_XS = sub() { 0 };
            *JSON_IS_CPANEL = sub() { 1 };
            *JSON_IS_CPANEL_OR_XS = sub() { 1 };
        }
    };

    unless ($ok) {
        require JSON::PP;
        *JSON = sub() { 'JSON::PP' };

        *JSON_IS_PP = sub() { 1 };
        *JSON_IS_XS = sub() { 0 };
        *JSON_IS_CPANEL = sub() { 0 };
        *JSON_IS_CPANEL_OR_XS = sub() { 0 };
    }

}

our @EXPORT = qw{JSON encode_json decode_json decode_json_non_utf8 encode_pretty_json encode_canon_json};
our @EXPORT_OK = qw{JSON_IS_PP JSON_IS_XS JSON_IS_CPANEL JSON_IS_CPANEL_OR_XS};
BEGIN { require Exporter; our @ISA = qw(Exporter) }

my $json          = JSON->new->utf8(1)->convert_blessed(1)->allow_nonref(1);
my $json_non_utf8 = JSON->new->utf8(0)->convert_blessed(1)->allow_nonref(1);
my $canon         = JSON->new->utf8(1)->canonical(1)->convert_blessed(1)->allow_nonref(1);
my $pretty        = JSON->new->utf8(1)->pretty(1)->canonical(1)->convert_blessed(1)->allow_nonref(1);

sub encode_json        { $json->encode(@_) }
sub encode_canon_json  { $canon->encode(@_) }
sub encode_pretty_json { $pretty->encode(@_) }

sub decode_json {
    my ($input) = @_;
    my $data;

    local $@;
    my $error;

    # Try to decode the JSON stream as utf8. In malformed tests or tests which are intentionally
    # testing bytes behavior we need to accept the bytes from the JSON file instead.
    my $ok = eval { $data = $json->decode($input); 1 } || do {
        $error = $@;
        eval { $data = $json_non_utf8->decode($input); 1 };
    };
    $error ||= $@;
    return $data if $ok;
    my $mess = Carp::longmess("JSON decode error: $error");
    die "$mess\n=======\n$input\n=======\n";
}

# This is here because Test2::Formatter::Stream's JSON encoder
# doesn't encode as UTF-8 (i.e., its utf8() mode is not enabled).
# Thus, we need the logic that decodes that JSON not to decode UTF-8.
sub decode_json_non_utf8 {
    my ($input) = @_;
    my $data;

    local $@;
    my $error;

    eval { $data = $json_non_utf8->decode($input); 1 } or do {
        my $mess = Carp::longmess("JSON decode error: $@");
        die "$mess\n=======\n$input\n=======\n";
    };

    return $data;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::JSON - Utility class to help Test2::Harness pick the best
JSON implementation.

=head1 DESCRIPTION

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
