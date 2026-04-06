package App::Yath::Option::Adapter;
use strict;
use warnings;

our $VERSION = '1.000168';

use Carp qw/confess/;
use Scalar::Util qw/blessed/;

# This adapter wraps a Getopt::Yath::Option object so it can be used
# wherever an App::Yath::Option is expected. It delegates attribute access
# to the wrapped object and translates where the APIs differ.

# Type mapping from Getopt::Yath::Option subclass to old-style type letter
my %CLASS_TO_TYPE = (
    'Getopt::Yath::Option::Bool'     => 'b',
    'Getopt::Yath::Option::Scalar'   => 's',
    'Getopt::Yath::Option::Count'    => 'c',
    'Getopt::Yath::Option::List'     => 'm',
    'Getopt::Yath::Option::Map'      => 'h',
    'Getopt::Yath::Option::Auto'     => 'd',
    'Getopt::Yath::Option::AutoList' => 'D',
    'Getopt::Yath::Option::AutoMap'  => 'H',
    'Getopt::Yath::Option::BoolMap'  => 'H',
);

sub new {
    my ($class, %args) = @_;

    my $inner = $args{inner} or confess "The 'inner' attribute (a Getopt::Yath::Option instance) is required";

    confess "'inner' must be a Getopt::Yath::Option instance, got '$inner'"
        unless blessed($inner) && $inner->isa('Getopt::Yath::Option');

    return bless {
        inner        => $inner,
        from_plugin  => $args{from_plugin},
        from_command => $args{from_command},
    }, $class;
}

sub inner { $_[0]->{inner} }

# Translate group -> prefix
sub prefix { $_[0]->{inner}->group }

# Direct delegation for methods with matching names
sub name        { $_[0]->{inner}->name }
sub field       { $_[0]->{inner}->field }
sub title       { $_[0]->{inner}->title }
sub short       { $_[0]->{inner}->short }
sub alt         { $_[0]->{inner}->alt }
sub category    { $_[0]->{inner}->category }
sub description { $_[0]->{inner}->description }
sub trace       { $_[0]->{inner}->trace }
sub trace_string { $_[0]->{inner}->trace_string }
sub long_args   { $_[0]->{inner}->long_args }
sub autofill    { $_[0]->{inner}->autofill }
sub pre_process { undef }     # Getopt::Yath doesn't have this concept directly
sub adds_options { $_[0]->{inner}->mod_adds_options }

sub from_plugin  { $_[0]->{from_plugin} }
sub from_command { $_[0]->{from_command} }

# Options from Getopt::Yath are not pre-command by default; this can be
# overridden if needed. The old system used pre_command to determine
# whether to show an option before or after the command. Getopt::Yath
# options included via the bridge are typically command options.
sub pre_command { 0 }

# Env vars: Getopt::Yath uses from_env_vars, old system uses env_vars
sub env_vars       { $_[0]->{inner}->from_env_vars }
sub clear_env_vars {
    my $val = $_[0]->{inner}->clear_env_vars;
    return $val if ref($val) eq 'ARRAY';
    return $val ? 1 : 0;  # old-style boolean for backward compat
}

# Derive the old-style type letter from the Getopt::Yath::Option subclass
sub type {
    my $self = shift;
    my $class = ref($self->{inner});
    return $CLASS_TO_TYPE{$class} // 's';    # default to scalar if unknown
}

sub requires_arg {
    my $self = shift;
    my $type = $self->type;

    # Use the old-style type semantics for requires_arg/allows_arg
    # to ensure the old parser handles these correctly.
    my %REQUIRES_ARG = (s => 1, m => 1, h => 1, H => 1);
    return $REQUIRES_ARG{$type};
}

sub allows_arg {
    my $self = shift;
    my $type = $self->type;

    my %REQUIRES_ARG = (s => 1, m => 1, h => 1, H => 1);
    my %ALLOWS_ARG   = (d => 1, D => 1);
    return $ALLOWS_ARG{$type} || $REQUIRES_ARG{$type};
}

sub default {
    my $self = shift;
    my $inner = $self->{inner};

    # Getopt::Yath uses 'initialize' for what legacy calls 'default'
    if (exists $inner->{initialize}) {
        return $inner->{initialize};
    }

    # Fall back to the inner default if it allows defaults
    return $inner->{default} if exists $inner->{default};

    return undef;
}

# applicable: Getopt::Yath uses is_applicable($options, $settings)
# Old system uses applicable($options) where the callback is ($opt, $options)
sub applicable {
    my $self = shift;
    my ($options) = @_;
    my $cb = $self->{inner}->{applicable} or return 1;
    return $self->{inner}->$cb($options, undef);
}

sub option_slot {
    my $self = shift;
    my ($settings) = @_;

    confess "A settings instance is required" unless $settings;
    return $settings->define_prefix($self->prefix)->vivify_field($self->field);
}

sub get_default {
    my $self  = shift;
    my $inner = $self->{inner};

    # Check env vars first (same logic as old App::Yath::Option)
    for my $var (@{$inner->from_env_vars // []}) {
        my $env = "$var";
        my ($neg) = $env =~ s/^(!)//;
        next unless exists $ENV{$env};
        return !$ENV{$env} if $neg;
        return $ENV{$env};
    }

    # Check for explicit default on the inner option
    # Getopt::Yath uses 'default' (evaluated at finalize time)
    # and 'initialize' (evaluated at init time).
    if (exists $inner->{default}) {
        my $default = $inner->{default};
        return ref($default) eq 'CODE' ? $default->() : $default;
    }

    if (exists $inner->{initialize}) {
        my $init = $inner->{initialize};
        return ref($init) eq 'CODE' ? $init->() : $init;
    }

    # Fall back to type-appropriate defaults
    my $type = $self->type;

    return 0
        if $type eq 'c'
        || $type eq 'b';

    return []
        if $type eq 'm'
        || $type eq 'D';

    return {}
        if $type eq 'h'
        || $type eq 'H';

    return undef;
}

sub get_normalized {
    my $self = shift;
    my ($raw) = @_;

    my $inner = $self->{inner};

    # Try normalize callback first
    if ($inner->{normalize}) {
        return ($inner->normalize_value($raw))[0];
    }

    # Fall back to old-style normalization based on type
    my $type = $self->type;

    return $raw ? 1 : 0 if $type eq 'b';

    if (lc($type) eq 'h') {
        my ($key, $val) = split /=/, $raw, 2;

        if ($type eq 'H') {
            $val //= '';
            $val = [split /,/, $val];
            return [$key, $val];
        }

        return [$key, $val // 1];
    }

    return $raw;
}

# Handlers per type, matching the old App::Yath::Option behavior
my %HANDLERS = (
    c => sub { ${$_[0]}++ },
    m => sub { push @{${$_[0]} //= []} => $_[1] && ref($_[1]) eq 'ARRAY' ? @{$_[1]} : $_[1] },
    D => sub { push @{${$_[0]} //= []} => $_[1] && ref($_[1]) eq 'ARRAY' ? @{$_[1]} : $_[1] },
    h => sub {
        my $hash = ${$_[0]} //= {};
        my $key = $_[1]->[0];
        my $val = $_[1]->[1];
        push @{$hash->{'@'} //= []} => $key unless $hash->{$key};
        $hash->{$key} = $val;
    },
    H => sub {
        my $hash = ${$_[0]} //= {};
        my $key = $_[1]->[0];
        my $vals = $_[1]->[1];
        push @{$hash->{'@'} //= []} => $key unless $hash->{$key};
        push @{$hash->{$key} //= []} => @$vals;
    },
);

sub handle {
    my $self = shift;
    my ($raw, $settings, $options, $list) = @_;

    confess "A settings instance is required" unless $settings;
    confess "An options instance is required" unless $options;

    my $slot = $self->option_slot($settings);
    my $norm = $self->get_normalized($raw);

    my $type = $self->type;
    my $handler = $HANDLERS{$type} //= sub { ${$_[0]} = $_[1] };

    # Getopt::Yath options don't have a legacy action callback,
    # but they may have a trigger. We fire the trigger if present.
    my $inner = $self->{inner};
    if ($inner->{trigger}) {
        my $group = $settings->define_prefix($self->prefix);
        $inner->trigger(
            action   => 'set',
            ref      => $slot,
            val      => [ref($norm) eq 'ARRAY' ? @$norm : $norm],
            settings => $settings,
            group    => $group,
            options  => $options,
        );
    }

    return $handler->($slot, $norm);
}

sub handle_negation {
    my $self = shift;
    my ($settings, $options) = @_;

    confess "A settings instance is required" unless $settings;
    confess "An options instance is required" unless $options;

    my $slot = $self->option_slot($settings);

    # Try clear from the inner option
    my $inner = $self->{inner};
    if ($inner->{trigger}) {
        my $group = $settings->define_prefix($self->prefix);
        $inner->trigger(
            action   => 'clear',
            ref      => $slot,
            val      => undef,
            settings => $settings,
            group    => $group,
            options  => $options,
        );
    }

    my $type = $self->type;

    return $$slot = 0
        if $type eq 'b'
        || $type eq 'c';

    return @{$$slot //= []} = ()
        if $type eq 'm'
        || $type eq 'D';

    return %{$$slot //= {}} = ()
        if $type eq 'h'
        || $type eq 'H';

    return $$slot = undef;
}

sub cli_docs {
    my $self = shift;
    return $self->{inner}->cli_docs(@_);
}

sub pod_docs {
    my $self = shift;
    return $self->{inner}->pod_docs(@_);
}

# Make the adapter pass isa checks for App::Yath::Option
sub isa {
    my ($self, $class) = @_;
    return 1 if $class eq 'App::Yath::Option';
    return $self->SUPER::isa($class);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Option::Adapter - Wraps Getopt::Yath::Option for use in App::Yath::Options

=head1 DESCRIPTION

This adapter allows a C<Getopt::Yath::Option> instance to be used anywhere
an C<App::Yath::Option> is expected. It translates between the two APIs,
delegating to the wrapped object where possible.

=head1 SYNOPSIS

    use App::Yath::Option::Adapter;

    my $adapter = App::Yath::Option::Adapter->new(
        inner => $getopt_yath_option,
    );

    # Now works like an App::Yath::Option
    my $name = $adapter->name;
    my $type = $adapter->type;    # Returns old-style type letter

=cut
