package App::Yath2::Renderer::Formatter;
use strict;
use warnings;

our $VERSION = '2.000011';

use App::Yath2::Renderer::Theme::Composer();

use Object::HashBase qw{
    <io
    <io_err
    <composer
    <tag_width
};

use Role::Tiny::With;
with 'App::Yath2::Role::Renderer';

# The verbose -v line formatter. Every triple the composer produces
# from an event is written as a single line:
#
#   [ TAG   ] <text>
#
# STDOUT and STDERR streams are separated: triples whose facet is
# 'error' or whose tag is in STDERR_TAGS go to io_err; everything
# else goes to io. This matches the legacy -v contract: tests that
# print diag go to stderr, tests that pass emit ok lines to stdout.

my %STDERR_TAGS = map { $_ => 1 } qw/STDERR DIAG WARN WARNING FAIL FAILED ERROR FATAL CRITICAL TIMEOUT/;

sub init {
    my $self = shift;

    $self->{+IO} //= \*STDOUT;
    unless (ref($self->{+IO})) {
        my $path = $self->{+IO};
        open(my $fh, '>', $path) or die "Cannot open '$path' for writing: $!";
        $self->{+IO} = $fh;
    }
    $self->{+IO}->autoflush(1) if $self->{+IO}->can('autoflush');

    $self->{+IO_ERR} //= \*STDERR;
    unless (ref($self->{+IO_ERR})) {
        my $path = $self->{+IO_ERR};
        open(my $fh, '>', $path) or die "Cannot open '$path' for writing: $!";
        $self->{+IO_ERR} = $fh;
    }
    $self->{+IO_ERR}->autoflush(1) if $self->{+IO_ERR}->can('autoflush');

    $self->{+COMPOSER}  //= App::Yath2::Renderer::Theme::Composer->new;
    $self->{+TAG_WIDTH} //= 8;

    return;
}

sub event_in {
    my ($self, $event) = @_;

    my $f = ref($event) eq 'HASH' ? $event->{facet_data} // {} : {};

    # Every renderable triple the event carries. The caller is the
    # one that decided this event should be forwarded (the artifact-
    # reading layer in verbose mode replays the whole 0.jsonl), so
    # here we render everything we can.
    my $triples = $self->{+COMPOSER}->render_verbose($f);
    return unless ref($triples) eq 'ARRAY' && @$triples;

    for my $triple (@$triples) {
        my ($facet, $tag, $text) = @$triple;
        my $fh = $self->_stream_for($facet, $tag);
        print $fh $self->_format_line($tag, $text);
    }

    return;
}

sub end_of_run {
    my ($self, %summary) = @_;

    my $rid  = $summary{run_id}     // '(unknown)';
    my $pass = $summary{pass_count} // 0;
    my $fail = $summary{fail_count} // 0;
    my $fh   = $fail ? $self->{+IO_ERR} : $self->{+IO};

    print $fh sprintf("[%-*s] %s\n", $self->{+TAG_WIDTH},
        $fail ? 'FAILED' : 'PASSED',
        "run $rid: $pass passed, $fail failed",
    );

    return;
}

sub shutdown { }

sub _stream_for {
    my ($self, $facet, $tag) = @_;
    return $self->{+IO_ERR} if $facet && $facet eq 'error';
    return $self->{+IO_ERR} if $tag && $STDERR_TAGS{uc($tag)};
    return $self->{+IO};
}

sub _format_line {
    my ($self, $tag, $text) = @_;
    my $txt = defined $text ? $text : '';
    $txt =~ s/\s+\z//;
    return sprintf("[%-*s] %s\n", $self->{+TAG_WIDTH}, $tag, $txt);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::Formatter - Verbose line-by-line event formatter.

=head1 DESCRIPTION

A minimal verbose renderer. For every event handed in via
C<event_in>, it walks the composer's verbose output (every triple
the event produces) and writes one line per triple to either
STDOUT or STDERR.

Intended for the C<-v> code path: the artifact-reading layer
replays every event from a test's C<0.jsonl> through this
renderer, so each test line appears exactly as the test emitted
it.

=head1 ATTRIBUTES

=over 4

=item io

Primary output filehandle (STDOUT by default). Passes / info /
plans go here.

=item io_err

Secondary output filehandle (STDERR by default). Failures,
errors, diagnostics, and STDERR-tagged output go here.

=item composer

L<App::Yath2::Renderer::Theme::Composer> instance; defaults to a
fresh one.

=item tag_width

Width of the leading tag column. Defaults to 8.

=back

=head1 HOOKS

All four hooks from L<App::Yath2::Role::Renderer> are implemented;
C<event_in> does the verbose replay, C<end_of_run> prints a short
result line, and the other two are no-ops.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

See L<https://dev.perl.org/licenses/>

=cut
