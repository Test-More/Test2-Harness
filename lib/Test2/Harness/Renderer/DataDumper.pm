package Test2::Harness::Renderer::DataDumper;
use strict;
use warnings;

our $VERSION = '0.000012';

use Data::Dumper;
use File::Basename qw/basename dirname/;
use File::Path qw/mkpath/;
use File::Spec;
use File::Temp qw/tempdir/;
use Test2::Util::HashBase qw/jobs dir encoder verbose/;

sub init {
    my $self = shift;

    $self->{+JOBS} = {};
    $self->{+DIR}  = $ENV{TEST2_DUMP_DIR}
        || tempdir(File::Spec->catdir(File::Spec->tmpdir, 'Test2-Dump-XXXXXXXX'));
}

sub listen {
    my $self = shift;
    sub { $self->process(@_) }
}

sub process {
    my $self = shift;
    my ($j, $fact) = @_;

    my $t_file = $j->file;
    if ($self->{+VERBOSE}) {
        print "Received fact for $t_file\n";
        print '  ', $fact->summary, "\n";
    }

    $self->{+JOBS}{$t_file} ||= [];
    push @{$self->{+JOBS}{$t_file}}, $fact;

    # End of the job
    return unless $fact->result && $fact->nested < 0;

    my $dump_file = File::Spec->catfile($self->{+DIR}, $t_file . '.dd');
    if ($self->{+VERBOSE}) {
        print "Dumping facts for $t_file to $dump_file\n";
    }

    local $Data::Dumper::Terse     = 1;
    local $Data::Dumper::Indent    = 1;
    local $Data::Dumper::Useqq     = 1;
    local $Data::Dumper::Deparse   = 1;
    local $Data::Dumper::Quotekeys = 0;
    local $Data::Dumper::Sortkeys  = 1;
    local $Data::Dumper::Purity    = 1;

    mkpath(dirname($dump_file), 0, 0755);
    open my $fh, '>', $dump_file or die "Cannot write to $dump_file: $!";
    print {$fh} Dumper($self->{+JOBS}{$t_file})
        or die "Cannot write to $dump_file: $!";
    close $fh or die "Cannot write to $dump_file: $!";
}

sub summary {
    my $self = shift;

    print 'Dumped all output to ', $self->{+DIR}, "\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Renderer::JSONDump - Dump facts to JSON files

=head1 DESCRIPTION

This renderer takes the stream of L<Test2::Harness::Fact> objects and dumps
them using Data::Dumper. Each test file that is executed is dumped to a
corresponding dump file.

By default, the files are dumped to a directory under your temp directory. You
can specify the directory to use by setting the C<TEST2_DUMP_DIR> environment
variable.

The primary use case for this module is to help you write other types of
renderers. Being able to dump out the facts for a test run will help you
understand how your renderer should handle presenting these facts.

You could also use this module to do remote code execution, where many systems
execute test files and another replays all the dumps to centralize the test
reporting.

=head1 EVALING DUMP FILES

The dumped data will almost certainly have cross-references between different
parts of the data structure. This means that the dump contains multiple
statements to fill in those references. You can use the following code snippet
to successfully read a file and turn it back into a Perl data structure:

    sub decode {
        my $file = shift;

        open my $fh, '<', $file or die "Cannot read $file: $!";
        my $dump = do { local $/; <$fh> };
        close $fh;

        our $VAR1;
        local $VAR1;
        local $@;

        eval $dump;
        die $@ if $@;

        return $VAR1;
    }

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Dave Rolsky E<lt>autarch@urth.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
