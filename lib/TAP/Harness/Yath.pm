package TAP::Harness::Yath;
use strict;
use warnings;

our $VERSION = '2.000005';

BEGIN {
    require Test::Harness;
    Test::Harness->VERSION(3.49);
}

use TAP::Harness::Yath::Aggregator;

our $SUMMARY;

use App::Yath::Script;
use Test2::Harness::Util::HashBase qw{
    color
    ignore_exit
    jobs
    lib
    switches
    timer
    verbosity
};

sub runtests {
    my $self = shift;
    my (@tests) = @_;

    my @env_args = $ENV{TAP_HARNESS_YATH_ARGS} ? split(/\s*,\s*/, $ENV{TAP_HARNESS_YATH_ARGS}) : ();

    my @args = (
        'test',
        $self->{+COLOR} ? '--color' : (),
        '--jobs=' . ($self->{+JOBS} // 1),
        '-v=' . ($self->{+VERBOSITY} // 0),
        (map { "-I$_" } @{$self->{+LIB} // []}),
        (map { "-S=$_" } @{$self->{+SWITCHES} // []}),
        '--renderer=Default',
        '--renderer=TAPHarness',
        @env_args,
        @tests,
    );

    my $got = App::Yath::Script::run(__FILE__, \@args);

    my $files_total  = $SUMMARY->{'tests_seen'} //= 0;
    my $files_failed = $SUMMARY->{'failed'}     //= $got;
    my $files_passed = $files_total - $files_failed;

    my $asserts_total  = $SUMMARY->{'asserts_seen'}   // 0;
    my $asserts_passed = $SUMMARY->{'asserts_passed'} // 0;
    my $asserts_failed = $SUMMARY->{'asserts_failed'} // 0;

    my $out = TAP::Harness::Yath::Aggregator->new(
        files_total    => $files_total,
        files_failed   => $files_failed,
        files_passed   => $files_passed,

        asserts_total  => $asserts_total,
        asserts_passed => $asserts_passed,
        asserts_failed => $asserts_failed,
    );

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

TAP::Harness::Yath - Use yath instead of prove when installing modules.

=head1 DESCRIPTION

This tool allows you to tell the module install process to use yath instead of
prove. This works for cpan, cpanm, and most other module install tools. It
hooks into the process used by L<ExtUtils::MakeMaker> and
L<Module::Build::Tiny> which ultimately cover most of cpan.

=head1 SYNOPSIS

    HARNESS_SUBCLASS="TAP::Harness::Yath" cpanm [MODULES]

Setting the C<HARNESS_SUBCLASS> env var to "TAP::Harness::Yath" Will cause this
module to be used instead of L<Test::Harness> or L<TAP::Harness>.

You can also pass in command line arguments for yath using the
C<TAP_HARNESS_YATH_ARGS> env var, args should be seperated by comma. Any other
yath env vars will also work.

    TAP_HARNESS_YATH_ARGS="-v,--color" HARNESS_SUBCLASS="TAP::Harness::Yath" cpanm -v [MODULES]

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

=pod

=cut POD NEEDS AUDIT

