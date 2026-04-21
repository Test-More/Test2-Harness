package Test2::Harness2::Test::ResourceService;
use strict;
use warnings;

# Factory for throw-away ResourceService classes used in unit tests.
# Each call installs a fresh package so tests that want different
# restartable / spawn behaviour don't step on each other.

use Carp qw/croak/;

use Test2::Harness2::Role::ResourceService;

my $COUNTER = 0;

# Build a fresh class that composes Test2::Harness2::Role::ResourceService
# and fakes the bits of the IPC::Manager::Role::Service contract
# tests care about. Options:
#
#   restartable => 0|1              (default 0)
#   pids        => [\@pid_queue]    -- shift one pid per spawn call
#   pid         => $scalar          -- constant pid every spawn
#   spawn_die   => "$msg"           -- make spawn() croak with $msg
#   new_die     => "$msg"           -- make new() croak with $msg
#   on_spawn    => sub { my ($svc) = @_; ... }  -- called before pid resolution
#
# Returns the generated class name.
sub make_service_class {
    my %opts = @_;

    my $restartable = $opts{restartable} ? 1 : 0;
    my $pids        = $opts{pids};
    my $static_pid  = $opts{pid};
    my $spawn_die   = $opts{spawn_die};
    my $new_die     = $opts{new_die};
    my $on_spawn    = $opts{on_spawn};

    my $pkg = __PACKAGE__ . '::Generated' . ++$COUNTER;

    {
        no strict 'refs';

        # Required by IPC::Manager::Role::Service; these have to
        # exist *before* the role is applied so the role's requires
        # check is satisfied.
        *{"${pkg}::new"} = sub {
            my ($class, @args) = @_;
            croak $new_die if defined $new_die;
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

        *{"${pkg}::restartable"} = sub { $restartable };
        *{"${pkg}::spawn"}       = sub {
            my $self = shift;
            $on_spawn->($self) if $on_spawn;
            croak $spawn_die   if defined $spawn_die;
            return $static_pid if defined $static_pid;
            if ($pids && @$pids) {
                return shift @$pids;
            }
            croak "no pids left for fake spawn in $pkg";
        };
    }

    Role::Tiny->apply_roles_to_package($pkg, 'Test2::Harness2::Role::ResourceService');

    return $pkg;
}

1;
