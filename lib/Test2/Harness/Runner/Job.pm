package Test2::Harness::Runner::Job;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/confess croak/;
use Config qw/%Config/;
use Scalar::Util qw/weaken blessed/;
use Test2::Util qw/CAN_REALLY_FORK/;
use Time::HiRes qw/time/;

use File::Spec();

use Test2::Harness::Util qw/fqmod clean_path write_file_atomic write_file mod2file open_file parse_exit/;
use Test2::Harness::IPC;

use parent 'Test2::Harness::IPC::Process';
use Test2::Harness::Util::HashBase(
    qw{ <task <runner <run <settings }, # required
    qw{
        <last_output_size

        +via

        +run_dir +job_dir +tmp_dir +event_dir

        +ch_dir +unsafe_inc

        +use_fork +use_w_switch

        +includes +runner_includes
        +switches
        +use_stream
        +cli_includes
        +cli_options

        +smoke
        +retry +retry_isolated +is_try

        +args +file

        +out_file +err_file +in_file

        +load +load_import

        +event_uuids +mem_usage

        +env_vars

        +event_timeout +post_exit_timeout

        +preloads_with_callbacks

        +switches_from_env

        +et_file +pet_file
    }
);

sub category { 'job' }

sub init {
    my $self = shift;

    croak "'runner' is a required attribute"   unless $self->{+RUNNER};
    croak "'run' is a required attribute"      unless $self->{+RUN};
    croak "'settings' is a required attribute" unless $self->{+SETTINGS};

    # Avoid a ref cycle
    #weaken($self->{+RUNNER});

    my $task = $self->{+TASK} or croak "'task' is a required attribute";

    delete $self->{+LAST_OUTPUT_SIZE};

    confess "Task does not have a job ID" unless $task->{job_id};
    confess "Task does not have a file"   unless $task->{file};
}

sub prepare_dir {
    my $self = shift;

    $self->write_initial_files();
    $self->make_temp_dir();
}

sub via {
    my $self = shift;

    return $self->{+VIA} if exists $self->{+VIA};

    my $task = $self->{+TASK};
    return $self->{+VIA} = $task->{via} if $task->{via};
    return $self->{+VIA} = undef;
}

sub spawn_params {
    my $self = shift;

    my $task = $self->{+TASK};

    my $command;
    if ($task->{binary} || $task->{non_perl}) {
        $command = [$self->file, $self->args];
    }
    else {
        $command = [
            $^X,
            $self->cli_includes,
            $self->switches,
            $self->cli_options,

            $self->{+SETTINGS}->debug->dummy ? ('-e', 'print "1..0 # SKIP dummy mode"') : ($self->file),

            $self->args,
        ];
    }

    my $out_fh = open_file($self->out_file, '>');
    my $err_fh = open_file($self->err_file, '>');
    my $in_fh  = open_file($self->in_file,  '<');

    return {
        command => $command,
        stdin   => $in_fh,
        stdout  => $out_fh,
        stderr  => $err_fh,
        chdir   => $self->ch_dir(),
        set_env => $self->env_vars(),
    };
}

sub switches_from_env {
    my $self = shift;

    return @{$self->{+SWITCHES_FROM_ENV}} if $self->{+SWITCHES_FROM_ENV};

    return @{$self->{+SWITCHES_FROM_ENV} = []} unless $ENV{HARNESS_PERL_SWITCHES};

    return @{$self->{+SWITCHES_FROM_ENV} = [split /\s+/, $ENV{HARNESS_PERL_SWITCHES}]};
}

my %JSON_SKIP = (
    TASK()                    => 1,
    RUNNER()                  => 1,
    RUN()                     => 1,
    CLI_INCLUDES()            => 1,
    CLI_OPTIONS()             => 1,
    PRELOADS_WITH_CALLBACKS() => 1,
);

sub TO_JSON {
    my $self = shift;

    my $out = { %{$self->{+TASK}} };

    for my $attr (Test2::Harness::Util::HashBase::attr_list(blessed($self))) {
        next if $JSON_SKIP{$attr};
        $out->{$attr} = $self->$attr;
    }

    $out->{job_name} //= $out->{job_id};
    $out->{abs_file} = clean_path($self->file);
    $out->{rel_file} = File::Spec->abs2rel($self->file);

    return $out;
}

sub file     { $_[0]->{+FILE}     //= clean_path($_[0]->{+TASK}->{file}) }
sub err_file { $_[0]->{+ERR_FILE} //= clean_path(File::Spec->catfile($_[0]->job_dir, 'stderr')) }
sub out_file { $_[0]->{+OUT_FILE} //= clean_path(File::Spec->catfile($_[0]->job_dir, 'stdout')) }
sub et_file  { $_[0]->{+ET_FILE}  //= clean_path(File::Spec->catfile($_[0]->job_dir, 'event_timeout')) }
sub pet_file { $_[0]->{+PET_FILE} //= clean_path(File::Spec->catfile($_[0]->job_dir, 'post_exit_timeout')) }
sub run_dir  { $_[0]->{+RUN_DIR}  //= clean_path(File::Spec->catdir($_[0]->{+RUNNER}->dir, $_[0]->{+RUN}->run_id)) }

sub output_size {
    my $self = shift;

    my $size = 0;

    $size += -s $self->err_file;
    $size += -s $self->out_file;

    return $self->{+LAST_OUTPUT_SIZE} = $size;
}

sub is_try      { $_[0]->{+IS_TRY}      //= $_[0]->{+TASK}->{is_try} // 0 }
sub ch_dir      { $_[0]->{+CH_DIR}      //= $_[0]->{+TASK}->{ch_dir} // '' }
sub unsafe_inc  { $_[0]->{+UNSAFE_INC}  //= $_[0]->{+RUNNER}->unsafe_inc }
sub event_uuids { $_[0]->{+EVENT_UUIDS} //= $_[0]->run->event_uuids }
sub mem_usage   { $_[0]->{+MEM_USAGE}   //= $_[0]->run->mem_usage }

sub smoke             { $_[0]->{+SMOKE}             //= $_[0]->_fallback(smoke             => 0,  qw/task run/) }
sub retry             { $_[0]->{+RETRY}             //= $_[0]->_fallback(retry             => 0,  qw/task run/) }
sub retry_isolated    { $_[0]->{+RETRY_ISOLATED}    //= $_[0]->_fallback(retry_isolated    => 0,  qw/task run/) }
sub use_stream        { $_[0]->{+USE_STREAM}        //= $_[0]->_fallback(use_stream        => '', qw/task run/) }
sub event_timeout     { $_[0]->{+EVENT_TIMEOUT}     //= $_[0]->_fallback(event_timeout     => '', qw/task runner/) }
sub post_exit_timeout { $_[0]->{+POST_EXIT_TIMEOUT} //= $_[0]->_fallback(post_exit_timeout => '', qw/task runner/) }

sub args { @{$_[0]->{+ARGS} //= $_[0]->_fallback(test_args => [], qw/task run/)} }
sub load { @{$_[0]->{+LOAD} //= [@{$_[0]->run->load // []}]} }


#<<< no-tidy
sub cli_includes { @{$_[0]->{+CLI_INCLUDES} //= [ map {("-I$_")} $_[0]->includes ]} }

sub runner_includes { @{$_[0]->{+RUNNER_INCLUDES} //= [$_[0]->{+RUNNER}->all_libs]} }

sub preloads_with_callbacks {$_[0]->{+PRELOADS_WITH_CALLBACKS} //= [grep { $_->isa('Test2::Harness::Runner::Preload') } @{$_[0]->{+RUNNER}->preloads}]}
#>>>

sub _fallback {
    my $self = shift;
    my ($name, $default, @from) = @_;

    for my $from (@from) {
        my $source = $self->$from;
        my $val = blessed($source) ? $source->$name : $source->{$name};
        return $val if defined $val;
    }

    return $default;
}

sub job_dir {
    my $self = shift;
    return $self->{+JOB_DIR} if $self->{+JOB_DIR};

    my $job_dir = File::Spec->catdir($self->run_dir, $self->{+TASK}->{job_id} . '+' . $self->is_try);
    mkdir($job_dir) or die "$$ Could not create job directory '$job_dir': $!";
    $self->{+JOB_DIR} = $job_dir;
}

sub make_temp_dir { $_[0]->tmp_dir }
sub tmp_dir {
    my $self = shift;
    return $self->{+TMP_DIR} if $self->{+TMP_DIR};

    my $tmp_dir = File::Spec->catdir($self->job_dir, 'tmp');
    mkdir($tmp_dir) or die "$$ Could not create temp directory '$tmp_dir': $!";
    $self->{+TMP_DIR} = $tmp_dir;
}

sub make_event_dir { $_[0]->event_dir }
sub event_dir {
    my $self = shift;
    return $self->{+EVENT_DIR} if $self->{+EVENT_DIR};

    my $events_dir = File::Spec->catdir($self->job_dir, 'events');
    unless (-d $events_dir) {
        mkdir($events_dir) or die "$$ Could not create events directory '$events_dir': $!";
    }
    $self->{+EVENT_DIR} = $events_dir;
}

sub in_file {
    my $self = shift;
    return $self->{+IN_FILE} if $self->{+IN_FILE};

    my $from_run = $self->run->input_file;
    return $self->{+IN_FILE} = $from_run if $from_run;

    my $stdin = File::Spec->catfile($self->job_dir, 'stdin');

    my $content = $self->run->input // '';
    write_file($stdin, $content);

    return $self->{+IN_FILE} = $stdin;
}

sub write_initial_files {
    my $self = shift;

    my $job_dir = $self->job_dir;
    my $file_file = File::Spec->catfile($job_dir, 'file');
    write_file_atomic($file_file, $self->{+TASK}->{file});

    my $start_file = File::Spec->catfile($job_dir, 'start');
    write_file_atomic($start_file, time());
}

sub use_fork {
    my $self = shift;

    return $self->{+USE_FORK} if defined $self->{+USE_FORK};

    my $task = $self->{+TASK};

    return $self->{+USE_FORK} = 0 unless CAN_REALLY_FORK;
    return $self->{+USE_FORK} = 0 if $task->{binary};
    return $self->{+USE_FORK} = 0 if $task->{non_perl};
    return $self->{+USE_FORK} = 0 if defined($task->{use_fork}) && !$task->{use_fork};
    return $self->{+USE_FORK} = 0 if defined($task->{use_preload}) && !$task->{use_preload};

    # -w switch is ok, otherwise it is a no-go
    return $self->{+USE_FORK} = 0 if grep { !m/\s*-w\s*/ } $self->switches;

    my $runner = $self->{+RUNNER};
    return $self->{+USE_FORK} = 0 unless $runner->use_fork;

    return $self->{+USE_FORK} = 1;
}

sub includes {
    my $self = shift;

    return @{$self->{+INCLUDES}} if $self->{+INCLUDES};

    my @inc = $self->runner_includes;
    push @inc => @{$self->{+SETTINGS}->yath->orig_inc};

    return @{$self->{+INCLUDES} = \@inc};
}

sub cli_options {
    my $self = shift;

    my $event_dir = $self->event_dir;

    return (
        $self->use_stream  ? ("-MTest2::Formatter::Stream=dir,$event_dir") : (),
        $self->event_uuids ? ('-MTest2::Plugin::UUID')                     : (),
        $self->mem_usage   ? ('-MTest2::Plugin::MemUsage')                 : (),
        (map { @{$_[1]} ? "-M$_[0]=" . join(',' => @{$_[1]}) : "-M$_[0]" } $self->load_import),
        (map { "-m$_" } $self->load),
    );
}

sub switches {
    my $self = shift;

    return @{$self->{+SWITCHES}} if $self->{+SWITCHES};

    my @switches;

    my %seen;
    for my $s (@{$self->{+TASK}->{switches} // []}) {
        $seen{$s}++;
        $self->{+USE_W_SWITCH} = 1 if $s =~ m/\s*-w\s*/;
        push @switches => $s;
    }

    my %seen2;
    for my $s (@{$self->{+RUNNER}->switches // []}) {
        next if $seen{$s};
        $seen2{$s}++;
        $self->{+USE_W_SWITCH} = 1 if $s =~ m/\s*-w\s*/;
        push @switches => $s;
    }

    for my $s ($self->switches_from_env) {
        next if $seen{$s};
        next if $seen2{$s};
        $self->{+USE_W_SWITCH} = 1 if $s =~ m/\s*-w\s*/;
        push @switches => $s;
    }

    return @{$self->{+SWITCHES} = \@switches};
}

sub env_vars {
    my $self = shift;

    return $self->{+ENV_VARS} if $self->{+ENV_VARS};

    my $from_run = $self->run->env_vars;
    my $from_task = $self->{+TASK}->{env_vars};

    my $p5l = join $Config{path_sep} => grep { defined $_ } $from_task->{PERL5LIB}, $from_run->{PERL5LIB}, $self->runner_includes;

    return $self->{+ENV_VARS} = {
        $from_run  ? (%$from_run)  : (),
        $from_task ? (%$from_task) : (),

        $self->use_stream ? (T2_FORMATTER => 'Stream', T2_STREAM_DIR => $self->event_dir) : (),

        PERL5LIB            => $p5l,
        T2_HARNESS_JOB_NAME => $self->{+TASK}->{job_name},
        PERL_USE_UNSAFE_INC => $self->unsafe_inc,
        TEST2_JOB_DIR       => $self->job_dir,
        TMPDIR              => $self->tmp_dir,
        TEMPDIR             => $self->tmp_dir,
    };
}

sub load_import {
    my $self = shift;

    return @{$self->{+LOAD_IMPORT}} if $self->{+LOAD_IMPORT};

    my $from_run = $self->run->load_import;

    my @out;
    for my $mod (@{$from_run->{'@'} // []}) {
        push @out => [$mod, $from_run->{$mod}];
    }

    return @{$self->{+LOAD_IMPORT} = \@out};
}

sub use_w_switch {
    my $self = shift;
    return $self->{+USE_W_SWITCH} if defined $self->{+USE_W_SWITCH};
    $self->switches;
    return $self->{+USE_W_SWITCH};
}

sub set_exit {
    my $self = shift;
    my ($runner, $exit, $time, @args) = @_;

    $self->SUPER::set_exit(@_);

    my $file = File::Spec->catfile($self->job_dir, 'exit');

    my $e = parse_exit($exit);

    write_file_atomic($file, join(" " => $exit, $e->{err}, $e->{sig}, $e->{dmp}, $time, @args));
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Job - Representation of a test job.

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
