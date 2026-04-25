package Test2::Harness2::Resource::Preload;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Test2::Harness2::Util qw/mod2file load_module/;

use Test2::Harness2::Preload();
use Test2::Harness2::Preload::Stage();

use Object::HashBase qw{
    <preloads
    <preload_early
    harness_name
    logdir
    +stage_tree
    +stage_states
    +job_stages
    +ipcm_info
    +stage_handles
    +broken
    +permanent_broken
    +paused
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';

sub resource_name { 'preload' }

sub init {
    my $self = shift;

    $self->{+PRELOADS}      //= [];
    $self->{+PRELOAD_EARLY} //= {};
    $self->{+HARNESS_NAME}  //= 'harness';
    $self->{+STAGE_STATES}  //= {};
    $self->{+JOB_STAGES}    //= {};
    $self->{+STAGE_HANDLES} //= {};

    my $tree = Test2::Harness2::Preload->new;

    for my $mod (@{$self->{+PRELOADS}}) {
        my $ok  = eval { require(mod2file($mod)); 1 };
        my $err = $@;
        unless ($ok) {
            warn "Failed to load preload module '$mod': $err";
            next;
        }
        $tree->merge($mod->TEST2_HARNESS_PRELOAD()) if $mod->can('TEST2_HARNESS_PRELOAD');
    }

    $self->{+STAGE_TREE} = $tree;

    $self->{+STAGE_STATES}{'preload-root'} = 'pending';
    $self->{+STAGE_STATES}{$_} = 'pending' for keys %{$tree->stage_lookup};
}

sub is_broken           { $_[0]->{+BROKEN}           ? 1 : 0 }
sub is_permanent_broken { $_[0]->{+PERMANENT_BROKEN} ? 1 : 0 }
sub is_paused           { $_[0]->{+PAUSED}           ? 1 : 0 }

sub mark_broken { $_[0]->{+BROKEN} = 1 }

sub mark_permanent_broken {
    my $self = shift;
    $self->{+BROKEN}           = 1;
    $self->{+PERMANENT_BROKEN} = 1;
}

sub mark_paused  { $_[0]->{+PAUSED} = 1 }

sub mark_resumed {
    my $self = shift;
    $self->{+PAUSED} = 0;
    $self->{+BROKEN} = 0 unless $self->{+PERMANENT_BROKEN};
}

sub set_ipcm_info {
    my ($self, $info) = @_;
    $self->{+IPCM_INFO}     = $info;
    $self->{+STAGE_HANDLES} = {};
}

sub needed {
    my ($self, %p) = @_;
    my $job = $p{job} or croak "'job' is required";
    return $job->test_file->check_feature('preload') ? 1 : 0;
}

sub available {
    my ($self, %p) = @_;
    my $job = $p{job} or croak "'job' is required";

    my $stage_name = $self->_stage_for_job($job);
    my $state = $self->{+STAGE_STATES}{$stage_name} // 'pending';

    return 0 unless $state eq 'up';
    return 1;
}

sub assign {
    my ($self, %p) = @_;

    my $id  = $p{id}  or croak "'id' is required";
    my $job = $p{job} or croak "'job' is required";

    croak "duplicate assign for id '$id'" if exists $self->{+JOB_STAGES}{$id};

    $self->{+JOB_STAGES}{$id} = $self->_stage_for_job($job);
    return 1;
}

sub release {
    my ($self, %p) = @_;
    my $id = $p{id} or croak "'id' is required";
    delete $self->{+JOB_STAGES}{$id};
    return 1;
}

sub services {
    my $self = shift;

    return (
        [
            'Test2::Harness2::ResourceService::PreloadRoot',
            name          => 'preload-root',
            preloads      => $self->{+PRELOADS},
            preload_early => $self->{+PRELOAD_EARLY},
            harness_name  => $self->{+HARNESS_NAME},
            (defined $self->{+LOGDIR} ? (logdir => $self->{+LOGDIR}) : ()),
        ],
    );
}

sub set_stage_up {
    my ($self, $name) = @_;
    $self->{+STAGE_STATES}{$name} = 'up';
    $self->{+BROKEN} = 0 unless $self->{+PERMANENT_BROKEN};
}

sub set_stage_down {
    my ($self, $name) = @_;
    $self->{+STAGE_STATES}{$name} = 'down';
}

sub stage_handle_for_job {
    my ($self, $job) = @_;

    return undef unless $self->{+IPCM_INFO};

    my $stage_name = $self->_stage_for_job($job);
    return undef unless ($self->{+STAGE_STATES}{$stage_name} // '') eq 'up';

    return $self->{+STAGE_HANDLES}{$stage_name} //= do {
        require IPC::Manager::Service::Handle;
        IPC::Manager::Service::Handle->new(
            service_name => $stage_name,
            ipcm_info    => $self->{+IPCM_INFO},
        );
    };
}

sub status {
    my $self = shift;

    return {
        resource  => $self->resource_name,
        broken    => $self->is_broken,
        paused    => $self->is_paused,
        permanent => $self->is_permanent_broken,
        stages    => {%{$self->{+STAGE_STATES}}},
    };
}

sub _stage_for_job {
    my ($self, $job) = @_;

    my $tf        = $job->test_file;
    my $requested = $tf->check_stage if $tf->can('check_stage');

    if ($requested && exists $self->{+STAGE_STATES}{$requested}) {
        return $requested;
    }

    my $default = $self->{+STAGE_TREE}->default_stage;
    if ($default) {
        my $name = ref($default) ? $default->name : $default;
        return $name if exists $self->{+STAGE_STATES}{$name};
    }

    return 'preload-root';
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::Preload - Resource that routes tests through
preload stage services.

=head1 DESCRIPTION

Implements L<Test2::Harness2::Role::Resource> for preload support.
Reads the preload DSL from the modules listed in C<preloads>, builds
an internal stage tree, and declares a
L<Test2::Harness2::ResourceService::PreloadRoot> service. The harness
injects C<ipcm_info> after construction so the resource can build
L<IPC::Manager::Service::Handle> objects for routing C<launch_job>
requests to the appropriate stage service.

Stage state (C<pending> / C<up> / C<down>) is updated by the harness
when it receives C<stage_up> / C<stage_down> service events from the
PreloadRoot service.

=head1 ATTRIBUTES

=over 4

=item preloads

Arrayref of module names. Plain modules are loaded by the stage service;
modules that export C<TEST2_HARNESS_PRELOAD()> contribute stage-tree
definitions that drive per-test routing.

=item preload_early

Optional hashref of early-load modules passed through to the root
service (loaded before the preload recipe).

=back

=head1 METHODS

Implements the L<Test2::Harness2::Role::Resource> interface. See that
role for the contract on C<needed>, C<available>, C<assign>, C<release>,
and C<status>.

=over 4

=item $resource->set_ipcm_info($info)

Inject the harness's C<ipcm_info> so the resource can create service
handles. Invalidates any cached stage handles.

=item $resource->set_stage_up($name)

Mark stage C<$name> as ready. Clears transient brokenness on the
resource (but not permanent brokenness).

=item $resource->set_stage_down($name)

Mark stage C<$name> as down.

=item $handle_or_undef = $resource->stage_handle_for_job($job)

Return an L<IPC::Manager::Service::Handle> for the stage that should
run C<$job>, or C<undef> if C<ipcm_info> has not been injected yet or
the target stage is not up.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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
