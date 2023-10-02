package Test2::Harness::Runner::Resource::SharedJobSlots::Config;
use strict;
use warnings;

our $VERSION = '1.000155';

use YAML::Tiny;
use Sys::Hostname qw/hostname/;
use App::Yath::Util qw/find_in_updir/;

use Test2::Harness::Util::HashBase qw{
    <config_file
    <config_raw

    <host

    <common_conf
    <host_conf

    +state_file
    +state_umask
    +algorithm
    +max_slots
    +max_slots_per_job
    +max_slots_per_run
    +min_slots_per_run
    +default_slots_per_job
    +default_slots_per_run
    +disabled
};

sub find {
    my $class = shift;
    my (%opts) = @_;

    my $base_name   = delete $opts{base_name};
    my $settings    = delete $opts{settings};
    my $config_file = delete $opts{config_file};

    unless ($config_file) {
        $base_name //= ($settings && $settings->check_prefix('runner')) ? $settings->runner->shared_jobs_config : '.sharedjobslots.yml';
        $config_file = ($base_name =~ m{(/|\\)} || -e $base_name) ? $base_name : find_in_updir($base_name);
    }

    return unless $config_file && -e $config_file;

    return $class->new(%opts, config_file => $config_file);
}

sub init {
    my $self = shift;

    my $config_file = $self->{+CONFIG_FILE};

    my $config = YAML::Tiny->read($config_file) or die "Could not read '$config_file'";
    $config = $self->{+CONFIG_RAW} = $config->[0]; # First doc only

    my $host = $self->{+HOST} //= hostname();

    # Normalize an empty host config section to a hashref
    $config->{$host} ||= {} if exists $config->{$host};

    unless ($self->{+HOST_CONF} = $config->{$host}) {
        if ($self->{+HOST_CONF} = $config->{DEFAULT}) {
            $self->{+HOST} = 'DEFAULT';
        }
        else {
            die "Could not find '$host' or 'DEFAULT' settings in '$config_file'.\n";
        }

        warn <<"        EOT" unless $self->{+HOST_CONF}->{no_warning};
Using the 'DEFAULT' shared-slots host config.
You may want to add the current host to the config file.
To silence this warning, set the 'no_warning' key to true in the DEFAULT host config.
 Config File: $config_file
Current Host: $host
        EOT
    }

    if ($self->{+HOST_CONF}->{use_common} //= 1) {
        $self->{+COMMON_CONF} = $config->{'COMMON'} // {};
    }

    $self->{+COMMON_CONF} //= {};

    #sanity check
    $self->max_slots;

    return;
}

sub state_umask           { $_[0]->{+STATE_UMASK}           //= $_[0]->_get_config_option(+STATE_UMASK,           default  => 0007) }
sub state_file            { $_[0]->{+STATE_FILE}            //= $_[0]->_get_config_option(+STATE_FILE,            require  => 1) }
sub max_slots             { $_[0]->{+MAX_SLOTS}             //= $_[0]->_get_config_option(+MAX_SLOTS,             required => 1) }
sub min_slots_per_run     { $_[0]->{+MIN_SLOTS_PER_RUN}     //= $_[0]->_get_config_option(+MIN_SLOTS_PER_RUN,     default  => 0) }
sub max_slots_per_job     { $_[0]->{+MAX_SLOTS_PER_JOB}     //= $_[0]->_get_config_option(+MAX_SLOTS_PER_JOB,     default  => $_[0]->max_slots) }
sub max_slots_per_run     { $_[0]->{+MAX_SLOTS_PER_RUN}     //= $_[0]->_get_config_option(+MAX_SLOTS_PER_RUN,     default  => $_[0]->max_slots) }
sub default_slots_per_job { $_[0]->{+DEFAULT_SLOTS_PER_JOB} //= $_[0]->_get_config_option(+DEFAULT_SLOTS_PER_JOB, default  => $_[0]->max_slots_per_job) }
sub default_slots_per_run { $_[0]->{+DEFAULT_SLOTS_PER_RUN} //= $_[0]->_get_config_option(+DEFAULT_SLOTS_PER_RUN, default  => $_[0]->max_slots_per_run) }
sub disabled              { $_[0]->{+DISABLED}              //= $_[0]->_get_config_option(+DISABLED,              default  => 0) }

sub _get_config_option {
    my $self = shift;
    my ($field, %opts) = @_;

    my $val = $self->{+HOST_CONF}->{$field} // $self->{+COMMON_CONF}->{$field} // $opts{default};

    die "'$field' not set in '$self->{+CONFIG_FILE}' for host '$self->{+HOST}' or under 'COMMON' config.\n" 
        if $opts{required} && !defined($val);

    return $val;
}

sub algorithm {
    my $self = shift;

    return $self->{+ALGORITHM} if $self->{+ALGORITHM};

    my $algorithm = $self->_get_config_option(+ALGORITHM, default => 'fair');

    if ($algorithm =~ m/^(.*)::([^:]+)$/) {
        my ($mod, $sub) = ($1, $2);
        require(mod2file($mod));
    }
    else {
        require Test2::Harness::Runner::Resource::SharedJobSlots::State;

        my $short = $algorithm;
        $algorithm = "_redistribute_$algorithm";

        die "'$short' is not a valid algorithm (in file '$self->{+CONFIG_FILE}' under host '$self->{+HOST}' key 'algorithm'). Must be 'fair', 'first', or a Fully::Qualified::Module::function_name."
            unless Test2::Harness::Runner::Resource::SharedJobSlots::State->can($algorithm);
    }

    return $self->{+ALGORITHM} = $algorithm;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Resource::SharedJobSlots::Config - Config for shared job slots

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

Copyright 2022 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
