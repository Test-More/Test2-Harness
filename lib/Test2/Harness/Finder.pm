package Test2::Harness::Finder;
use strict;
use warnings;

our $VERSION = '1.000058';

use Test2::Harness::Util qw/clean_path mod2file/;
use Test2::Harness::Util::JSON qw/decode_json encode_json/;
use List::Util qw/first/;
use Cwd qw/getcwd/;
use Carp qw/croak/;

use Test2::Harness::TestFile;
use File::Spec;

use Test2::Harness::Util::HashBase qw{
    <default_search <default_at_search

    <durations <maybe_durations +duration_data

    <exclude_files  <exclude_patterns <exclude_lists

    <no_long <only_long

    search <extensions

    <multi_project

    <changed <changed_only <changes_plugin <show_changed_files <changes_diff
    <changes_filter_file <changes_filter_pattern
    +coverage_data <coverage_from <maybe_coverage_from
    <coverage_manager
};

sub munge_settings {}

sub init {
    my $self = shift;

    $self->{+EXCLUDE_FILES} = { map {( $_ => 1 )} @{$self->{+EXCLUDE_FILES}} } if ref($self->{+EXCLUDE_FILES}) eq 'ARRAY';
}

sub duration_data {
    my $self = shift;
    my ($plugins, $settings) = @_;

    $self->{+DURATION_DATA} //= $self->pull_durations();

    return $self->{+DURATION_DATA} if $self->{+DURATION_DATA};

    for my $plugin (@$plugins) {
        next unless $plugin->can('duration_data');
        $self->{+DURATION_DATA} = $plugin->duration_data($settings) or next;
        last;
    }

    return $self->{+DURATION_DATA} //= {};
}

sub coverage_data {
    my $self = shift;
    my ($plugins, $changed, $settings) = @_;

    $self->{+COVERAGE_DATA} //= $self->pull_coverage($changed);
    return $self->{+COVERAGE_DATA} if $self->{+COVERAGE_DATA};

    for my $plugin (@$plugins) {
        next unless $plugin->can('coverage_data');
        $self->{+COVERAGE_DATA} = $plugin->coverage_data($changed, $settings) or next;
        last;
    }

    return $self->{+COVERAGE_DATA} //= {};
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

sub pull_coverage {
    my $self = shift;
    my ($changed) = @_;

    my $primary  = delete $self->{+MAYBE_COVERAGE_FROM};
    my $fallback = delete $self->{+COVERAGE_FROM};

    my $aggregator;

    my %args = (
        name      => 'coverage',
        is_json   => 1,
        http_args => [{headers => {'Content-Type' => 'application/json'}}],

        log_event_handler => sub {
            my ($event) = @_;

            unless ($aggregator) {
                require Test2::Harness::Log::CoverageAggregator;
                $aggregator = Test2::Harness::Log::CoverageAggregator->new();
            }

            $aggregator->process_event($event);
        },

        log_return_builder => sub {
            return unless $aggregator;
            return $aggregator->coverage;
        },
    );

    if ($primary) {
        local $@;

        my $coverage = eval { $self->_pull_from_log_or_file_or_url(source => $primary, %args) }
            or print "Could not fetch optional coverage '$primary', ignoring...\n";

        if ($coverage) {
            print "Found coverage: $primary\n";
            return $coverage;
        }
    }

    return $self->_pull_from_log_or_file_or_url(source => $fallback, %args)
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

sub _pull_from_log_or_file_or_url {
    my $self = shift;
    my %params = @_;

    my $in = $params{source} // croak "No file or url provided";

    return $self->_pull_from_file_or_url(%params)
        unless $in =~ m/\.jsonl(?:\.(?:gz|bz2))?$/;

    require Test2::Harness::Util::File::JSONL;
    my $jsonl = Test2::Harness::Util::File::JSONL->new(name => $in);

    while (1) {
        my @items = $jsonl->poll(max => 1000) or last;
        $params{log_event_handler}->($_) for @items;
    }

    return $params{log_return_builder}->();
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

    $self->add_changed_to_search($plugins, $settings)
        if $self->{+CHANGED} || $self->{+CHANGED_ONLY} || $self->{+CHANGES_PLUGIN} || $self->{+CHANGES_DIFF};

    return $self->find_multi_project_files($plugins, $settings) if $self->multi_project;

    return $self->find_project_files($plugins, $settings, $self->search);
}

sub add_changed_to_search {
    my $self = shift;
    my ($plugins, $settings) = @_;

    my $search = $self->search;
    unless ($search) {
        $search = [];
        $self->set_search($search);
    }

    my @listed_changes = @{$self->{+CHANGED}} if $self->{+CHANGED};

    my $check_plugins = $plugins;
    if (my $plugin = $self->{+CHANGES_PLUGIN}) {
        $plugin = "App::Yath::Plugin::$plugin"
            unless $plugin =~ s/^\+//;

        $check_plugins = [$plugin];
    }

    my (@diff_changes, @found_changes);
    if (my $diff = $self->{+CHANGES_DIFF}) {
        @found_changes = $self->_changes_from_diff(file => $diff, $settings);
    }
    else {
        for my $plugin (@$check_plugins) {
            if ($plugin->can('changed_diff')) {
                my ($type, $data) = $plugin->changed_diff($settings);
                next unless $type && $data;

                @found_changes = $self->_changes_from_diff($type, $data, $settings);

                # Only use a diff from the first plugin to have one.
                last if @found_changes;
            }
            elsif ($plugin->can('changed_files')) {
                push @found_changes => $plugin->changed_files($settings)
            }
        }
    }

    # listed changes always included, diff changes OR found changes, not both.
    my @changed = (@listed_changes, @diff_changes ? @diff_changes : @found_changes);

    my $filter_files    = $self->{+CHANGES_FILTER_FILE};
    my $filter_patterns = $self->{+CHANGES_FILTER_PATTERN};

    if (($filter_files && @$filter_files) || ($filter_patterns && @$filter_patterns)) {
        my %files = map {$_ => 1} @{$self->{+CHANGES_FILTER_FILE} || []};
        my @keep;
        for my $set (@changed) {
            my ($file) = @$set;

            if ($files{$file}) {
                push @keep => $set;
                next;
            }

            my $patterns = $self->{+CHANGES_FILTER_PATTERN} // next;
            for my $pattern (@$patterns) {
                next unless $file =~ m/$pattern/;
                push @keep => $set;
                last;
            }
        }

        @changed = @keep;
    }

    die "Could not find any changed files.\n" if $self->{+CHANGED_ONLY} && !@changed;
    return unless @changed;

    if ($self->{+SHOW_CHANGED_FILES}) {
        print "Found the following changed files:\n";
        for my $change (@changed) {
            my ($file, @parts) = ref($change) ? @$change : ($change, '*');
            @parts = ('*') unless @parts;
            print "  $file: ", join(", ", @parts), "\n";
        }
    }

    my $coverage_data = $self->coverage_data($plugins, \@changed, $settings);
    my $type = ref($coverage_data);

    # We must have posted the changes and got a list of tests back.
    if ($type eq 'ARRAY') {
        push @$search => @$coverage_data;
        return;
    }

    if ($self->{+CHANGED_ONLY}) {
        die "Could not get any coverage data, no way to map changed files to tests.\n"
            unless $coverage_data;

        die "Can not add test or directory names when using --changed-only (saw: " . join(", " => @$search) . ")\n"
            if @$search;
    }

    my $filemap  = $coverage_data->{files}    // {};
    my $testmeta = $coverage_data->{testmeta} // {};

    my %tests;
    for my $change (@changed) {
        my ($file, @parts) = ref($change) ? @$change : ($change, '*');

        if (!@parts || grep {$_ eq '*'} @parts) {
            @parts = keys %{$filemap->{$file}};
        }

        my %seen;
        for my $part (@parts) {
            next if $seen{$part}++;
            my $ctests = $filemap->{$file}->{$part} or next;
            for my $test (keys %$ctests) {
                push @{$tests{$test}->{subs}} => @{$ctests->{$test}};
            }
        }

        if (my $ltests = $filemap->{$file}->{'*'}) {
            for my $test (keys %$ltests) {
                push @{$tests{$test}->{loads}} => @{$ltests->{$test}};
            }
        }

        if (my $otests = $filemap->{$file}->{'<>'}) {
            for my $test (keys %$otests) {
                push @{$tests{$test}->{opens}} => @{$otests->{$test}};
            }
        }
    }

    my $count = 0;
    for my $test (sort keys %tests) {
        my $meta = $testmeta->{$test} // {type => 'flat'};
        my $type = $meta->{type};
        my $manager = $meta->{manager} // $self->coverage_manager;

        # In these cases we have no choice but to run the entire file
        if ($type eq 'flat' || !$manager) {
            $count++;
            push @$search => $test;
            next;
        }

        die "Invalid test type: $type" unless $type eq 'split';

        my $froms = $tests{$test} // [];
        my $ok = eval {
            require(mod2file($manager));
            my $specs = $manager->test_parameters($test, $froms);

            $specs = { run => $specs } unless ref $specs;

            # Intentional skip
            return 1 if defined $specs->{run} && !$specs->{run};

            $count++;
            push @$search => [$test, $specs];

            1;
        };
        my $err = $@;

        next if $ok;

        $count++;
        warn "Error processing coverage data for '$test' using manager '$manager'. Running entire test to be safe.\nError:\n====\n$@\n====\n";
        push @$search => $test;
    }

    if ($self->{+SHOW_CHANGED_FILES}) {
        print "Found $count test files to run based on changed files.\n\n";
    }

    return;
}

sub _changes_from_diff {
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
    my ($file, $sub, $indent);
    while (my $line = $next->()) {
        chomp($line);
        if ($line =~ m{^(?:---|\+\+\+) [ab]/(.*)$}) {
            my $maybe_file = $1;
            next if $maybe_file =~ m{/dev/null};
            $file = $maybe_file;
            $sub  = '*'; # Wildcard, changes to the code outside of a sub potentially effects all subs
            $changed{$file} //= {};
            next;
        }

        next unless $file;

        $line =~ m/^( |-|\+)(.*)$/ or next;
        my ($prefix, $statement) = ($1, $2, $3);
        my $changed = $prefix eq ' ' ? 0 : 1;

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
        }

        next unless $sub;

        $changed{$file}{$sub}++ if $changed;
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

    my $durations = $self->duration_data($plugins, $settings);

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
            die "'$path' is not a valid file or directory.\n" if @$input;
            next;
        }

        $path = clean_path($path, 0);
        $seen{$path}++;

        my $test;
        unless (first { $test = $_->claim_file($path, $settings) } @$plugins) {
            $test = Test2::Harness::TestFile->new(file => $path);
        }

        my $rel = $test->relative;
        $test->set_duration($durations->{$rel}) if $durations->{$rel};
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
                    unless(first { $test = $_->claim_file($file, $settings) } @$plugins) {
                        for my $ext (@{$self->extensions}) {
                            next unless m/\.\Q$ext\E$/;
                            $test = Test2::Harness::TestFile->new(file => $file);
                            last;
                        }
                    }

                    return unless $test;
                    my $rel = $test->relative;
                    $test->set_duration($durations->{$rel}) if $durations->{$rel};
                    return unless $self->include_file($test);
                    push @tests => $test;
                },
            },
            @dirs
        );
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
