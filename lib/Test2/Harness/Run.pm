package Test2::Harness::Run;
use strict;
use warnings;

our $VERSION = '0.001001';

use Carp qw/croak/;

use Test2::Util qw/IS_WIN32/;

use Test2::Harness::Util::HashBase qw{
    -run_id

    -job_count
    -switches
    -libs -lib -blib
    -preload
    -args
    -input

    -chdir
    -search
    -unsafe_inc

    -env_vars
    -no_stream
    -no_fork
};

sub init {
    my $self = shift;

    # Put this here, before loading data, loaded data means a replay without
    # actually running tests, this way we only die if we are starting a new run
    # on windows.
    croak "preload is not supported on windows"
        if IS_WIN32 && $self->{+PRELOAD};

    croak "The 'run_id' attribute is required"
        unless $self->{+RUN_ID};

    $self->{+CHDIR}     ||= undef;
    $self->{+SEARCH}    ||= ['t'];
    $self->{+PRELOAD}   ||= undef;
    $self->{+SWITCHES}  ||= [];
    $self->{+ARGS}      ||= [];
    $self->{+LIBS}      ||= [];
    $self->{+LIB}       ||= 0;
    $self->{+BLIB}      ||= 0;
    $self->{+JOB_COUNT} ||= 1;
    $self->{+INPUT}     ||= undef;

    $self->{+UNSAFE_INC} = 1 unless defined $self->{+UNSAFE_INC};

    my $env = $self->{+ENV_VARS} ||= {};
    $env->{PERL_USE_UNSAFE_INC} = $self->{+UNSAFE_INC} unless defined $env->{PERL_USE_UNSAFE_INC};

    $env->{HARNESS_ACTIVE}    = 1;
    $env->{T2_HARNESS_ACTIVE} = 1;

    $env->{HARNESS_VERSION}    = "Test2-Harness-$VERSION";
    $env->{T2_HARNESS_VERSION} = $VERSION;

    $env->{T2_HARNESS_JOBS} = $self->{+JOB_COUNT};
    $env->{HARNESS_JOBS}    = $self->{+JOB_COUNT};

    $env->{T2_HARNESS_RUN_ID} = $self->{+RUN_ID};
}

sub all_libs {
    my $self = shift;

    my @libs;

    push @libs => 'lib' if $self->{+LIB};
    push @libs => 'blib/lib', 'blib/arch' if $self->{+BLIB};
    push @libs => @{$self->{+LIBS}} if $self->{+LIBS};

    return @libs;
}

sub TO_JSON { return { %{$_[0]} } }

sub find_files {
    my $self = shift;

    my $search = $self->search;

    my (@files, @dirs);

    for my $item (@$search) {
        push @files => $item and next if -f $item;
        push @dirs  => $item and next if -d $item;
        die "'$item' does not appear to be either a file or a directory.\n";
    }

    require File::Find;
    File::Find::find(
        sub {
            no warnings 'once';
            return unless -f $_ && m/\.t2?$/;
            push @files => $File::Find::name;
        },
        @dirs
    );

    return sort @files;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Run - Test Run Configuration

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
