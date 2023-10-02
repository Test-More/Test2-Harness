package Test2::Harness::Util::File::JSONL;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp qw/croak/;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness::Util::File::Stream';
use Test2::Harness::Util::HashBase;

sub decode { shift; decode_json($_[0]) }
sub encode { shift; encode_json(@_) . "\n" }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::File::JSONL - Utility class for a JSONL file (stream)

=head1 DESCRIPTION

Subclass of L<Test2::Harness::Util::File> and
L<Test2::Harness::Util::File::Stream> which automatically handles
encoding/decoding JSONL data.

=head1 SYNOPSIS

    use Test2::Harness::Util::File::JSONL;

    my $jsonl = Test2::Harness::Util::File::JSONL->new(name => '/path/to/file.jsonl');

    while (1) {
        my @items = $jsonl->poll(max => 1000) or last;
        for my $item (@items) {
            ... handle $item ...
        }
    }

or

    use Test2::Harness::Util::File::JSONL;

    my $jsonl = Test2::Harness::Util::File::JSONL->new(name => '/path/to/file.jsonl');

    $jsonl->write({my => 'item', ... });
    ...

=head1 SEE ALSO

See the base classes L<Test2::Harness::Util::File> and
L<Test2::Harness::Util::File::Stream> for methods.

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
