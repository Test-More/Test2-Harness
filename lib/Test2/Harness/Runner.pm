package Test2::Harness::Runner;
use strict;
use warnings;

our $VERSION = '0.000014';

use Test2::Event::Diag;
use Test2::Harness::Proc;
use Config;

use Test2::Util::HashBase qw/headers merge via _preload_list/;
use Test2::Util qw/CAN_REALLY_FORK/;

use Carp qw/croak/;
use Symbol qw/gensym/;
use IPC::Open3 qw/open3/;
use File::Temp qw/tempfile/;
use Scalar::Util 'openhandle';

our ($DO_FILE, $SET_ENV);

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

sub start {
    my $self = shift;
    my ($file, %params) = @_;

    die "'$file' is not a valid test file"
        unless -f $file;

    my $header = $self->header($file);

    # Localize+copy
    local $ENV{T2_FORMATTER} = $ENV{T2_FORMATTER} || '';
    if (exists $header->{features}->{formatter} && !$header->{features}->{formatter}) {
        delete $ENV{T2_FORMATTER};

        my $env = $params{env};
        delete $env->{T2_FORMATTER}
            if $env;
    }

    my $via = $self->{+VIA};

    return $self->via_open3(@_) unless $via;
    return $self->via_open3(@_) if $via eq 'open3';

    unless (CAN_REALLY_FORK) {
        my $event = Test2::Event::Diag->new(
            message     => "This system is not capable of forking, falling back to IPC::Open3.",
            diagnostics => 1,
        );

        my $proc = $self->via_open3(@_);
        return ($proc, $event);
    }

    if ($header->{switches}) {
        my $event = Test2::Event::Diag->new(
            message     => "Test file '$file' uses switches in the #! line, Falling back to IPC::Open3.",
            diagnostics => 1,
        );

        my $proc = $self->via_open3(@_);
        return ($proc, $event);
    }

    if (exists($header->{features}->{preload}) && !$header->{features}->{preload}) {
        my $event = Test2::Event::Diag->new(
            message     => "Test file '$file' has turned off preloading, Falling back to IPC::Open3.",
            diagnostics => 1,
        );

        my $proc = $self->via_open3(@_);
        return ($proc, $event);
    }

    $self->fatal_error("You cannot use switches with preloading, aborting...")
        if @{$params{switches}};

    $self->fatal_error("Something preloaded Test::Builder, aborting...")
        if $INC{'Test/Builder.pm'};

    $self->fatal_error("Something preloaded and initialized Test2::API, Aborting...")
        if $INC{'Test2/API.pm'} && Test2::API::test2_init_done();

    return $self->via_do(@_);
}

sub _parse_shbang {
    my $self = shift;
    my $line = shift;

    return {} if !defined $line;

    my %shbang;

    my $shbang_re = qr{
        ^
          \#!.*\bperl.*?        # the perl path
          (?: \s (-.+) )?       # the switches, maybe
          \s*
        $
    }xi;

    if ( $line =~ $shbang_re ) {
        my @switches = grep { m/\S/ } split /\s+/, $1 if defined $1;
        $shbang{switches} = \@switches;
        $shbang{shbang} = $line;
    }

    return \%shbang;
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

    for(my $ln = 0; my $line = <$fh>; $ln++) {
        chomp($line);
        next if $line =~ m/^\s*$/;

        if( $ln == 0 ) {
            my $shbang = $self->_parse_shbang($line);
            for my $key (keys %$shbang) {
                $header{$key} = $shbang->{$key} if defined $shbang->{$key};
            }
            next if $shbang->{shbang};
        }

        next if $line =~ m/^(use|require|BEGIN)/;
        last unless $line =~ m/^\s*#/;

        next unless $line =~ m/^\s*#\s*HARNESS-(.+)$/;

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

    return $self->via_win32(@_)
        if $^O eq 'MSWin32';

    my $env      = $params{env} || {};
    my $libs     = $params{libs};
    my $switches = $params{switches};
    my $header   = $self->header($file);

    my $in  = gensym;
    my $out = gensym;
    my $err = $self->{+MERGE} ? $out : gensym;

    my @switches;
    push @switches => map { ("-I$_") } @$libs if $libs;
    push @switches => map { ("-I$_") } split $Config{path_sep}, ($ENV{PERL5LIB} || "");
    push @switches => @$switches             if $switches;
    push @switches => @{$header->{switches}} if $header->{switches};

    # local $ENV{$_} = $env->{$_} for keys %$env;  does not work...
    my $old = {%ENV};
    $ENV{$_} = $env->{$_} for keys %$env;

    my $pid = open3(
        $in, $out, $err,
        $^X, @switches, $file
    );

    $ENV{$_} = $old->{$_} || '' for keys %$env;

    die "Failed to execute '" . join(' ' => $^X, @switches, $file) . "'" unless $pid;

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

    my $env      = $params{env} || {};
    my $libs     = $params{libs};
    my $header   = $self->header($file);

    my ($in_read, $in_write, $out_read, $out_write, $err_read, $err_write);

    pipe($in_read, $in_write) or die "Could not open pipe!";
    pipe($out_read, $out_write) or die "Could not open pipe!";
    if ($self->{+MERGE}) {
        ($err_read, $err_write) = ($out_read, $out_write);
    }
    else {
        pipe($err_read, $err_write) or die "Could not open pipe!";
    }

    # Generate the preload list
    $self->preload_list;

    my $pid = fork;
    die "Could not fork!" unless defined $pid;

    if ($pid) {
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

    unshift @INC => @$libs if $libs;
    @ARGV = ();

    $SET_ENV = sub { $ENV{$_} = $env->{$_} || '' for keys %$env };

    $DO_FILE = $file;
    $0 = $file;

    $self->reset_DATA($file);

    # Stuff copied shamelessly from forkprove
    ####################
    # if FindBin is preloaded, reset it with the new $0
    FindBin::init() if defined &FindBin::init;

    # restore defaults
    Getopt::Long::ConfigDefaults();

    # reset the state of empty pattern matches, so that they have the same
    # behavior as running in a clean process.
    # see "The empty pattern //" in perlop.
    # note that this has to be dynamically scoped and can't go to other subs
    "" =~ /^/;

    # Test::Builder is loaded? Reset the $Test object to make it unaware
    # that it's a forked off proecess so that subtests won't run
    if ($INC{'Test/Builder.pm'}) {
        if (defined $Test::Builder::Test) {
            $Test::Builder::Test->reset;
        }
        else {
            Test::Builder->new;
        }
    }

    # avoid child processes sharing the same seed value as the parent
    srand();
    ####################
    # End stuff copied from forkprove

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
    $Test2::Harness::Runner::SET_ENV->();
    $@ = '';
    do $file;
    die $@ if $@;
    exit 0;
}

{
    no warnings 'once';
    *via_win32 = \&via_files;
}
sub via_files {
    my $self = shift;
    my ($file, %params) = @_;

    my $env      = $params{env} || {};
    my $libs     = $params{libs};
    my $switches = $params{switches};
    my $header   = $self->header($file);

    my ($in_write, $in)   = tempfile(CLEANUP => 1) or die "XXX";
    my ($out_write, $out) = tempfile(CLEANUP => 1) or die "XXX";
    my ($err_write, $err) = tempfile(CLEANUP => 1) or die "XXX";
    open(my $in_read,  '<', $in)  or die "$!";
    open(my $out_read, '<', $out) or die "$!";
    open(my $err_read, '<', $err) or die "$!";

    my @switches;
    push @switches => map { ("-I$_") } @$libs if $libs;
    push @switches => map { ("-I$_") } split $Config{path_sep}, ($ENV{PERL5LIB} || "");
    push @switches => @$switches             if $switches;
    push @switches => @{$header->{switches}} if $header->{switches};

    # local $ENV{$_} = $env->{$_} for keys %$env;  does not work...
    my $old = {%ENV};
    $ENV{$_} = $env->{$_} || '' for keys %$env;

    my $pid = open3(
        "<&" . fileno($in_read), ">&" . fileno($out_write), ">&" . fileno($err_write),
        $^X, @switches, $file
    );

    $ENV{$_} = $old->{$_} || '' for keys %$env;

    die "Failed to execute '" . join(' ' => $^X, @switches, $file) . "'" unless $pid;

    my $proc = Test2::Harness::Proc->new(
        file   => $file,
        pid    => $pid,
        in_fh  => $in_write,
        out_fh => $out_read,
        err_fh => $err_read,
    );

    return $proc;
}

# Heavily modified from forkprove
sub preload_list {
    my $self = shift;

    return @{$self->{+_PRELOAD_LIST}} if $self->{+_PRELOAD_LIST};

    my $list = $self->{+_PRELOAD_LIST} = [];

    for my $loaded (keys %INC) {
        next unless $loaded =~ /\.pm$/;

        my $mod = $loaded;
        $mod =~ s{/}{::}g;
        $mod =~ s{\.pm$}{};

        my $fh = do {
            no strict 'refs';
            *{ $mod . '::DATA' }
        };

        next unless openhandle($fh);
        push @$list => [ $mod, $INC{$loaded}, tell($fh) ];
    }

    return @$list;
}

# Heavily modified from forkprove
sub reset_DATA {
    my $self = shift;
    my ($file) = @_;

    # open DATA from test script
    if (openhandle(\*main::DATA)) {
        close ::DATA;
        if (open my $fh, $file) {
            my $code = do { local $/; <$fh> };
            if(my($data) = $code =~ /^__(?:END|DATA)__$(.*)/ms){
                open ::DATA, '<', \$data
                  or die "Can't open string as DATA. $!";
            }
        }
    }

    for my $set ($self->preload_list) {
        my ($mod, $file, $pos) = @$set;

        my $fh = do {
            no strict 'refs';
            *{ $mod . '::DATA' }
        };

        # note that we need to ensure that each forked copy is using a
        # different file handle, or else concurrent processes will interfere
        # with each other

        close $fh if openhandle($fh);

        if (open $fh, '<', $file) {
            seek($fh, $pos, 0);
        }
        else {
            warn "Couldn't reopen DATA for $mod ($file): $!";
        }
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner - Responsible for spawning test processes.

=head1 DESCRIPTION

This is used to spawn each test file and return an L<Test2::Harness::Proc>
handle for it.

=head1 SPAWN METHODS

Depending on platform and command line arguments one of these will be used:

=over 4

=item via_open3

This is the default, it uses C<open3> to spawn a new process that runs the test
file.

=item via_do

This is used in preload mode to fork for each new process.

=item via_files

=item via_win32

This uses temporary files and open3 together. 'via_win32' is an alias to
'via_files'.

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
