package Test2::Harness::Finder;
use strict;
use warnings;

our $VERSION = '1.000155';

use Test2::Harness::Util qw/clean_path mod2file/;
use Test2::Harness::Util::JSON qw/decode_json encode_json/;
use List::Util qw/first/;
use Cwd qw/getcwd/;
use Carp qw/croak/;
use Time::HiRes qw/time/;
use Text::ParseWords qw/quotewords/;

use Test2::Harness::TestFile;
use File::Spec;

use Test2::Harness::Util::HashBase qw{
    <default_search <default_at_search

    <durations <maybe_durations +duration_data <durations_threshold

    <exclude_files  <exclude_patterns <exclude_lists

    <no_long <only_long

    <rerun <rerun_modes <rerun_plugin

    search <extensions

    <multi_project

    <changed <changed_only <changes_plugin <show_changed_files <changes_diff
    <changes_filter_file <changes_filter_pattern
    <changes_exclude_file <changes_exclude_pattern
    <changes_include_whitespace <changes_exclude_nonsub
    <changes_exclude_loads <changes_exclude_opens
};

sub munge_settings {}

sub init {
    my $self = shift;

    $self->{+EXCLUDE_FILES} = { map {( $_ => 1 )} @{$self->{+EXCLUDE_FILES}} } if ref($self->{+EXCLUDE_FILES}) eq 'ARRAY';

    if (my $plugins = $self->{+RERUN_PLUGIN}) {
        for (@$plugins) {
            $_ = "App::Yath::Plugin::$_" unless s/^\+// or m/^(App::Yath|Test2::Harness)::Plugin::/;
            my $file = mod2file($_);
            require $file;
        }
    }
}

sub duration_data {
    my $self = shift;
    my ($plugins, $settings, $test_files) = @_;

    $self->{+DURATION_DATA} //= $self->pull_durations();

    return $self->{+DURATION_DATA} if $self->{+DURATION_DATA};

    for my $plugin (@$plugins) {
        next unless $plugin->can('duration_data');
        $self->{+DURATION_DATA} = $plugin->duration_data($settings, $test_files) or next;
        last;
    }

    return $self->{+DURATION_DATA} //= {};
}

sub pull_durations {
    my $self = shift;

    my $primary  = delete $self->{+MAYBE_DURATIONS};
    my $fallback = delete $self->{+DURATIONS};

    my @args = (
        name      => 'durations',
        is_json   => 1,
        http_args => [{headers => {'Content-Type' => 'application/json'}}],
    );

    if ($primary) {
        local $@;

        my $durations = eval { $self->_pull_from_file_or_url(source => $primary, @args) }
            or print "Could not fetch optional durations '$primary', ignoring...\n";

        if ($durations) {
            print "Found durations: $primary\n";
            return $durations;
        }
    }

    return $self->_pull_from_file_or_url(source => $fallback, @args)
        if $fallback;

    return;
}

sub add_exclusions_from_lists {
    my $self = shift;

    my @lists = ref($self->{+EXCLUDE_LISTS}) eq 'ARRAY' ? @{$self->{+EXCLUDE_LISTS}} : ($self->{+EXCLUDE_LISTS});

    for my $path (@lists) {
        my $content = $self->_pull_from_file_or_url(
            source => $path,
            name => 'exclusion lists',
        );

        next unless $content;

        for (split(/\r?\n\r?/, $content)) {
            $self->{+EXCLUDE_FILES}->{$_} = 1 unless /^\s*#/;
        };
    }
}

sub _pull_from_file_or_url {
    my $self = shift;
    my %params = @_;

    my $in   = $params{source} // croak "No file or url provided";
    my $name = $params{name}   // croak "No name provided";

    my $is_json = $params{is_json};

    if (my $type = ref($in)) {
        return $in if $is_json && ($type eq 'HASH' || $type eq 'ARRAY');
    }
    elsif (-f $in) {
        if ($is_json) {
            require Test2::Harness::Util::File::JSON;
            my $file = Test2::Harness::Util::File::JSON->new(name => $in);
            return $file->read();
        }
        else {
            require Test2::Harness::Util::File;
            my $f = Test2::Harness::Util::File->new(name => $in);
            return $f->read();
        }
    }
    elsif ($in =~ m{^https?://}) {
        my $meth = $params{http_method} // 'get';
        my $args = $params{http_args};

        require HTTP::Tiny;
        my $ht = HTTP::Tiny->new();
        my $res = $ht->$meth($in, $args ? (@$args) : ());

        die "Could not query $name from '$in'\n$res->{status}: $res->{reason}\n$res->{content}\n"
            unless $res->{success};

        return $is_json ? decode_json($res->{content}) : $res->{content};
    }

    die "Invalid $name specification: $in";
}

sub find_files {
    my $self = shift;
    my ($plugins, $settings) = @_;

    $self->add_exclusions_from_lists() if $self->{+EXCLUDE_LISTS};

    my $add_changes = 0;
    $add_changes ||= $self->{+CHANGED} && @{$self->{+CHANGED}};
    $add_changes ||= $self->{+CHANGED_ONLY};
    $add_changes ||= $self->{+CHANGES_PLUGIN};
    $add_changes ||= $self->{+CHANGES_DIFF};

    $self->add_changed_to_search($plugins, $settings) if $add_changes;

    my $add_rerun = $self->{+RERUN};
    $self->add_rerun_to_search($plugins, $settings, $add_rerun) if $add_rerun;

    return $self->find_multi_project_files($plugins, $settings) if $self->multi_project;

    return $self->find_project_files($plugins, $settings, $self->search);
}

sub check_plugins {
    my $self = shift;
    my ($plugins, $settings) = @_;

    my $check_plugins = $plugins;
    my $plugin;
    if (my $p = $self->{+CHANGES_PLUGIN}) {
        $plugin = $p =~ s/^\+// ? $p : "App::Yath::Plugin::$p";
        $check_plugins = [$plugin];
    }

    return $check_plugins // [];
}

sub get_diff {
    my $self = shift;
    my ($plugins, $settings) = @_;

    return (file => $self->{+CHANGES_DIFF}) if $self->{+CHANGES_DIFF};

    my $check_plugins = $self->check_plugins($plugins, $settings);

    for my $plugin (@$check_plugins) {
        if ($plugin->can('changed_diff')) {
            my ($type, $data) = $plugin->changed_diff($settings);
            next unless $type && $data;

            return ($type => $data);
        }
    }

    return ();
}

sub find_changes {
    my $self = shift;
    my ($plugins, $settings) = @_;

    my @listed_changes;
    @listed_changes = @{$self->{+CHANGED}} if $self->{+CHANGED};

    my ($type, $diff) = $self->get_diff($plugins, $settings);

    my (@found_changes);
    if ($type && $diff) {
        @found_changes = $self->changes_from_diff($type => $diff, $settings);
    }

    unless (@found_changes) {
        my $check_plugins = $self->check_plugins($plugins, $settings);

        for my $plugin (@$check_plugins) {
            next unless $plugin->can('changed_files');

            push @found_changes => $plugin->changed_files($settings);
            last if @found_changes;
        }
    }

    my $filter_patterns = @{$self->{+CHANGES_FILTER_PATTERN}} ? $self->{+CHANGES_FILTER_PATTERN} : undef;
    my $filter_files    = @{$self->{+CHANGES_FILTER_FILE}} ? {map { $_ => 1 } @{$self->{+CHANGES_FILTER_FILE}}} : undef;

    my $exclude_patterns = @{$self->{+CHANGES_EXCLUDE_PATTERN}} ? $self->{+CHANGES_EXCLUDE_PATTERN} : undef;
    my $exclude_files    = @{$self->{+CHANGES_EXCLUDE_FILE}} ? {map { $_ => 1 } @{$self->{+CHANGES_EXCLUDE_FILE}}} : undef;

    my %changed_map;
    for my $change (@listed_changes, @found_changes) {
        next unless $change;
        my ($file, @parts) = ref($change) ? @$change : ($change);

        next if $filter_files && !$filter_files->{$file};
        next if $exclude_files && $exclude_files->{$file};
        next if $filter_patterns && !first { $file =~ m/$_/ } @$filter_patterns;
        next if $exclude_patterns && first { $file =~ m/$_/ } @$exclude_patterns;

        @parts = ('*') unless @parts;
        $changed_map{$file}{$_} = 1 for @parts;
    }

    return \%changed_map;
}

sub get_capable_plugins {
    my $self = shift;
    my ($method, $plugins) = @_;

    my %seen;
    return grep { $_ && !$seen{$_}++ && $_->can($method) } @$plugins;
}

sub add_rerun_to_search {
    my $self = shift;
    my ($plugins, $settings, $rerun) = @_;

    my $search = $self->search;
    unless ($search) {
        $search = [];
        $self->set_search($search);
    }

    my $modes = $self->{+RERUN_MODES};
    my $mode_hash = { map {$_ => 1} @$modes };

    my ($grabbed, $data);
    for my $p ($self->get_capable_plugins(grab_rerun => [@{$self->{+RERUN_PLUGIN} // []}, @$plugins])) {
        ($grabbed, $data) = $p->grab_rerun($rerun, modes => $modes, mode_hash => $mode_hash, settings => $settings);
        next unless $grabbed;

        unless ($data && keys %$data) {
            print "No files found to rerun.\n";
            exit 0;
        }

        last if $grabbed;
    }

    unless ($grabbed) {
        if ($rerun eq '1') {
            $rerun = first { -e $_ } qw{ ./lastlog.jsonl ./lastlog.jsonl.bz2 ./lastlog.jsonl.gz };

            die "Could not find a lastlog.jsonl(.bz2|.gz) file for re-running, you may need to provide a full path to --rerun=... or --rerun-failed=..."
                unless $rerun;
        }

        die "'$rerun' is not a valid log file, and no plugin intercepted it.\n" unless -f $rerun;

        my $stream = Test2::Harness::Util::File::JSONL->new(name => $rerun, skip_bad_decode => 1);

        my %files;
        while (1) {
            my @events = $stream->poll(max => 1000) or last;

            for my $event (@events) {
                my $f = $event->{facet_data} or next;

                for my $type (qw/seen queued start end/) {
                    my $field = $type eq 'seen' ? "harness_job" : "harness_job_$type";

                    my $data = $f->{$field} or next;

                    my $file = $data->{rel_file} // $data->{run_file} // $data->{file} // $data->{abs_file};
                    next unless $file;

                    my $ref = $files{$file} //= {};
                    $ref->{$type}++;

                    $ref->{$data->{fail} ? 'fail' : 'pass'}++ if $type eq 'end';
                    $ref->{retry}++                           if $data->{is_try};
                }
            }
        }

        $data = \%files;
    }

    my @add = map { $data->{$_}->{add} // $_ } grep {
        my $entry = $data->{$_};

        my $keep = $mode_hash->{all} ? 1 : 0;
        $keep ||= 1 if $mode_hash->{failed}  && $entry->{fail} && !$entry->{pass};
        $keep ||= 1 if $mode_hash->{retried} && $entry->{retry};
        $keep ||= 1 if $mode_hash->{passed}  && $entry->{pass};
        $keep ||= 1 if $mode_hash->{missed}  && !$entry->{end};

        $keep
    } sort keys %$data;

    unless (@add) {
        print "No files found to rerun.\n";
        exit 0;
    }

    push @$search => @add;
}

sub add_changed_to_search {
    my $self = shift;
    my ($plugins, $settings) = @_;

    my $search = $self->search;
    unless ($search) {
        $search = [];
        $self->set_search($search);
    }

    my $changed_map = $self->find_changes($plugins, $settings);
    my $found_changed = keys %$changed_map;

    die "Could not find any changed files.\n" if $self->{+CHANGED_ONLY} && !$found_changed;

    if ($self->{+CHANGED_ONLY}) {
        die "Can not add test or directory names when using --changed-only (saw: " . join(", " => @$search) . ")\n"
            if @$search;
    }

    if ($self->{+SHOW_CHANGED_FILES} && $found_changed) {
        print "Found the following changed files:\n";
        for my $file (keys %$changed_map) {
            print "  $file: ", join(", ", sort keys %{$changed_map->{$file}}), "\n";
        }
    }

    my @add;
    for my $p ($self->get_capable_plugins(get_coverage_tests => $plugins)) {
        for my $set ($p->get_coverage_tests($settings, $changed_map)) {
            my $test = ref($set) ? $set->[0] : $set;

            unless (-e $test) {
                print STDERR "Coverage wants to run test '$test', but it does not exist, skipping...\n";
                next;
            }

            push @add => $set;
        }
    }

    for my $p ($self->get_capable_plugins(post_process_coverage_tests => $plugins)) {
        $p->post_process_coverage_tests($settings, \@add);
    }

    if ($self->{+SHOW_CHANGED_FILES} && @add) {
        print "Found " . scalar(@add) . " test files to run based on changed files.\n";
        print ref($_) ? "  $_->[0]" : "  $_\n" for @add;
        print "\n";
    }

    push @$search => @add;

    return;
}

sub changes_from_diff {
    my $self = shift;
    my ($type, $data, $settings) = @_;

    my $next;
    if ($type eq 'lines') {
        $next = sub { shift @$data };
    }
    elsif ($type eq 'diff') {
        my $lines = [split /\n/, $data];
        $next = sub { shift @$lines };
    }
    elsif ($type eq 'file') {
        die "'$data' is not a valid diff file.\n" unless -f $data;
        open(my $fh, '<', $data) or die "Could not open diff file '$data': $!";
        $next = sub {
            my $line = <$fh>;
            close($fh) unless defined $line;
            return $line;
        };
    }
    elsif ($type eq 'line_sub') {
        $next = $data;
    }
    elsif ($type eq 'handle') {
        $next = sub { scalar <$data> };
    }
    else {
        die "Invalid diff type '$type'";
    }

    my %changed;

    # Only perl can parse perl, and nothing can parse perl diff. What this does
    # is take a diff of every file with 100% context so we see the entire file
    # with the +, minus, or space prefix. As we scan it we look for subs. We
    # track what files and subs we are in. When we see a change we
    # {$file}{$sub}++.
    #
    # This of course is broken if you make a change between
    # subs as it will attribute it to the previous sub, however tracking
    # indentation is equally flawed as things like heredocs and other special
    # perl things can also trigger that to prematurely think we are out of a
    # sub.
    #
    # PPI and similar do a better job parsing perl, but using them and also
    # tracking changes from the diff, or even asking them to parse a diff where
    # some lines are added and others removed is also a huge hassle.
    #
    # The current algorith is "good enough", not perfect.
    my ($file, $sub, $indent, $is_perl);
    while (my $line = $next->()) {
        chomp($line);
        if ($line =~ m{^(?:---|\+\+\+) ([ab]/)?(.*)$}) {
            my $maybe_prefix = $1;
            my $maybe_file = $2;
            next if $maybe_file =~ m{/dev/null};
            if ($maybe_prefix) {
                $file = -f "$maybe_prefix$maybe_file" ? "$maybe_prefix$maybe_file" : $maybe_file;
            }
            else {
                $file = $maybe_file;
            }
            $is_perl = 1 if $file =~ m/\.(pl|pm|t2?)$/;
            $sub  = '*'; # Wildcard, changes to the code outside of a sub potentially effects all subs
            next;
        }

        next unless $file;

        $line =~ m/^( |-|\+)(.*)$/ or next;
        my ($prefix, $statement) = ($1, $2);
        my $changed = $prefix eq ' ' ? 0 : 1;

        $is_perl = 1 if $statement =~ m/^#!.*perl/;

        if ($statement =~ m/^(\s*)sub\s+(\w+)/) {
            $indent = $1 // '';
            $sub = $2;

            # 1-line sub: sub foo { ... }
            if ($statement =~ m/}/) {
                $changed{$file}{$sub}++ if $changed;
                $sub = '*';
                $indent = undef;
                next;
            }
        }
        elsif(defined($indent) && $statement =~ m/^$indent\}/) {
            $indent = undef;
            $sub = "*";

            # If this is nothing but whitespace and a closing paren we can skip it.
            next if $statement =~ m/^\s*\}?\s*$/ && !$self->{+CHANGES_INCLUDE_WHITESPACE};
        }

        next unless $sub;   # If sub is empty then we are not even in a file yet
        next unless $changed; # If we are not on a changed line no need to add it
        unless ($self->{+CHANGES_INCLUDE_WHITESPACE}) {
            next if !length($statement); # If there is no statement length then this is whitespace only
            next if $statement =~ m/^\s+$/; # Do not care about whitespace only changes
        }

        next if $is_perl && $self->{+CHANGES_EXCLUDE_NONSUB} && $sub eq '*';

        $changed{$file}{$sub}++;
    }

    return map {([$_ => sort keys %{$changed{$_}}])} sort keys %changed;
}


sub find_multi_project_files {
    my $self = shift;
    my ($plugins, $settings) = @_;

    my $search = $self->search // [];

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

            for my $item (@{$self->find_project_files($plugins, $settings, [])}) {
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

sub find_project_files {
    my $self = shift;
    my ($plugins, $settings, $input) = @_;

    $input   //= [];
    $plugins //= [];

    my $default_search = [@{$self->default_search}];
    push @$default_search => @{$self->default_at_search} if $settings->check_prefix('run') && $settings->run->author_testing;

    $_->munge_search($input, $default_search, $settings) for @$plugins;

    my $search = @$input ? $input : $self->{+CHANGED_ONLY} ? [] : $default_search;

    die "No tests to run, search is empty\n" unless @$search;


    my (%seen, @tests, @dirs);

    for my $item (@$search) {
        my ($path, $test_params);

        if (ref $item) {
            ($path, $test_params) = @$item;
        }
        else {
            my ($type, $data);
            ($path, $type, $data) = split /(:<|:@|:=)/, $item, 2;
            if ($type && $data) {
                $test_params = {};
                if ($type eq ':<') {
                    $test_params->{stdin} = $data;
                }
                elsif ($type eq ':@') {
                    $test_params->{argv} = decode_json($data);
                }
                elsif ($type eq ':=') {
                    $test_params->{env} = decode_json($data);
                }
            }
        }

        push @dirs => $path and next if -d $path;

        unless(-f $path) {
            my ($actual, $args) = split /=/, $path, 2;
            if (-f $actual) {
                $path = $actual;
                $test_params = {%{$test_params // {}}, argv => [quotewords('\s+', 0, $args)]};
            }
            else {
                die "'$path' is not a valid file or directory.\n" if @$input;
                next;
            }
        }

        $path = clean_path($path, 0);
        $seen{$path}++;

        my $test;
        unless (first { $test = $_->claim_file($path, $settings, from => 'listed') } @$plugins) {
            $test = Test2::Harness::TestFile->new(file => $path);
        }

        if (my @exclude = $self->exclude_file($test)) {
            if (@$input) {
                print STDERR "File '$path' was listed on the command line, but has been exluded for the following reasons:\n";
                print STDERR "  $_\n" for @exclude;
            }

            next;
        }

        if ($test_params) {
            $test->set_input($test_params->{stdin})    if $test_params->{stdin};
            $test->set_test_args($test_params->{argv}) if $test_params->{argv};
            $test->set_env_vars($test_params->{env})   if $test_params->{env};
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

                    my $file = clean_path($File::Find::name, 0);

                    return if $seen{$file}++;
                    return unless -f $file;

                    my $test;
                    unless(first { $test = $_->claim_file($file, $settings, from => 'search') } @$plugins) {
                        for my $ext (@{$self->extensions}) {
                            next unless m/\.\Q$ext\E$/;
                            $test = Test2::Harness::TestFile->new(file => $file);
                            last;
                        }
                    }

                    return unless $test;
                    return unless $self->include_file($test);
                    push @tests => $test;
                },
            },
            @dirs
        );
    }

    my $test_count = @tests;
    my $threshold = $settings->finder->durations_threshold // 0;
    if ($threshold && $test_count >= $threshold) {
        my $start = time;
        my $durations = $self->duration_data($plugins, $settings, [map { $_->relative } @tests]);
        my $end = time;
        if ($durations && keys %$durations) {
            printf("Fetched duration data (Took %0.2f seconds)\n", $end - $start);
            for my $test (@tests) {
                my $rel = $test->relative;
                $test->set_duration($durations->{$rel}) if $durations->{$rel};
            }
        }
    }

    $_->munge_files(\@tests, $settings) for @$plugins;

    return [ sort { $a->rank <=> $b->rank || $a->file cmp $b->file } @tests ];
}

sub include_file {
    my $self = shift;
    my ($test) = @_;

    my @exclude = $self->exclude_file($test);

    return !@exclude;
}

sub exclude_file {
    my $self = shift;
    my ($test) = @_;

    my @out;

    push @out => "File has a do-not-run directive inside it." unless $test->check_feature(run => 1);

    my $full = $test->file;
    my $rel  = $test->relative;

    push @out => 'File is in the exclude list.' if $self->exclude_files->{$full} || $self->exclude_files->{$rel};
    push @out => 'File matches an exclusion pattern.' if first { $rel =~ m/$_/ } @{$self->exclude_patterns};

    push @out => 'File is marked as "long", but the "no long tests" opition was specified.'
        if $self->no_long && $test->check_duration eq 'long';

    push @out => 'File is not marked "long", but the "only long tests" option was specified.'
        if $self->only_long && $test->check_duration ne 'long';

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Finder - Library that searches for test files

=head1 DESCRIPTION

The finder is responsible for locating test files that should be run. You can
subclass the finder and instruct yath to use your subclass.

=head1 SYNOPSIS

=head2 USING A CUSTOM FINDER

To use Test2::Harness::Finder::MyFinder:

    $ yath test --finder MyFinder

To use Another::Finder

    $ yath test --finder +Another::Finder

By default C<Test2::Harness::Finder::> is prefixed onto your custom finder, use
'+' before the class name or prevent this.

=head2 SUBCLASSING

    use parent 'Test2::Harness::Finder';
    use Test2::Harness::TestFile;

    # Custom finders may provide their own options if desired.
    # This is optional.
    use App::Yath::Options;
    option foo => (
        ...
    );

    # This is the main method to override.
    sub find_project_files {
        my $self = shift;
        my ($plugins, $settings, $search) = @_;

        return [
            Test2::Harness::TestFile->new(...),
            Test2::Harness::TestFile->new(...),
            ...,
        ];
    }

=head1 METHODS

These are important state methods, as well as utility methods for use in your
subclasses.

=over 4

=item $bool = $finder->multi_project

True if the C<yath projects> command was used.

=item $arrayref = $finder->find_files($plugins, $settings)

This is the main method. This method returns an arrayref of
L<Test2::Harness::TestFile> instances, each one representing a single test to
run.

$plugins is a list of plugins, some may be class names, others may be
instances.

$settings is an L<Test2::Harness::Settings> instance.

B<Note:> In many cases it is better to override C<find_project_files()> in your
subclasses.

=item $durations = $finder->duration_data

This will fetch the durations data if any was provided. This is a hashref of
relative test paths as keys where the value is the duration of the file (SHORT,
MEDIUM or LONG).

B<Note:> The result is cached, see L<pull_durations()> to refresh the data.

=item @reasons = $finder->exclude_file($test)

The input argument should be an L<Test2::Harness::Test> instance. This will
return a list of human readible reasons a test file should be excluded. If the
file should not be excluded the list will be empty.

This is a utility method that verifies the file is not in an exclude
list/pattern. The reasons are provided back in case you need to inform the
user.

=item $bool = $finder->include_file($test)

The input argument should be an L<Test2::Harness::Test> instance. This is a
convenience method around C<exclude_file()>, it will return true when
C<exclude_file()> returns an empty list.

=item $arrayref = $finder->find_multi_project_files($plugins, $settings)

=item $arrayref = $finder->find_project_files($plugins, $settings, $search)

These do the heavy lifting for C<find_files>

The default C<find_files()> implementation is this:

    sub find_files {
        my $self = shift;
        my ($plugins, $settings) = @_;

        return $self->find_multi_project_files($plugins, $settings) if $self->multi_project;
        return $self->find_project_files($plugins, $settings, $self->search);
    }

Each one returns an arrayref of L<Test2::Harness::TestFile> instances.

Note that C<find_multi_project_files()> uses C<find_project_files()> internall,
once per project directory.

$plugins is a list of plugins, some may be class names, others may be
instances.

$settings is an L<Test2::Harness::Settings> instance.

$search is an arrayref of search paths.

=item $finder->munge_settings($settings, $options)

A callback that lets you munge settings and options.

=item $finder->pull_durations

This will fetch the durations data if ant was provided. This is a hashref of
relative test paths as keys where the value is the duration of the file (SHORT,
MEDIUM or LONG).

L<duration_data()> is a cached version of this. This method will refresh the
cache for the other.

=back

=head2 FROM SETTINGS

See L<App::Yath::Options::Finder> for up to date documentation on these.

=over 4

=item $finder->default_search

=item $finder->default_at_search

=item $finder->durations

=item $finder->maybe_durations

=item $finder->exclude_files

=item $finder->exclude_patterns

=item $finder->no_long

=item $finder->only_long

=item $finder->search

=item $finder->extensions

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
