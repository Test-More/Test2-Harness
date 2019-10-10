package Test2::Harness::Run;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/croak/;

use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::Util qw/write_file_atomic clean_path/;

use Test2::Harness::TestFile;
use Test2::Harness::Util::Queue;

use List::Util qw/first/;

use HTTP::Tiny;
use File::Spec;

use Test2::Harness::Util::HashBase qw{
    <run_id

    <default_search <default_at_search

    <durations <maybe_durations +duration_data

    <env_vars <author_testing <unsafe_inc

    <event_uuids
    <use_stream
    <mem_usage

    <exclude_files  <exclude_patterns

    <no_long <only_long

    <input <input_file

    <search <test_args

    <load <load_import

    <fields <meta

    <retry <retry_isolated
};

sub init {
    my $self = shift;

    croak "run_id is required"
        unless $self->{+RUN_ID};

    $self->{+EXCLUDE_FILES} = { map {( $_ => 1 )} @{$self->{+EXCLUDE_FILES}} } if ref($self->{+EXCLUDE_FILES}) eq 'ARRAY';
}

sub run_dir {
    my $self = shift;
    my ($workdir) = @_;
    return File::Spec->catfile($workdir, $self->{+RUN_ID});
}

sub queue {
    my $self = shift;
    my ($run_dir) = @_;
    return Test2::Harness::Util::Queue->new(file => File::Spec->catfile($run_dir, 'queue.jsonl'));
}

sub write_queue {
    my $self = shift;
    my ($workdir, $plugins) = @_;

    my $run_dir = $self->run_dir($workdir);
    mkdir($run_dir) or die "Could not create run-dir '$run_dir': $!";

    my $queue = $self->queue($run_dir);
    $queue->start;

    my $job_count = 0;
    $queue->enqueue($_->queue_item(++$job_count)) for @{$self->find_files($plugins)};
    $queue->end;

    return $job_count;
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

sub duration_data {
    my $self = shift;
    return $self->{+DURATION_DATA} //= $self->pull_durations() // {};
}

sub pull_durations {
    my $self = shift;

    my $primary  = delete $self->{+MAYBE_DURATIONS} || [];
    my $fallback = delete $self->{+DURATIONS};

    for my $path (@$primary) {
        local $@;
        my $durations = eval { $self->_pull_durations($path) } or print "Could not fetch optional durations '$path', ignoring...\n";
        next unless $durations;

        print "Found durations: $path\n";
        return $self->{+DURATION_DATA} = $durations;
    }

    return $self->{+DURATION_DATA} = $self->_pull_durations($fallback)
        if $fallback;
}

sub _pull_durations {
    my $self = shift;
    my ($in) = @_;

    if (my $type = ref($in)) {
        return $self->{+DURATIONS} = $in if $type eq 'HASH';
    }
    elsif ($in =~ m{^https?://}) {
        my $ht = HTTP::Tiny->new();
        my $res = $ht->get($in, {headers => {'Content-Type' => 'application/json'}});

        die "Could not query durations from '$in'\n$res->{status}: $res->{reason}\n$res->{content}"
            unless $res->{success};

        return $self->{+DURATIONS} = decode_json($res->{content});
    }
    elsif(-f $in) {
        require Test2::Harness::Util::File::JSON;
        my $file = Test2::Harness::Util::File::JSON->new(name => $in);
        return $self->{+DURATIONS} = $file->read();
    }

    die "Invalid duration specification: $in";
}

sub find_files {
    my $self = shift;
    my ($plugins) = @_;

    $plugins //= [];

    my $have_list = 1;
    my $search = $self->{+SEARCH} // [];
    unless (@$search || first { $_->block_default_search() } @$plugins) {
        $have_list = 0;
        push @$search => @{$self->{+DEFAULT_SEARCH}};
        push @$search => @{$self->{+DEFAULT_AT_SEARCH}} if $self->{+AUTHOR_TESTING};
    }

    my (@dirs, %listed, @files, @found, @claimed, %seen);
    for my $path (@$search) {
        push @dirs => $path and next if -d $path;
        if (-f $path) {
            $path = clean_path($path);
            $listed{$path}++ if $have_list;
            push @files => $path;
            next;
        }
        die "'$path' is not a valid file or directory.\n";
    }

    for my $plugin (@$plugins) {
        my $class = ref($plugin) || $plugin;

        for my $test ($plugin->find_files($self, \@dirs)) {
            die "$class\->find_files returned an '$test' instead of an instance of Test2::Harness::TestFile, please correct this.\n"
                unless $test->isa('Test2::Harness::TestFile');

            my $file = $test->file;

            die "Plugin '$class' tried to add '$file', but it was already added by '$seen{$file}'.\n" if $seen{$file};

            $seen{$file} = $class;
            push @claimed => $test;
        }
    }

    if (@dirs) {
        require File::Find;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    no warnings 'once';
                    return unless -f $_ && m/\.t2?$/;
                    push @files => clean_path($File::Find::name);
                },
            },
            @dirs
        );
    }

    for my $file (@files) {
        next if $seen{$file};

        for my $plugin (@$plugins) {
            my $test = $plugin->claim_file($file) or next;

            my $class = ref($plugin);
            die "$class\->find_files returned an '$test' instead of an instance of Test2::Harness::TestFile, please correct this.\n"
                unless $test->isa('Test2::Harness::TestFile');

            $seen{$file} = $class;
            push @claimed => $test;
            last;
        }

        next if $seen{$file};
        $seen{$file} = ref($self);
        my $test = Test2::Harness::TestFile->new(file => $file);
        push @found => $test;
    }

    my @out = grep { $self->_include_file($_) || $listed{$_->file} } @claimed, @found;

    $_->munge_files(\@out) for @$plugins;

    return [ sort { $a->rank <=> $b->rank || $a->file cmp $b->file } @out ];
}

sub _include_file {
    my $self = shift;
    my ($test) = @_;

    return 0 unless $test->check_feature(run => 1);

    my $full = $test->file;
    my $rel  = $test->relative;

    return 0 if $self->{+EXCLUDE_FILES}->{$full};
    return 0 if $self->{+EXCLUDE_FILES}->{$rel};
    return 0 if first { $rel =~ m/$_/ } @{$self->{+EXCLUDE_PATTERNS}};

    my $durations = $self->duration_data;
    $test->set_duration($durations->{$rel}) if $durations->{$rel};

    return 0 if $self->{+NO_LONG}   && $test->check_duration eq 'long';
    return 0 if $self->{+ONLY_LONG} && $test->check_duration ne 'long';

    return 1;
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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
