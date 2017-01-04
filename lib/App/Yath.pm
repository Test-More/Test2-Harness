package App::Yath;
use strict;
use warnings;

our $VERSION = '0.000014';

use Test2::Util::HashBase qw/args harness files exclude renderers/;
use Test2::Util qw/pkg_to_file/;

use Test2::Harness;
use Test2::Harness::Parser;
use Test2::Harness::Runner;

use Getopt::Long qw/GetOptionsFromArray/;

sub run {
    my $self = shift;
    my $results = $self->{+HARNESS}->run(@{$self->{+FILES}});

    $_->summary($results) for @{$self->{+RENDERERS}};

    my $failed = grep {!$_->passed} @$results;
    return $failed;
}

sub init {
    my $self = shift;
    $self->{+ARGS} ||= [];
    my @args = @{$self->{+ARGS}};

    my (%env, @libs, @switches);
    my %harness_args = (
        env_vars => \%env,
        libs     => \@libs,
        switches => \@switches,

        parser_class => '+Test2::Harness::Parser',
    );

    my (@exclude, @render, @preload);
    my $color   = -t STDOUT ? 1 : 0;
    my $jobs    = 1;
    my $merge   = 0;
    my $verbose = 0;
    my $quiet   = 0;
    my $timeout = 0;

    my $runner_class = '+Test2::Harness::Runner';

    Getopt::Long::Configure("bundling");
    GetOptionsFromArray \@args => (
        'l|lib'         => sub {
            push @libs, 'lib';
        },
        'b|blib'        => sub {
            push @libs, 'blib/lib', 'blib/arch';
        },
        'I|include=s@'  => \@libs,
        'R|renderer=s@' => \@render,
        'L|preload=s@'  => \@preload,

        'c|color=i'     => \$color,
        'h|help'        => \&help,
        'j|jobs=i'      => \$jobs,
        'm|merge'       => \$merge,
        'q|quiet'       => \$quiet,
        'v|verbose'     => \$verbose,
        'x|exclude=s@'  => \@exclude,
        't|timeout=i'   => \$timeout,

        'parser|parser_class=s' => \$harness_args{parser_class},
        'runner|runner_class=s' => \$runner_class,

        'S|switch=s@' => sub {
            push @switches => split '=', $_[1];
        },
    ) or die "Could not parse the command line options given.\n";

    die "You cannot combine preload (-L) with switches (-S).\n"
        if @preload && @switches;

    unshift @render => 'EventStream'
        unless $quiet;

    {
        local $ENV{TB_NO_EARLY_INIT} = 1;
        local @INC = (@libs, @INC);
        load_module('', $_) for @preload;
        load_module('Test2::Harness::Runner::', $runner_class) if $runner_class;
        load_module('Test2::Harness::Parser::', $harness_args{parser_class}) if $harness_args{parser_class};
        load_module('Test2::Harness::Renderer::', $_) for @render;
    }

    $harness_args{timeout} = $timeout;
    $harness_args{jobs}    = $jobs;
    $harness_args{runner}  = $runner_class->new(merge => $merge, via => @preload ? 'do' : 'open3');

    my @renderers;
    for my $r (@render) {
        push @renderers => $r->new(
            color    => $color,
            parallel => $jobs,
            verbose  => $verbose,
        );
    }

    $harness_args{listeners} = [ map { $_->listen } @renderers ];

    $self->{+RENDERERS} = \@renderers;
    $self->{+HARNESS}   = Test2::Harness->new(%harness_args, verbose => $verbose);

    $self->{+EXCLUDE} = \@exclude;
    $self->{+FILES} = $self->expand_files(@args);
}

sub load_module {
    my $prefix = shift;
    $prefix = '' if $_[0] =~ s/^\+//;
    $_[0] = "${prefix}$_[0]" if $prefix;
    require(pkg_to_file($_[0]));
}

sub expand_files {
    my $self = shift;

    my @in = @_;
    push @in => 't' if !@in && -d 't';

    my (@files, @dirs);
    for my $f (@in) {
        push @files => $f and next if -f $f;
        push @dirs  => $f and next if -d $f;
        die "'$f' is not a valid test file or directory"
    }

    if (@dirs) {
        require File::Find;
        File::Find::find(
            sub {
                no warnings 'once';
                push @files => $File::Find::name if -f $_ & m/\.t2?$/;
            },
            @dirs
        );
    }

    my $exclude = $self->{+EXCLUDE};
    if (@$exclude) {
        @files = grep {
            my $file = $_;
            grep { $file !~ m/$_/ } @$exclude;
        } @files;
    }

    return \@files;
}

sub help {
    my $self = shift;

    print <<"    EOT";
Usage: $0 [OPTIONS] File1 File2 Directory ...

 Common Options:
  -l          --lib               Add lib/ to \@INC.
  -b          --blib              Add blib/lib and blib/arch to \@INC.
  -I[dir]     --include="dir"     Add directories to \@INC.
  -L[Module]  --preload="Module"  Add a module to preload. (Prefork)
  -R[name]    --renderer="name"   Add a renderer. (See [name] section)
  -S[s=val]   --switch="s=val"    Add switches to use when executing perl.
  -c[n]       --color=n           Override the default color level. (0=off)
  -h          --help              Show this usage help.
  -j[n]       --jobs=n            How many tests to run concurrently.
  -m          --merge             Merge STDERR and STDOUT from test files.
  -q          --quiet             Do not use the default renderer.
  -v          --verbose           Show every event, not just failures and diag.
  -t          --timeout=n         Event timeout, kill tests that stall too long.
  -x[pattern] --exclude=[pattern] Exclude any files that match the pattern.

 Other Options:
  --parser=[name] --parser_class=[name]   Override the default parser.
  --runner=[name] --runner_class=[name]   Override the default runner.

 [name]
   -R[name] --renderer="name"
    'Test2::Harness::Renderer::[name]' is implied. Prefix with '+' to give an
    absolute module name.

   --parser=[name] --parser_class="name"
    'Test2::Harness::Parser::[name]' is implied. Prefix with '+' to give an
    absolute module name.

   --runner=[name] --runner_class="name"
    'Test2::Harness::Runner::[name]' is implied. Prefix with '+' to give an
    absolute module name.

    EOT

    exit 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath - Yet Another Test Harness, alternative to prove

=head1 DESCRIPTION

This package implements the C<yath> command line tool.

=head1 SYNOPSIS

=head2 COMMAND LINE

    yath [options] [files] [directories]

=head2 IN A SCRIPT

=head3 MINIMAL

    use App::Yath;
    my $yath = App::Yath->new(args => \@ARGV);
    my $exit = $yath->run();
    exit($exit);

This minimal version is all most people will need. However it is recommended
you use the complete form below. The complete form does a much better job of
backing out of stack frames in preload+fork mode. Using the minimal can cause
problems in some edge cases where tests assume there are no stack frames
outside the test script itself.

=head3 COMPLETE

    use App::Yath;

    T2_DO_FILE: {
        my $yath = App::Yath->new(args => \@ARGV);
        my $exit = $yath->run();
        exit($exit);
    }

    my $file = $Test2::Harness::Runner::DO_FILE
        or die "No file to run!";

    # Test files do not always return a true value, so we cannot use require. We
    # also cannot trust $!
    package main;
    $@ = '';
    do $file;
    die $@ if $@;
    exit 0;

In preload+fork mode the runner will attempt to break out to the C<T2_DO_FILE>
label. If the example above is inserted into your top-level script then the
script will be able to run with minimal stack trace noise.

=head1 COMMAND LINE ARGUMENTS

=head2 COMMON

=over 4

=item -l --lib

Add F<lib/> to C<@INC>.

=item -b --blib

Add F<blib/lib> and F<blib/arch> to C<@INC>.

=item -I[dir] --include="dir"

Add directories to C<@INC>.

=item -L[Module] --preload="Module"

Add a module to preload. (Prefork)

=item -R[name] --renderer="name"

Add a renderer. C<"Test2::Harness::Renderer::$NAME"> is implied. Prefix with
'+' to give an absolute module name C<"+My::Name">.

=item -S[s=val] --switch="s=val"

Add switches to use when executing perl.

=item -c[n] --color=n

Override the default color level. (0=off)

=item -h --help

Show this usage help.

=item -j[n] --jobs=n

How many tests to run concurrently.

=item -m --merge

Merge STDERR and STDOUT from test files.

=item -q --quiet

Do not use the default renderer.

=item -v --verbose

Show every event, not just failures and diag.

=item -x[pattern] --exclude=[pattern]

Exclude any files that match the pattern.

=back

=head2 OTHER OPTIONS

=over 4

=item --parser=[name] --parser_class=[name]

Override the default parser. C<"Test2::Harness::Parser::$NAME"> is implied.
Prefix with '+' to give an absolute module name.

=item --runner=[name] --runner_class=[name]

Override the default runner. C<"Test2::Harness::Runner::$NAME"> is implied.
Prefix with '+' to give an absolute module name.

=back

=head1 METHODS

=over 4

=item $yath = App::Yath->new(args => \@ARGV)

Create a new instance. Accepts an array of command line arguments.

=item $arg_ref = $yath->args()

Args array passed into construction (was modified during construction.)

=item $harness = $yath->harness()

The L<Test2::Harness> instance that will be used (configured during object
construction).

=item $files_ref = $yath->files()

The arrayref of files as processed/expanded from the command line arguments.

=item $exclude_ref = $yath->exclude()

The arrayref of file exclusion patterns.

=item $renderers_ref = $yath->renderers()

The arrayref of renders that are listening for events.

=item $exit = $yath->run()

Run the tests, returns an integer that should be used as the exit code.

=item $yath->load_module($prefix, $name)

Used to load a module given in C<$name>. C<$prefix> is appended to the start of
the module name unless C<$name> begins with a '+' character.

=item $files_ref = $yath->expand_files(@files_and_dirs)

Takes a list of filea and directories and expands it into a complete list of
test files to run.

=item $yath->help()

Prints the command line help and exits.

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

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
