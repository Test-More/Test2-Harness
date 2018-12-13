package Test2::Harness::Run;
use strict;
use warnings;

our $VERSION = '0.001072';

use Carp qw/croak/;

use List::Util qw/first/;

use Test2::Util qw/IS_WIN32/;

use File::Spec;

use Test2::Harness::Util::TestFile;

use Test2::Harness::Util::HashBase qw{
    -run_id

    -finite
    -job_count
    -switches
    -libs -lib -blib -tlib
    -preload
    -load    -load_import
    -args
    -input
    -verbose
    -dummy
    -cover
    -event_uuids
    -mem_usage

    -default_search
    -projects
    -search
    -unsafe_inc

    -env_vars
    -use_stream
    -use_fork
    -use_timeout
    -times
    -show_times

    -exclude_files
    -exclude_patterns
    -no_long

    -plugins
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

    $self->{+SEARCH}     ||= ['t'];
    $self->{+PRELOAD}    ||= undef;
    $self->{+SWITCHES}   ||= [];
    $self->{+ARGS}       ||= [];
    $self->{+LIBS}       ||= [];
    $self->{+LIB}        ||= 0;
    $self->{+BLIB}       ||= 0;
    $self->{+JOB_COUNT}  ||= 1;
    $self->{+INPUT}      ||= undef;

    $self->{+UNSAFE_INC} = 1 unless defined $self->{+UNSAFE_INC};
    $self->{+USE_STREAM} = 1 unless defined $self->{+USE_STREAM};
    $self->{+USE_FORK}   = (IS_WIN32 ? 0 : 1) unless defined $self->{+USE_FORK};

    croak "Preload requires forking"
        if $self->{+PRELOAD} && !$self->{+USE_FORK};

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

    my $libs = $self->{+LIBS} or return;
    return @$libs;
}

sub TO_JSON { return { %{$_[0]} } }

sub find_files {
    my $self = shift;

    my $search = $self->search;

    if ($self->{+PROJECTS}) {
        my @out;

        for my $root (@$search) {
            opendir(my $dh, $root) or die "Failed to open project dir: $!";
            for my $file (readdir($dh)) {
                next if $file =~ /^\.+/;
                next unless -d "$root/$file";

                my @sub_search = grep { -d $_ } map { "$root/$file/$_" } @{$self->{+DEFAULT_SEARCH}};
                next unless @sub_search;
                my @new = $self->_find_files(\@sub_search);

                for my $task (@new) {
                    push @{$task->queue_args} => (ch_dir => "$root/$file");

                    push @{$task->queue_args} => (libs => [grep { -d $_ } (
                        "$root/$file/lib",
                        "$root/$file/blib",
                    )]);
                }

                push @out => @new;
            }
        }

        return @out;
    }

    return $self->_find_files($search);
}

sub _find_files {
    my $self = shift;
    my ($search) = @_;

    my $plugins = $self->{+PLUGINS} || [];

    my (@files, @dirs);

    for my $item (@$search) {
        my $claimed;
        for my $plugin (@$plugins) {
            my $file = $plugin->claim_file($item) or next;
            push @files => $file;
            $claimed = 1;
            last;
        }
        next if $claimed;

        push @files => Test2::Harness::Util::TestFile->new(file => $item) and next if -f $item;
        push @dirs  => $item and next if -d $item;
        die "'$item' does not appear to be either a file or a directory.\n";
    }

    if (@dirs) {
        require File::Find;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    no warnings 'once';
                    return unless -f $_ && m/\.t2?$/;
                    push @files => Test2::Harness::Util::TestFile->new(
                        file => $File::Find::name,
                    );
                },
            },
            @dirs
        );
    }

    push @files => $_->find_files($self, $search) for @$plugins;

    $_->munge_files(\@files) for @$plugins;

    # With -jN > 1 we want to sort jobs based on their category, otherwise
    # filename sort is better for people.
    if ($self->{+JOB_COUNT} > 1 || !$self->{+FINITE}) {
        @files = sort { $a->rank <=> $b->rank || $a->file cmp $b->file } @files;
    }
    else {
        @files = sort { $a->file cmp $b->file } @files;
    }

    @files = grep { !$self->{+EXCLUDE_FILES}->{$_->file} } @files if keys %{$self->{+EXCLUDE_FILES}};

    #<<< no-tidy
    @files = grep { my $f = $_->file; !first { $f =~ m/$_/ } @{$self->{+EXCLUDE_PATTERNS}} } @files if @{$self->{+EXCLUDE_PATTERNS}};
    #>>>

    @files = grep { $_->check_category ne 'long' } @files if $self->{+NO_LONG};

    return @files;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Run - Test Run Configuration

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
