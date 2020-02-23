package Test2::Harness::Run;
use strict;
use warnings;

our $VERSION = '0.999002';

use Carp qw/croak/;

use File::Spec;

use Test2::Harness::Util::HashBase qw{
    <run_id

    <env_vars <author_testing <unsafe_inc

    <links

    <event_uuids
    <use_stream
    <mem_usage
    <io_events

    <input <input_file <test_args

    <load <load_import

    <fields <meta

    <retry <retry_isolated
};

sub init {
    my $self = shift;

    croak "run_id is required"
        unless $self->{+RUN_ID};
}

sub run_dir {
    my $self = shift;
    my ($workdir) = @_;
    return File::Spec->catfile($workdir, $self->{+RUN_ID});
}

sub TO_JSON { +{ %{$_[0]} } }

sub queue_item {
    my $self = shift;
    my ($plugins) = @_;

    croak "a plugins arrayref is required" unless $plugins;

    my $out = {%$self};

    my $meta = $out->{+META} //= {};
    my $fields = $out->{+FIELDS} //= [];
    for my $p (@$plugins) {
        $p->inject_run_data(meta => $meta, fields => $fields, run => $self);
    }

    return $out;
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Run - Representation of a set of tests to run, and their
options.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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
