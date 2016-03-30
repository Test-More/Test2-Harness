package Test2::Harness::Runner;
use strict;
use warnings;

use Test2::Harness::Proc;

use Test2::Util::HashBase qw/headers merge via/;
use Test2::Util qw/CAN_REALLY_FORK/;

use IO::Handle;
use Carp qw/croak/;
use Symbol qw/gensym/;
use IPC::Open3 qw/open3/;

our $DO_FILE;

sub init {
    my $self = shift;
    $self->{+HEADERS} = {};

    croak "'$self->{+VIA}' is not a valid value for the 'via' attribute"
        if exists($self->{+VIA}) && !$self->can("via_$self->{+VIA}");
}

sub fatal_error {
    my $self = shift;
    my ($msg) = @_;

    print STDERR <<"    EOT";

*******************************************************************************
*                                                                             *
*                           Test2::Harness::Runner                            *
*                            INTERNAL FATAL ERROR                             *
*                                                                             *
*******************************************************************************
$msg

    EOT

    CORE::exit(255);
}

my %WARNED;
sub start {
    my $self = shift;
    my ($file, %params) = @_;

    die "'$file' is not a valid test file"
        unless -f $file;

    my $header = $self->header($file);

    my $via = $self->{+VIA};

    return $self->via_open3(@_) unless $via;
    return $self->via_open3(@_) if $via eq 'open3';

    unless (CAN_REALLY_FORK) {
        warn "This system is not capable of forking, falling back to IPC::Open3.\nThis message will not be shown again.\n"
            unless $WARNED{FORK}++;

        return $self->via_open3(@_);
    }

    if ($header->{switches}) {
        warn "Test file '$file' uses switches in the #! line, Falling back to IPC::Open3.";
        return $self->via_open3(@_);
    }

    if (exists($header->{features}->{preload}) && !$header->{features}->{preload}) {
        warn "Test file '$file' uses has turned off preloading, Falling back to IPC::Open3.";
        return $self->via_open3(@_);
    }

    $self->fatal_error("You cannot use switches with preloading, aborting...")
        if @{$params{switches}};

    $self->fatal_error("Something preloaded Test::Builder, aborting...")
        if $INC{'Test/Builder.pm'};

    $self->fatal_error("Something preloaded and initialized Test2::API, Aborting...")
        if $INC{'Test2/API.pm'} && Test2::API::test2_init_done();

    return $self->via_do(@_);
}

sub header {
    my $self = shift;
    my ($file) = @_;

    return $self->{+HEADERS}->{$file}
        if $self->{+HEADERS}->{$file};

    my %header = (
        shbang   => "",
        features => {},
    );

    open(my $fh, '<', $file) or die "Could not open file $file: $!";
    my $ln = 0;
    while (my $line = <$fh>) {
        $ln++;
        chomp($line);
        next if $line =~ m/^\s*$/;

        if ($ln == 1 && $line =~ m/#!.*perl\S*(\s.*)?$/) {
            my @switches = split /\s+/, $1;
            $header{switches} = \@switches;
            $header{shbang} = $line;
        }

        last unless $line =~ m/^\s*#\s*HARNESS-(.+)$/;
        my ($dir, @args) = split /-/, lc($1);
        if($dir eq 'no') {
            my ($feature) = @args;
            $header{features}->{$feature} = 0;
        }
        elsif($dir eq 'yes') {
            my ($feature) = @args;
            $header{features}->{$feature} = 1;
        }
        else {
            warn "Unknown harness directive '$dir' at $file line $ln.\n";
        }
    }
    close($fh);

    $self->{+HEADERS}->{$file} = \%header;
}

sub via_open3 {
    my $self = shift;
    my ($file, %params) = @_;

    my $env      = $params{env};
    my $libs     = $params{libs};
    my $switches = $params{switches};
    my $header   = $self->header($file);

    my $in  = gensym;
    my $out = gensym;
    my $err = $self->{+MERGE} ? $out : gensym;

    my @switches;
    push @switches => map { ('-I', $_) } @$libs if $libs;
    push @switches => @$switches             if $switches;
    push @switches => @{$header->{switches}} if $header->{switches};

    local %ENV = (%ENV, %$env) if $env;

    my $pid = open3(
        $in, $out, $err,
        $^X, @switches, $file
    );
    die "Failed to execute '" . join(' ' => $^X, @switches, $file) . "'" unless $pid;

    for my $fh ($in, $out, $err) {
        next unless $fh;
        $fh->blocking(0);
    }

    my $proc = Test2::Harness::Proc->new(
        file   => $file,
        pid    => $pid,
        in_fh  => $in,
        out_fh => $out,
        err_fh => $self->{+MERGE} ? undef : $err,
    );

    return $proc;
}

sub via_do {
    my $self = shift;
    my ($file, %params) = @_;

    my $env      = $params{env};
    my $libs     = $params{libs};
    my $header   = $self->header($file);

    my ($in_read, $in_write, $out_read, $out_write, $err_read, $err_write);

    pipe($in_read, $in_write) or die "Could not open pipe!";
    pipe($out_read, $out_write) or die "Could not open pipe!";
    if ($self->{+MERGE}) {
        ($out_read, $out_write) = ($in_read, $in_write);
    }
    else {
        pipe($err_read, $err_write) or die "Could not open pipe!";
    }

    my $pid = fork;
    die "Could not fork!" unless defined $pid;

    if ($pid) {
        for my $fh ($in_write, $out_read, $err_read) {
            next unless $fh;
            $fh->blocking(0);
        }
    
        return Test2::Harness::Proc->new(
            file   => $file,
            pid    => $pid,
            in_fh  => $in_write,
            out_fh => $out_read,
            err_fh => $self->{+MERGE} ? undef : $err_read,
        )
    }

    close(STDIN);
    open(STDIN, '<&', $in_read) || die "Could not open new STDIN: $!";

    close(STDOUT);
    open(STDOUT, '>&', $out_write) || die "Could not open new STDOUT: $!";

    close(STDERR);
    open(STDERR, '>&', $err_write) || die "Could not open new STDERR: $!";

    %ENV = (%ENV, %$env) if $env;

    $DO_FILE = $file;

    my $ok = eval {
        no warnings 'exiting';
        last T2_DO_FILE;
        1;
    };
    my $err = $@;

    die $err unless $err =~ m/Label not found for "last T2_DO_FILE"/;

    # Test files do not always return a true value, so we cannot use require. We
    # also cannot trust $!
    package main;
    $@ = '';
    do $file;
    die $@ if $@;
    exit 0;
}

1;
