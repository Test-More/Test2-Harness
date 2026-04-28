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

# Why 'iff' and not 'if', AI typo?
# Read the file iff something about it has changed since the last
# successful read. Returns the decoded content on a fresh read
# (including Perl undef if the file contained the literal JSON
# `null`), or an empty list if nothing has changed since last time.
# The empty-list vs (undef) distinction lets callers loop cheaply:
#
#     while (my @new = $f->read_if_changed) {
#         my ($payload) = @new;        # defined or undef, both valid
#         ... handle $payload ...
#     }
#
# The change test layers -- see Test2::Harness2::Util::File's
# changed() -- so this inherits whatever watching mechanism the
# base class is using (Linux::Inotify2 or stat-tuple fallback).
# Remove this for FileMonitor
sub read_if_changed {
    my $self = shift;

    # Take a snapshot of the stat state BEFORE the read so we don't
    # miss a racing writer that flips the file between our changed()
    # check and our read: record_state() is called with what we saw
    # just now, not what stat reports after we finish reading.
    my $cur = $self->_current_state;

    return () unless $self->changed;

    my $path = $self->{+NAME};
    unless (defined($cur) && -e $path) {
        # File is gone. Note that and report "changed"; but there
        # is no content to return, so an empty list is misleading
        # -- report (undef) so the caller can react to disappearance.
        # The next call sees no change (both states are "missing").
        $self->_record_state(undef);
        return (undef);
    }

    my $raw = Test2::Harness2::Util::read_file($path);

    # Empty or unreadable: record the state and report the absence
    # of content as (undef) so the caller can distinguish "read
    # returned nothing" from "nothing to read".
    unless (defined($raw) && length($raw)) {
        $self->_record_state($cur);
        return (undef);
    }

    my $data;
    my $ok = eval { $data = $self->decode($raw); 1 };
    my $err = $@;
    confess "$path: $err" unless $ok;

    $self->_record_state($cur);
    return ($data);
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
