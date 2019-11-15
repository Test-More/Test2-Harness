package Test2::Harness::Run;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/croak/;
use Cwd qw/getcwd/;

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

    <links

    <event_uuids
    <use_stream
    <mem_usage

    <exclude_files  <exclude_patterns

    <no_long <only_long

    <input <input_file

    <search <test_args <extensions

    <load <load_import

    <fields <meta

    <retry <retry_isolated

    <multi_project
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
    my ($plugins, $settings) = @_;

    return $self->_find_project_files($plugins, $settings) if $self->multi_project;
    return $self->_find_files($plugins, $settings, $self->{+SEARCH});
}

sub _find_project_files {
    my $self = shift;
    my ($plugins, $settings) = @_;

    my $search = $self->{+SEARCH} // [];

    die "multi-project search must be a single directory, or the current directory" if @$search > 1;
    my ($pdir) = @$search;
    my $dir = clean_path(getcwd());

    my $out = [];
    my $ok = eval {
        chdir($pdir) if defined $pdir;
        my $ret = clean_path(getcwd());

        opendir(my $dh, '.') or die "Could not open project dir: $!";
        for my $subdir (readdir($dh)) {
            chdir($ret);

            next if $subdir =~ m/^\./;
            my $path = clean_path(File::Spec->catdir($ret, $subdir));
            next unless -d $path;

            chdir($path) or die "Could not chdir to $path: $!\n";

            for my $item (@{$self->_find_files($plugins, $settings, [])}) {
                push @{$item->queue_args} => ('ch_dir' => $path);
                push @$out => $item;
            }
        }

        chdir($ret);
        1;
    };
    my $err = $@;

    chdir($dir);
    die $err unless $ok;

    return $out;
}

sub _find_files {
    my $self = shift;
    my ($plugins, $settings, $input) = @_;

    $input   //= [];
    $plugins //= [];

    my $default_search = [@{$self->default_search}];
    push @$default_search => @{$self->default_at_search} if $self->author_testing;

    $_->munge_search($self, $input, $default_search, $settings) for @$plugins;

    my $search = @$input ? $input : $default_search;

    die "No tests to run, search is empty\n" unless @$search;

    my (%seen, @tests, @dirs);
    for my $path (@$search) {
        push @dirs => $path and next if -d $path;

        unless(-f $path) {
            die "'$path' is not a valid file or directory.\n" if @$input;
            next;
        }

        $path = clean_path($path);
        $seen{$path}++;

        my $test;
        unless (first { $test = $_->claim_file($path, $settings) } @$plugins) {
            $test = Test2::Harness::TestFile->new(file => $path);
            next unless @$input || $self->_include_file($test);
        }

        push @tests => $test;
    }

    if (@dirs) {
        require File::Find;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    no warnings 'once';

                    my $file = clean_path($File::Find::name);

                    return if $seen{$file}++;
                    return unless -f $file;

                    my $test;
                    unless(first { $test = $_->claim_file($file, $settings) } @$plugins) {
                        for my $ext (@{$self->{+EXTENSIONS}}) {
                            next unless m/\.\Q$ext\E$/;
                            $test = Test2::Harness::TestFile->new(file => $file);
                            last;
                        }
                    }

                    return unless $test && $self->_include_file($test);
                    push @tests => $test;
                },
            },
            @dirs
        );
    }

    $_->munge_files($self, \@tests, $settings) for @$plugins;

    return [ sort { $a->rank <=> $b->rank || $a->file cmp $b->file } @tests ];
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
