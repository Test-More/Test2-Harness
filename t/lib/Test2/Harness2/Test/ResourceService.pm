package Test2::Harness2::Test::ResourceService;
use strict;
use warnings;

# Factory for throw-away ResourceService classes used in unit tests,
# plus an ipcm_service stub that hands back a fake handle with a
# canned child_pid. The stub dispatches by service class, so each
# generated class can carry its own pid queue / die-on-spawn message.

use Carp qw/croak/;

use Test2::Harness2::Role::ResourceService;
use Test2::Harness2::Role::ResourceServiceHost;

my $COUNTER     = 0;
my $STUB_LOADED = 0;

# Build a fresh class that composes Test2::Harness2::Role::ResourceService
# and fakes the IPC::Manager::Role::Service contract bits tests care
# about. Options:
#
#   restartable => 0|1              (default 0)
#   pids        => \@pid_queue      -- stub shifts one pid per spawn call
#   pid         => $scalar          -- alternative: constant pid every spawn
#   spawn_die   => "$msg"           -- stub croaks with $msg on spawn
#
# Returns the generated class name.
sub make_service_class {
    my %opts = @_;

    _install_ipcm_service_stub();

    my $restartable = $opts{restartable} ? 1 : 0;
    my $pids        = $opts{pids};
    my $static_pid  = $opts{pid};
    my $spawn_die   = $opts{spawn_die};

    my $pkg = __PACKAGE__ . '::Generated' . ++$COUNTER;

    {
        no strict 'refs';

        # IPC::Manager::Role::Service contract.
        *{"${pkg}::new"} = sub {
            my ($class, @args) = @_;
            return bless {@args}, $class;
        };
        *{"${pkg}::orig_io"}        = sub { {} };
        *{"${pkg}::name"}           = sub { $_[0]->{name} };
        *{"${pkg}::run"}            = sub { 0 };
        *{"${pkg}::ipcm_info"}      = sub { $_[0]->{ipcm_info} };
        *{"${pkg}::pid"}            = sub { $_[0]->{pid} };
        *{"${pkg}::set_pid"}        = sub { $_[0]->{pid} = $_[1] };
        *{"${pkg}::watch_pids"}     = sub { $_[0]->{watch_pids} // [] };
        *{"${pkg}::handle_request"} = sub { {} };

        # ResourceService-specific.
        *{"${pkg}::restartable"} = sub { $restartable };

        # Stub hooks.
        *{"${pkg}::_next_pid"} = sub {
            return $static_pid if defined $static_pid;
            return undef unless $pids && @$pids;
            return shift @$pids;
        };
        *{"${pkg}::_spawn_die"} = sub { $spawn_die };
    }

    Role::Tiny->apply_roles_to_package($pkg, 'Test2::Harness2::Role::ResourceService');

    return $pkg;
}

# Override the ipcm_service symbol the host role imported. The stub
# looks at the %params to find the requested class, consults that
# class's _spawn_die / _next_pid hooks, and returns a fake handle with
# a child_pid accessor. Tests never actually fork.
sub _install_ipcm_service_stub {
    return if $STUB_LOADED;
    $STUB_LOADED = 1;

    no warnings 'redefine';
    *Test2::Harness2::Role::ResourceServiceHost::ipcm_service = sub {
        my ($name, %params) = @_;
        my $class = $params{class}
            or croak "test ipcm_service stub: missing 'class' in params";

        if ($class->can('_spawn_die')) {
            if (my $msg = $class->_spawn_die) {
                croak $msg;
            }
        }

        my $pid = $class->can('_next_pid') ? $class->_next_pid : undef;
        croak "test ipcm_service stub: no pid available for class '$class' (service '$name')"
            unless defined $pid;

        return bless {
            child_pid => $pid,
            name      => $name,
            class     => $class,
            },
            'Test2::Harness2::Test::ResourceService::FakeHandle';
    };

    return;
}

package Test2::Harness2::Test::ResourceService::FakeHandle;

sub child_pid { $_[0]->{child_pid} }
sub name      { $_[0]->{name} }

1;
