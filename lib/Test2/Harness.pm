package Test2::Harness;
use strict;
use warnings;

use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use 5.10.0;

use Test2::Util::HashBase qw{
    renderers formatter parser verbose parallel libs switches files procs
    proc_class tmpdir results _environment
};

my $SINGLETON;
sub singleton { $SINGLETON ||= __PACKAGE__->new };

sub loop { $_->loop for @{$_[0]->{+RENDERERS}} }

sub init {
    my $self = shift;

    $self->{+TMPDIR} ||= tempdir('test2harness-XXXXXX');

    $self->{+RESULTS}   ||= {};
    $self->{+RENDERERS} ||= [];
    $self->{+LIBS}      ||= [];
    $self->{+SWITCHES}  ||= [];
    $self->{+FILES}     ||= [];
    $self->{+PROCS}     ||= [];

    $self->{+_ENVIRONMENT} ||= {};
}

sub run {
    my $self = shift;

    my $files = $self->{+FILES} or die "No files specified\n";
    my $max = $self->{+PARALLEL} ||= 1;

    unless(@{$self->{+RENDERERS}}) {
        if ($max > 1) {
            require Test2::Harness::Renderer::Parallel;
            push @{$self->{+RENDERERS}} => Test2::Harness::Renderer::Parallel->new(
                tmpdir => $self->tmpdir,
            );
        }
        elsif($self->{+VERBOSE}) {
            require Test2::Harness::Renderer::Verbose;
            push @{$self->{+RENDERERS}} => Test2::Harness::Renderer::Verbose->new(
                tmpdir => $self->tmpdir,
            );
        }
        else {
            require Test2::Harness::Renderer::Simple;
            push @{$self->{+RENDERERS}} => Test2::Harness::Renderer::Simple->new(
                tmpdir => $self->tmpdir,
            );
        }
    }

    unless($self->{+PARSER}) {
        require Test2::Harness::Parser::TAP;
        $self->{+PARSER} = Test2::Harness::Parser::TAP->new;
    }

    unless($self->{+PROC_CLASS}) {
        require Test2::Harness::Proc;
        $self->{+PROC_CLASS} = 'Test2::Harness::Proc';
    }

    my $procs       = $self->{+PROCS};
    my $tmpdir      = $self->{+TMPDIR};
    my $class       = $self->{+PROC_CLASS};
    my $libs        = $self->{+LIBS};
    my $switches    = $self->{+SWITCHES};
    my $environment = $self->environment;

    my $id = 0;
    for my $file (@$files) {
        $id++;
        my $slot = $self->slot;
        mkdir("$tmpdir/$id") or die "$!";
        my $proc = $class->new(
            id          => $id,
            file        => $file,
            tmpdir      => "$tmpdir/$id",
            switches    => $switches,
            libs        => $libs,  
            environment => $environment,
        );
        $proc->start;
        $procs->[$slot] = $proc;
    }

    $self->wait;
    $self->finish;
}

sub environment {
    my $self = shift;

    my %out = (
        'HARNESS_ACTIVE'  => '1',
        'HARNESS_VERSION' => $Test2::Harness::VERSION,

        'T2_HARNESS_ACTIVE'  => '1',
        'T2_HARNESS_VERSION' => $Test2::Harness::VERSION,
    );

    $out{T2_FORMATTER} = $self->{+FORMATTER} if $self->{+FORMATTER};
    $out{HARNESS_IS_VERBOSE}  = $self->{+VERBOSE}      ? 1 : 0;
    $out{HARNESS_IS_PARALLEL} = $self->{+PARALLEL} > 1 ? 1 : 0;

    return \%out;
}

sub wait {
    my $self = shift;
    my $max = $self->{+PARALLEL};
    my $procs = $self->{+PROCS};

    while (@$procs) {
        $self->loop;

        for my $s (1 .. $max) {
            next unless $procs->[$s];
            next unless $procs->[$s]->is_done;
            $self->process($procs->[$s]);
            $procs->[$s] = undef;
        }

        @$procs = grep { $_ } @$procs;
    }
}

sub slot {
    my $self = shift;
    my $max = $self->{+PARALLEL};
    my $procs = $self->{+PROCS};

    while (1) {
        $self->loop;

        for my $s (1 .. $max) {
            return $s unless $procs->[$s];
            next unless $procs->[$s]->is_done;
            $self->process($procs->[$s]);
            $procs->[$s] = undef;
            return $s;
        }
    }
}

sub process {
    my $self = shift;
    my ($proc) = @_;
    my $results = $self->{+PARSER}->parse($proc);
    $self->{+RESULTS}->{$proc->file} = $results;

    warn "todo";
    # append errors to log_file
    # write then copy into place.
    # Open results file (format? YAML, JSON, STORABLE, ...?) 
    # print result fields to it
    #   - count, failed, exit, pass, @errors
}

sub finish {
    my $self = shift;
    $_->finish for @{$_[0]->{+RENDERERS}};
    warn "todo";
}

1;
