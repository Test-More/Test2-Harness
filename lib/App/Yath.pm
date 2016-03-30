package App::Yath;
use strict;
use warnings;

our $VERSION = "0.000001";

use Test2::Util::HashBase qw/args harness files exclude/;
use Test2::Util qw/pkg_to_file/;

use Test2::Harness;
use Test2::Harness::Listener;
use Test2::Harness::Parser;
use Test2::Harness::Runner;

use Carp qw/croak/;
use Getopt::Long qw/GetOptionsFromArray/;
Getopt::Long::Configure("bundling");

sub run {
    my $self = shift;
    my $results = $self->{+HARNESS}->run(@{$self->{+FILES}});

    my $failed = grep {!$_->passed} @$results;
    return $failed;
}

sub init {
    my $self = shift;
    my @args = @{$self->{+ARGS}};

    my (%env, @libs, @switches);
    my %harness_args = (
        env_vars => \%env,
        libs     => \@libs,
        switches => \@switches,

        parser_class => 'Test2::Harness::Parser',
    );

    my (@exclude, @listen, @preload);
    my $color   = -t STDOUT ? 1 : 0;
    my $jobs    = 1;
    my $merge   = 0;
    my $verbose = 0;
    my $quiet   = 0;

    my $runner_class = 'Test2::Harness::Runner';

    GetOptionsFromArray \@args => (
        'I|include=s@'  => \@libs,
        'L|listener=s@' => \@listen,
        'P|preload=s@'  => \@preload,

        'c|color=i'     => \$color,
        'h|help'        => \&help,
        'j|jobs=i'      => \$jobs,
        'm|merge'       => \$merge,
        'q|quiet'       => \$quiet,
        'v|verbose'     => \$verbose,
        'x|exclude=s@'  => \@exclude,

        'parser|parser_class' => \$harness_args{parser_class},
        'runner|runner_class' => \$runner_class,

        'S|switch|switches=s@' => sub {
            push @switches => split '=', $_[1];
        },
    );


    croak "You cannot combine preload (-P) with switches (-S)"
        if @preload && @switches;

    {
        local @INC = (@libs, @INC);
        require(pkg_to_file($_)) for $runner_class, $harness_args{parser_class}, @listen, @preload;
    }

    $harness_args{jobs}   = $jobs;
    $harness_args{runner} = $runner_class->new(merge => $merge, via => @preload ? 'do' : 'open3');

    unshift @listen => 'Test2::Harness::Listener'
        unless $quiet;

    $harness_args{listeners} = [
        map {
            $_->new(
                color    => $color,
                parallel => $jobs,
                verbose  => $verbose,
            )->listen;
        } @listen
    ];

    $self->{+HARNESS} = Test2::Harness->new(%harness_args);

    $self->{+EXCLUDE} = \@exclude;
    $self->{+FILES} = $self->expand_files(@args);
}

sub expand_files {
    my $self = shift;

    my (@files, @dirs);
    for my $f (@_) {
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

1;
