package Test2::Harness2::Util::File::JSON;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak confess/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json encode_pretty_json/;

use parent 'Test2::Harness2::Util::File';
use Object::HashBase qw/pretty/;

sub decode { shift; decode_json(@_) }
sub encode { shift->pretty ? encode_pretty_json(@_) : encode_json(@_) }

sub reset     { croak "line reading is disabled for json files" }
sub read_line { croak "line reading is disabled for json files" }

sub maybe_read {
    my $self = shift;

    return undef unless -e $self->{+NAME};
    my $out = Test2::Harness2::Util::read_file($self->{+NAME});

    return undef unless defined($out) && length($out);

    my $ok = eval { $out = $self->decode($out); 1 };
    my $err = $@;
    confess "$self->{+NAME}: $err" unless $ok;
    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::File::JSON - Utility class for a JSON file.

=head1 DESCRIPTION

Subclass of L<Test2::Harness2::Util::File> that automatically
JSON-encodes writes and JSON-decodes reads. Use L</pretty> to switch
the encoder to pretty-printed, canonical output for human-facing files.

=head1 SYNOPSIS

    require Test2::Harness2::Util::File::JSON;
    my $file = Test2::Harness2::Util::File::JSON->new(name => '/path/to/file.json');

    my $hash = $file->read;
    $file->write({...});

=head1 ATTRIBUTES

=over 4

=item $bool = $f->pretty

When true, L<Test2::Harness2::Util::File/write> uses
L<Test2::Harness2::Util::JSON/encode_pretty_json>. Defaults to
compact ASCII-safe JSON.

=back

=head1 SEE ALSO

See the base class L<Test2::Harness2::Util::File> for additional methods.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

See L<http://dev.perl.org/licenses/>

=cut
