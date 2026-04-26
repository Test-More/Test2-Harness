package App::Yath::Script::V0;
use strict;
use warnings;

use Getopt::Yath;

our $VERSION = '2.000012';

my @BEGIN_ARGS;

option_group {group => 'v0', category => 'V0 Options'} => sub {
    option begin => (
        type        => 'List',
        description => 'Arguments to process during the BEGIN phase',
    );

    option goto_file => (
        type        => 'Scalar',
        description => 'Use goto::file to switch to a different file during BEGIN (for testing)',
    );
};

sub do_begin {
    my $class  = shift;
    my %params = @_;

    my $argv = $params{argv};

    my $state = parse_options($argv, skip_non_opts => 1);
    @BEGIN_ARGS = @{$state->{settings}->v0->begin // []};

    # Non-option args go back into @ARGV for do_runtime
    @ARGV = @{$state->{skipped} // []};

    print "BEGIN: $_\n" for @BEGIN_ARGS;

    my $goto = $state->{settings}->v0->goto_file;
    if ($goto) {
        require goto::file;
        goto::file->import($goto);
    }
}

sub do_runtime {
    my $class = shift;

    print "RUNTIME: $_\n" for @ARGV;

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Script::V0 - Test/validation version of the yath script handler

=head1 DESCRIPTION

This is the V0 script handler, intended for validating the yath script itself
rather than running real tests. It echoes non-option arguments prefixed by
C<BEGIN:> or C<RUNTIME:> depending on the phase in which they are processed.

=head1 OPTIONS

=over 4

=item --begin ARG

Add an argument to be processed (echoed) during the BEGIN phase. Can be
specified multiple times.

=back

=head1 EXAMPLE

    $ PERL_HASH_SEED=1 yath --begin hello --begin world foo bar

    BEGIN: hello
    BEGIN: world
    RUNTIME: foo
    RUNTIME: bar

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
