package Test2::Harness::Resource;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Term::Table;

use Test2::Harness::Util qw/parse_exit/;
use Test2::Harness::IPC::Util qw/start_collected_process ipc_connect set_procname/;
use Test2::Harness::Util::JSON qw/decode_json encode_json/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util::HashBase qw{
    <is_subprocess
    <subprocess_pid
    <resource_id
};

sub init {
    my $self = shift;
    $self->{+RESOURCE_ID} //= gen_uuid();
}

sub spawns_process { 0 }
sub is_job_limiter { 0 }

sub setup    { }
sub teardown { }
sub tick     { }
sub cleanup  { }

sub subprocess_args { () }

sub resource_name { 'Resource' }
sub resource_io_tag { 'RESOURCE' }

sub applicable     { croak "'$_[0]' does not implement 'applicable'" }
sub available      { croak "'$_[0]' does not implement 'available'" }
sub assign         { croak "'$_[0]' does not implement 'assign'" }
sub release        { croak "'$_[0]' does not implement 'release'" }
sub subprocess_run { croak "'$_[0]' does not implement 'subprocess_run'" }

sub DESTROY {
    my $self = shift;
    $self->cleanup();
}

sub sort_weight {
    my $class = shift;
    return 100 if $class->is_job_limiter;
    return 50;
}

sub subprocess_exited {
    my $self = shift;
    my %params = @_;

    my $pid       = $params{pid};
    my $exit      = $params{exit};
    my $scheduler = $params{scheduler};

    my $x = parse_exit($exit);

    warn "'$self' sub-process '$pid' exited (Code: $x->{err}, Signal: $x->{sig})"
        if $exit;
}

sub spawn_class {
    my $self = shift;
    return ref($self) || $self;
}

sub spawn_command {
    my $self   = shift;
    my %params = @_;

    my $class    = $self->spawn_class;
    my $instance = $params{instance};

    my %seen;
    return (
        $^X,                                                       # Call current perl
        (map { ("-I$_") } grep { -d $_ && !$seen{$_}++ } @INC),    # Use the dev libs specified
        "-m$class",                                                # Load Resource
        '-e' => "exit($class->_subprocess_run(\$ARGV[0]))",        # Run it.
        encode_json({parent_pid => $$, $self->subprocess_args}),        # json data
    );
}

sub spawn_process {
    my $self = shift;
    my %params = @_;

    my $scheduler = $params{scheduler} or die "'scheduler' is required";

    my @spawn_cmd = $self->spawn_command(%params);

    my $pid = start_collected_process(
        instance_ipc => $params{instance_ipc},
        io_pipes     => $ENV{T2_HARNESS_PIPE_COUNT},
        command      => \@spawn_cmd,
        root_pid     => $$,
        type         => 'resource',
        name         => $self->resourse_name,
        tag          => $self->resource_io_tag,
        setsid       => 0,
        forward_exit => 1,
    );

    $scheduler->register_child($pid, 'resource', $self->resourse_name, sub { $self->subprocess_exited(@_) });

    return $pid;
}

sub _subprocess_run {
    my $class = shift;
    my ($json) = @_;

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    my $params = decode_json($json);

    set_procname(set => ['resource', $class->resourse_name(%$params)]);

    $class->subprocess_run(%$params);

    exit 0;
}

sub status_data { () }

1;

__END__

Document: cleanup() should be able to be run multiple times, it is called by destroy

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Resource - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

