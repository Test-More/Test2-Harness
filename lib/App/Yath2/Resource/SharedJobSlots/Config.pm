package App::Yath2::Resource::SharedJobSlots::Config;
use strict;
use warnings;

our $VERSION = '2.000011';

use YAML::Tiny;
use Sys::Hostname qw/hostname/;
use Carp qw/croak/;

use Test2::Harness2::Util qw/find_in_updir mod2file/;

use Object::HashBase qw{
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
    my $config_file = delete $opts{config_file};

    unless ($config_file) {
        $base_name //= '.sharedjobslots.yml';
        $config_file = ($base_name =~ m{(/|\\)} || -e $base_name) ? $base_name : find_in_updir($base_name);
    }

    return unless $config_file && -e $config_file;

    return $class->new(%opts, config_file => $config_file);
}

sub init {
    my $self = shift;

    my $config_file = $self->{+CONFIG_FILE};

    my $config = YAML::Tiny->read($config_file) or die "Could not read '$config_file'";
    $config = $self->{+CONFIG_RAW} = $config->[0];    # First doc only

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

    # Sanity check
    $self->max_slots;

    return;
}

sub state_umask           { $_[0]->{+STATE_UMASK}           //= $_[0]->_get_config_option(+STATE_UMASK,           default  => 0007) }
sub state_file            { $_[0]->{+STATE_FILE}            //= $_[0]->_get_config_option(+STATE_FILE,            required => 1) }
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
        require App::Yath2::Resource::SharedJobSlots::State;

        my $short = $algorithm;
        $algorithm = "_redistribute_$algorithm";

        die "'$short' is not a valid algorithm (in file '$self->{+CONFIG_FILE}' under host '$self->{+HOST}' key 'algorithm'). Must be 'fair', 'first', or a Fully::Qualified::Module::function_name."
            unless App::Yath2::Resource::SharedJobSlots::State->can($algorithm);
    }

    return $self->{+ALGORITHM} = $algorithm;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Resource::SharedJobSlots::Config - Config for shared job slots

=head1 DESCRIPTION

Loads a C<.sharedjobslots.yml> file and exposes its per-host
configuration to L<App::Yath2::Resource::SharedJobSlots>. The config
file is a YAML document keyed by hostname; a C<COMMON> section
provides shared defaults and a C<DEFAULT> section is used when the
running host is not present in the file. See the POD on
L<App::Yath2::Resource::SharedJobSlots> for the expected config shape
and available keys.

=head1 CLASS METHODS

=over 4

=item $conf = $class->find(%opts)

Locate and load a config file. Recognised options:

=over 4

=item base_name =E<gt> '.sharedjobslots.yml'

Filename to search for. Looked up starting in cwd via
C<find_in_updir>; if the value contains a path separator it is used
directly.

=item config_file =E<gt> '/path/to/.sharedjobslots.yml'

Explicit absolute or relative path to the config file. Overrides
C<base_name>.

=item host =E<gt> 'some-host'

Override the hostname used to select the per-host config section.
Defaults to the running host's L<Sys::Hostname/hostname>.

=back

Returns C<undef> if no config file can be located; otherwise returns
a fully-constructed instance with the host-specific config parsed and
sanity-checked.

=back

=head1 ACCESSORS

All accessors return the value for the selected host, falling back to
C<COMMON> and then to the documented default:

=over 4

=item state_umask

Defaults to C<0007>.

=item state_file

Required. Absolute path to the shared-state JSON file.

=item max_slots

Required. System-wide slot pool size.

=item max_slots_per_job

Defaults to C<max_slots>.

=item max_slots_per_run

Defaults to C<max_slots>.

=item min_slots_per_run

Defaults to C<0>.

=item default_slots_per_job

Defaults to C<max_slots_per_job>.

=item default_slots_per_run

Defaults to C<max_slots_per_run>.

=item algorithm

Defaults to C<'fair'>. Resolved to a method name on
L<App::Yath2::Resource::SharedJobSlots::State> (C<fair> /
C<first>) or a fully qualified subroutine name the caller supplies.

=item disabled

Defaults to false.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
