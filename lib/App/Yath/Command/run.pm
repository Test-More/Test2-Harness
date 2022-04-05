package App::Yath::Command::run;
use strict;
use warnings;

our $VERSION = '1.000120';

use App::Yath::Options;

use Test2::Harness::Run;
use Test2::Harness::Util::Queue;
use Test2::Harness::Util::File::JSON;
use Test2::Harness::IPC;

use App::Yath::Util qw/find_pfile/;
use Test2::Harness::Util qw/open_file/;
use Test2::Harness::Util qw/mod2file open_file/;
use Test2::Util::Table qw/table/;

use File::Spec;

use Carp qw/croak/;

use parent 'App::Yath::Command::test';
use Test2::Harness::Util::HashBase qw/+pfile_data +pfile/;

include_options(
    'App::Yath::Options::Debug',
    'App::Yath::Options::Display',
    'App::Yath::Options::Finder',
    'App::Yath::Options::Logging',
    'App::Yath::Options::PreCommand',
    'App::Yath::Options::Run',
);

option_group {prefix => 'run'} => sub {
    option check_reload_state => (
        type => 'b',
        description => 'Abort the run if there are unfixes reload errors and show a confirmation dialogue for unfixed reload warnings.',
        default => 1,
    );
};


sub group { 'persist' }

sub summary { "Run tests using the persistent test runner" }
sub cli_args { '[--] [test files/dirs] [::] [arguments to test scripts] [test_file.t] [test_file2.t="--arg1 --arg2 --param=\'foo bar\'"] [:: --argv-for-all-tests]' }

sub description {
    return <<"    EOT";
This command will run tests through an already started persistent instance. See
the start command for details on how to launch a persistant instance.
    EOT
}

sub terminate_queue {}
sub write_settings_to {}
sub setup_plugins {}
sub setup_resources {}
sub teardown_plugins {}
sub finalize_plugins {}
sub pfile_params { () }


sub monitor_preloads { 1 }
sub job_count { 1 }

sub run {
    my $self = shift;

    my $settings = $self->settings;

    if ($settings->run->check_reload_state) {
        return 255 unless $self->check_reload_state;
    }

    return $self->SUPER::run(@_);
}

sub check_reload_state {
    my $self = shift;

    my $state = Test2::Harness::Runner::State->new(
        job_count    => 1,
        workdir      => $self->workdir,
    );

    $state->poll;

    my $reload_status = $state->reload_state // {};

    my (@out, $errors, $warnings, %seen);
    for my $stage (sort keys %$reload_status) {
        for my $file (keys %{$reload_status->{$stage}}) {
            next if $seen{$file}++;
            my $data = $reload_status->{$stage}->{$file} or next;

            push @out => "\n==== SOURCE FILE: $file ====\n";
            if ($data->{error}) {
                $errors++;
                push @out => $data->{error};
            }

            for (@{$data->{warnings} // []}) {
                push @out => $_;
                $warnings++;
            }
        }
    }
    $errors //= 0;
    $warnings //= 0;

    return 1 unless @out || $errors || $warnings;

    print <<"    EOT", @out;
*******************************************************************************
* Some source files were reloaded with errors or warnings
* Errors: $errors
* Warnings: $warnings
*******************************************************************************

    EOT

    if ($errors) {
        print <<"        EOT";

*******************************************************************************
Aborting due to reload errors. Please fix the errors so that the modules reload
cleanly, then try the run again. In most cases you will not need to reload the
runner, simply fix the problem with the source file(s) and the runner will
reload them automatically.

        EOT

        return 0;
    }
    elsif ($warnings) {
        print <<"        EOT";

*******************************************************************************
Warnings were encountered when reloading source files, please see the output
above. If these warnings are a problem you should abort this run (control+c)
and correct them before trying again. In most cases you will not need to reload
the runner, simply fix the problem with the source file(s) and the runner will
reload them automatically.

If these warnings are not indicitive of a problem you may continue by pressing
enter/return.

        EOT

        if (-t STDIN) {
            my $ignore = <STDIN>;
            return 1;
        }
        else {
            print STDERR "No TTY detected, aborting run due to warnings...\n";
            return 0;
        }
    }

    return 0;
}

sub init {
    my $self = shift;

    my $settings = $self->settings;
    my $pdata = $self->pfile_data;

    my $runner_settings = Test2::Harness::Util::File::JSON->new(name => $pdata->{dir} . '/settings.json')->read();

    for my $prefix (sort keys %{$runner_settings}) {
        next if $settings->check_prefix($prefix);

        my $new = $settings->define_prefix($prefix);
        ${$new->vivify_field('from_runner')} = 1;
        for my $key (sort keys %{$runner_settings->{$prefix}}) {
            ${$new->vivify_field($key)} = $runner_settings->{$prefix}->{$key};
        }
    }

    return $self->SUPER::init(@_);
}

sub pfile {
    my $self = shift;
    $self->{+PFILE} //= find_pfile($self->settings, $self->pfile_params) or die "No persistent harness was found for the current path.\n";
}

sub pfile_data {
    my $self = shift;
    return $self->{+PFILE_DATA} if $self->{+PFILE_DATA};

    my $pfile = $self->pfile;

    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();
    $data->{pfile_path} //= $pfile;

    print "\nFound: $data->{pfile_path}\n";
    print "  PID: $data->{pid}\n";
    print "  Dir: $data->{dir}\n";

    return $self->{+PFILE_DATA} = $data;
}

sub workdir {
    my $self = shift;
    return $self->pfile_data->{dir};
}

sub start_runner {
    my $self = shift;

    my $data = $self->pfile_data;

    $self->{+RUNNER_PID} = $data->{pid};
}

1;

__END__

=head1 POD IS AUTO-GENERATED

