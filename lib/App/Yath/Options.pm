package App::Yath::Options;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;
use Test2::Harness::Util qw/mod2file/;

use App::Yath::Option();
use Test2::Harness::Settings();

use Test2::Harness::Util::HashBase qw{
    <all <lookup

    <pre_list <cmd_list <post_list

    <post_list_sorted

    <settings

    <args
    <command_class

    <pending_pre <pending_cmd <pending_post

    <used_plugins

    <included

    <set_by_cli
};

sub import {
    my $class  = shift;
    my $caller = caller();

    croak "$caller already has an 'options' method"
        if defined(&{"$caller\::options"});

    my @common;
    my $instance;
    my $options = sub { ($instance //= $class->new()) };
    my $option  = sub { ($instance //= $class->new())->_option([caller()], shift(@_), @common ? (%{$common[-1]}) : (), @_) };
    my $include = sub { ($instance //= $class->new())->include_from(@_) };

    my $post = sub {
        my $cb = pop;
        my $weight = shift // 0;
        my ($applicable) = @_;

        $applicable //= $common[-1]->{applicable} if @common;

        croak "You must provide a callback coderef" unless $cb && ref($cb) eq 'CODE';

        ($instance //= $class->new())->_post($weight, $applicable, $cb);
    };

    my $group = sub {
        my ($set, $sub) = @_;

        my $common = {@common ? (%{$common[-1]}) : (), %$set};

        if (my $class = $common->{builds}) {
            require(mod2file($class));
        }

        push @common => $common;
        my $ok  = eval { $sub->(); 1 };
        my $err = $@;
        pop @common;

        die $err unless $ok;
    };

    {
        no strict 'refs';
        *{"$caller\::post"}            = $post;
        *{"$caller\::option"}          = $option;
        *{"$caller\::options"}         = $options;
        *{"$caller\::option_group"}    = $group;
        *{"$caller\::include_options"} = $include;
    }

    return 1;
}

sub init {
    my $self = shift;

    $self->{+ALL}   //= [];
    $self->{+LOOKUP} //= {};

    $self->{+USED_PLUGINS} //= [];

    $self->{+PRE_LIST} //= [];
    $self->{+CMD_LIST} //= [];
    $self->{+POST_LIST} //= [];

    $self->{+SETTINGS} //= Test2::Harness::Settings->new();

    $self->{+INCLUDED} //= {};

    $self->{+SET_BY_CLI} //= {};

    return $self;
}

sub option {
    my $self = shift;
    $self->_option([caller()], @_);
}

sub include {
    my $self = shift;
    my ($inc) = @_;

    croak "Include must be an instance of ${ \__PACKAGE__ }, got ${ defined($inc) ? \qq['$inc'] : \'undef' }"
        unless $inc && blessed($inc) && $inc->isa(__PACKAGE__);

    $self->include_option($_) for @{$inc->all};

    $self->{+POST_LIST_SORTED} = 0;
    push @{$self->{+POST_LIST}} => @{$inc->post_list};

    return;
}

sub include_from {
    my $self = shift;

    for my $pkg (@_) {
        require(mod2file($pkg)) unless $pkg->can('options');

        next unless $pkg->can('options');
        my $options = $pkg->options or next;
        $self->include($options);

        $self->{+INCLUDED}->{$pkg}++;
        $self->{+INCLUDED}->{$_}++ for keys %{$options->included};
    }

    return;
}

sub populate_pre_defaults {
    my $self = shift;

    for my $opt (@{$self->_pre_command_options}) {
        my $slot = $opt->option_slot($self->{+SETTINGS});
        my $val = $opt->get_default($self->{+SETTINGS});
        $$slot //= $val;
    }
}

sub populate_cmd_defaults {
    my $self = shift;

    croak "The 'command_class' attribute has not yet been set"
        unless $self->{+COMMAND_CLASS};

    for my $opt (@{$self->_command_options()}) {
        my $slot = $opt->option_slot($self->{+SETTINGS});
        my $val = $opt->get_default($self->{+SETTINGS});
        $$slot //= $val;
    }
}

sub grab_pre_command_opts {
    my $self = shift;
    my %config = @_;

    $self->populate_pre_defaults();

    unshift @{$self->{+PENDING_PRE} //= []} => $self->_grab_opts(
        '_pre_command_options',
        'pre-command',
        stop_at_non_opt => 1,
        passthrough => 1,
        %config,
    );
}

sub process_pre_command_opts {
    my $self = shift;
    return unless $self->{+PENDING_PRE};
    $self->_process_opts(delete $self->{+PENDING_PRE});
}

sub set_command_class {
    my $self = shift;
    my ($in) = @_;

    croak "Command class has already been set"
        if $self->{+COMMAND_CLASS};

    my $class = blessed($in) || $in;

    croak "Invalid command class: $class"
        unless $class->isa('App::Yath::Command');

    $self->include_from($class) if $class->can('options');

    return $self->{+COMMAND_CLASS} = $class;
}

sub set_args {
    my $self = shift;
    my ($in) = @_;

    croak "'args' has already been set"
        if $self->{+ARGS};

    return $self->{+ARGS} = $in;
}

sub grab_command_opts {
    my $self = shift;
    my %config = @_;

    croak "The 'command_class' attribute has not yet been set"
        unless $self->{+COMMAND_CLASS};

    $self->populate_cmd_defaults();

    push @{$self->{+PENDING_CMD} //= []} => $self->_grab_opts(
        '_command_options',
        "command (" . $self->{+COMMAND_CLASS}->name . ")",
        %config,
    );
}

sub process_command_opts {
    my $self = shift;
    return unless $self->{+PENDING_CMD};
    $self->_process_opts(delete $self->{+PENDING_CMD});
}

sub process_option_post_actions {
    my $self = shift;
    my ($cmd) = @_;

    croak "The 'args' attribute has not yet been set"
        unless $self->{+ARGS};

    if ($cmd) {
        croak "The 'command_class' attribute has not yet been set"
            unless $self->{+COMMAND_CLASS};

        croak "The process_option_post_actions requires an App::Yath::Command instance, got: " . ($cmd // "undef")
            unless blessed($cmd) && $cmd->isa('App::Yath::Command');

        croak "The command '$cmd' dos not match the expected class '$self->{+COMMAND_CLASS}'"
            unless blessed($cmd) eq $self->{+COMMAND_CLASS};
    }

    unless ($self->{+POST_LIST_SORTED}++) {
        @{$self->{+POST_LIST}} = sort { $a->[0] <=> $b->[0] } @{$self->{+POST_LIST}};
    }

    for my $post (@{$self->{+POST_LIST}}) {
        next if $post->[1] && !$post->[1]->($post->[2], $self);
        $post->[2]->(
            options  => $self,
            args     => $self->{+ARGS},
            settings => $self->{+SETTINGS},
            $cmd ? (command => $cmd) : (),
        );
    }
}

sub _pre_command_options { $_[0]->{+PRE_LIST} }

sub _command_options {
    my $self = shift;

    my $class = $self->{+COMMAND_CLASS} or croak "The 'command_class' attribute has not yet been set";

    my $cmd = $class->name;
    my $cmd_options = $self->{+CMD_LIST} // [];
    my $pre_options = $self->{+PRE_LIST} // [];

    return [grep { $_->applicable($self) } @$cmd_options, @$pre_options];
}

sub _process_opts {
    my $self = shift;
    my ($list) = @_;

    while (my $opt_set  = shift @$list) {
        my ($opt, $meth, @args) = @$opt_set;
        $opt->$meth(@args, $self->{+SETTINGS}, $self, $list);
        $self->{+SET_BY_CLI}->{$opt->prefix}->{$opt->field}++;
        push @{$self->{+USED_PLUGINS}} => $opt->from_plugin if $opt->from_plugin;
    }
}

sub _parse_long_option {
    my $self = shift;
    my ($arg) = @_;

    $arg =~ m/^--((?:no-)?([^=]+))(=(.*))?$/ or confess "Invalid long option: $arg";

    #return (main, full, val);
    return ($2, $1, $3 ? $4 // '' : undef);
}

sub _parse_short_option {
    my $self = shift;
    my ($arg) = @_;

    $arg =~ m/^-([^-])(=)?(.+)?$/ or confess "Invalid short option: $arg";

    #return (main, remain, assign);
    return ($1, $3, $2);
}

sub _handle_long_option {
    my $self = shift;
    my ($arg, $lookup, $args) = @_;

    my ($main, $full, $val) = $self->_parse_long_option($arg);

    my $opt;
    if ($opt = $lookup->{long}->{$full}) {
        if ($opt->requires_arg) {
            $val //= shift(@$args) // die "Option --$full requires an argument.\n";
        }
        elsif($opt->allows_arg) {
            $val //= $opt->autofill // 1;
        }
        else {
            die "Option --$full does not take an argument\n" if defined $val;
            $val = 1;
        }

        return [$opt, 'handle', $val];
    }
    elsif ($opt = $lookup->{long}->{$main}) {
        die "Option --$full does not take an argument\n" if defined $val;
        return [$opt, 'handle_negation'];
    }

    return undef;
}

sub _handle_short_option {
    my $self = shift;
    my ($arg, $lookup, $args) = @_;

    my ($main, $remain, $assign) = $self->_parse_short_option($arg);

    if (my $opt = $lookup->{short}->{$main}) {
        if ($opt->allows_arg) {
            my $val = $remain;

            $val //= '' if $assign;

            if ($opt->requires_arg) {
                $val //= shift(@$args) // die "Option -$main requires an argument.\n";
            }
            else {
                $val //= $opt->autofill // 1;
            }

            $val //= 1;
            return [$opt, 'handle', $val];
        }
        elsif ($assign) {
            die "Option -$main does not take an argument\n";
        }
        elsif(defined($remain) && length($remain)) {
            unshift @$args => "-$remain";
        }

        return [$opt, 'handle', 1];
    }

    return undef;
}

my %ARG_ENDS = ('--' => 1, '::' => 1);

sub _grab_opts {
    my $self = shift;
    my ($opt_fetch, $type, %config) = @_;

    croak "The opt_fetch callback is required" unless $opt_fetch;
    croak "The arg type is required"   unless $type;

    my $args = $config{args} || $self->{+ARGS} or confess "The 'args' attribute has not yet been set";

    my $lookup = $self->_build_lookup($self->$opt_fetch());

    my (@keep_args, @opts);
    while (@$args) {
        my $arg = shift @$args;

        if ($ARG_ENDS{$arg}) {
            push @keep_args => $arg;
            last;
        }

        if (substr($arg, 0, 1) eq '-') {
            my $handler = (substr($arg, 1, 1) eq '-') ? '_handle_long_option' : '_handle_short_option';
            if(my $opt_set = $self->$handler($arg, $lookup, $args)) {
                my ($opt, $action, @val) = @$opt_set;

                if (my $pre = $opt->pre_process) {
                    $pre->(
                        opt          => $opt,
                        options      => $self,
                        action       => $action,
                        type         => $type,

                        @val ? (val => $val[0]) : (),
                    );
                }

                $lookup = $self->_build_lookup($self->$opt_fetch())
                    if $opt->adds_options;

                push @opts => $opt_set;
                next;
            }
            elsif (!$config{passthrough}) {
                my $err = "Invalid $type option: $arg";
                my $handled = $self->{+COMMAND_CLASS} && $self->{+COMMAND_CLASS}->handle_invalid_option($type, $arg, $err);
                die "$err\n" unless $handled;
            }
        }

        if ($config{die_at_non_opt}) {
            my $err = "Invalid $type option: $arg";
            my $handled = $self->{+COMMAND_CLASS} && $self->{+COMMAND_CLASS}->handle_invalid_option($type, $arg, $err);
            die "$err\n" unless $handled;
        }

        push @keep_args => $arg;

        last if $config{stop_at_non_opt};
    }

    unshift @$args => @keep_args;

    return @opts;
}

sub _build_lookup {
    my $self = shift;
    my ($opts) = @_;

    my $lookup = {long => {}, short => {}};

    my %seen;
    for my $opt (@$opts) {
        next if $seen{$opt}++;

        for my $long ($opt->long_args) {
            $lookup->{long}->{$long} //= $opt;
        }

        my $short = $opt->short or next;
        $lookup->{short}->{$short} //= $opt;
    }

    return $lookup;
}

sub _post {
    my $self = shift;
    my ($weight, $applicable, $cb) = @_;

    $self->{+POST_LIST_SORTED} = 0;

    $weight //= 0;

    push @{$self->{+POST_LIST} //= []} => [$weight, $applicable, $cb];
}

sub _option {
    my $self = shift;
    my ($trace, @spec) = @_;

    my %proto = $self->_parse_option_args(@spec);

    my $opt = App::Yath::Option->new(
        trace => $trace,
        $self->_parse_option_caller($trace->[0], \%proto),
        %proto,
    );

    $self->include_option($opt);
}

sub include_option {
    my $self = shift;
    my ($opt) = @_;

    my $trace = $opt->trace or confess "Options must have a trace!";

    push @{$self->{+ALL}} => $opt;

    my $new = $self->_index_option($opt);
    $self->_list_option($opt) if $new;

    return $opt;
}

sub _parse_option_caller {
    my $self = shift;
    my ($caller, $proto) = @_;

    my ($from_plugin, $from_command, $from_prefix, $prefix, $is_top);

    $prefix = $proto->{prefix} if exists $proto->{prefix};
    $prefix //= $caller->option_prefix() if $caller->can('option_prefix');

    if ($caller->isa('App::Yath::Command')) {
        $from_command = $caller->name() unless $caller eq 'App::Yath::Command';
        $is_top       = 1;
    }
    elsif ($caller =~ m/App::Yath::Command::([^:]+)::.*Options(?:::.*)?$/) {
        $from_command = $1;
        $is_top       = 1;
    }
    elsif ($caller eq 'App::Yath') {
        $is_top = 1;
    }
    elsif ($caller =~ m/^(App::Yath::Plugin::([^:]+))$/) {
        $from_plugin = $1;
        $from_prefix = $2;

        unless (defined $prefix) {
            $prefix = $from_prefix;
            $prefix =~ s/::.*$//g;
        }
    }

    $prefix = lc($prefix) if $prefix;

    croak "Could not find an option prefix and option is not top-level ($proto->{title})"
        unless $is_top || defined($prefix) || defined($proto->{prefix});

    return (
        $from_plugin          ? (from_plugin  => $from_plugin)  : (),
        $from_command         ? (from_command => $from_command) : (),
        ($prefix || !$is_top) ? (prefix       => $prefix)       : (),
    );
}

sub _parse_option_args {
    my $self = shift;
    my @spec = @_;

    my %args;
    if (@spec == 1) {
        my ($title, $type) = $spec[0] =~ m/^([\w-]+)(?:=(.+))?$/ or croak "Invalid option specification: $spec[0]";
        return (title => $title, type => $type);
    }
    elsif (@spec == 2) {
        my ($title, $type) = @spec;
        return (title => $title, type => $type);
    }

    my $title = shift @spec;
    return (title => $title, @spec);
}

sub _index_option {
    my $self = shift;
    my ($opt) = @_;

    my $index = $self->{+LOOKUP};

    my $out = 0;

    for my $n ($opt->name, @{$opt->alt || []}) {
        if (my $existing = $index->{$n}) {
            next if "$existing" eq "$opt";
            croak "Option '$n' was already defined (" . $existing->trace_string . ")";
        }

        $out++;
        $index->{$n} = $opt;
    }

    if (my $short = $opt->short) {
        if (my $existing = $index->{$short}) {
            return $out if "$existing" eq "$opt";
            croak "Option '$short' was already defined (" . $existing->trace_string . ")";
        }

        $out++;
        $index->{$short} = $opt;
    }

    return $out;
}

sub _list_option {
    my $self = shift;
    my ($opt) = @_;

    return push @{$self->{+PRE_LIST}} => $opt
        if $opt->pre_command;

    push @{$self->{+CMD_LIST}} => $opt;
}

sub pre_docs {
    my $self = shift;

    return $self->_docs($self->_pre_command_options(), @_);
}

sub cmd_docs {
    my $self = shift;

    return unless $self->{+COMMAND_CLASS};

    return $self->_docs([grep { !$_->pre_command } @{$self->_command_options()}], @_);
}

my %DOC_FORMATS = (
    'cli' => [
        'cli_docs',    # Method to call on opt
        "\n",          # how to join lines
        sub { "\n$_[1]" },                        # how to render the category
        sub { $_[0] =~ s/^/  /mg; "$_[0]\n" },    # transform the value from the opt
        sub { },                                  # add this at the end
    ],
    'pod' => [
        'pod_docs',                               # Method to call on opt
        "\n\n",                                   # how to join lines
        sub { ($_[0] ? ("=back") : (), "=head$_[2] $_[1]", "=over 4") },    # how to render the category
        sub { $_[0] },                                                  # transform the value from the opt
        sub { $_[0] ? ("=back") : () },                                 # add this at the end
    ],
);

sub _docs {
    my $self = shift;
    my ($opts, $format, @args) = @_;

    $format //= "UNDEFINED";
    my $fset = $DOC_FORMATS{$format} or croak "Invalid documentation format '$format'";
    my ($fmeth, $join, $fcat, $ftrans, $fend) = @$fset;

    return unless $opts;
    return unless @$opts;

    my @opts = sort _doc_sort_ops @$opts;

    my @out;

    my $cat;
    for my $opt (@opts) {
        if (!$cat || $opt->category ne $cat) {
            push @out => $fcat->($cat, $opt->category, @args);
            $cat = $opt->category;
        }

        my $help = $opt->$fmeth();
        push @out => $ftrans->($help);
    }

    push @out => $fend->($cat);

    return join $join => @out;
}

sub _doc_sort_ops($$) {
    my ($a, $b) = @_;

    my $anc = $a->category eq 'NO CATEGORY - FIX ME';
    my $bnc = $b->category eq 'NO CATEGORY - FIX ME';

    if($anc xor $bnc) {
        return 1 if $anc;
        return -1;
    }

    my $ret = $a->category cmp $b->category;
    $ret ||= ($a->prefix || '') cmp ($b->prefix || '');
    $ret ||= $a->field cmp $b->field;
    $ret ||= $a->name cmp $b->name;

    return $ret;
}

sub clear_env {
    my $self = shift;

    for my $opt (@{$self->{+ALL}}) {
        next unless $opt->clear_env_vars;
        my $env = $opt->env_vars or next;
        for my $var (@$env) {
            $var =~ s/^!//;
            delete $ENV{$var};
        }
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options - Tools for defining and tracking yath CLI options.

=head1 DESCRIPTION

This class represents a collection of options, and holds the logic for
processing them. This package also exports sugar to help you define options.

=head1 SYNOPSIS

    package My::Options;

    use App::Yath::Options;

    # This package now has a package instance of options, which can be obtained
    # via the options() method.
    my $options = __PACKAGE__->options;

    # We can include options from other packages
    include_options(
        'Package::With::Options::A',
        'Package::With::Options::B',
        ...,
    );

    # Define an option group with some options
    option_group { %common_fields } => sub {

        # Define an option
        option foo => (
            type => 's',
            default => "FOOOOOOO",
            category => 'foo',
            description => "This is foo"
            long_examples => [' value'],
            ...
        );

        option bar => ( ... );
        ...
    };

    # Action to call right after options are parsed.
    post sub {
        my %params = @_;

        ...
    };

=head1 EXPORTS

=over 4

=item $opts = options()

=item $opts = $class->options()

This returns the options instance associated with your package.

=item include_options(@CLASSES)

This lets you include options defined in other packages.

=item option_group \%COMMON_FIELDS => sub { ... }

An option group is simply a block where all calls to C<option()> will have
common fields added automatically, this makes it easier to define multiple
options that share common fields. Common fields can be overridden inside the
option definition.

These are both equivalent:

    # Using option group
    option_group { category => 'foo', prefix => 'foo' } => sub {
        option a => (type => 'b');
        option b => (type => 's');
    };

    # Not using option group
    option a => (type => 'b', category => 'foo', prefix => 'foo');
    option b => (type => 's', category => 'foo', prefix => 'foo');

=item option TITLE => %FIELDS

Define an option. The first argument is the C<title> attribute for the new
option, all other arguments should be attribute/value pairs used to construct
the option. See L<App::Yath::Option> for the documentation of attributes.

=item post sub { ... }

=item post $weight => sub { ... }

C<post> callbacks are run after all command line arguments have been processed.
This is a place to verify the result of several options combined, sanity check,
or even add short-circuit behavior. This is how the C<--help> and
C<--show-opts> options are implemented.

If no C<$weight> is specified then C<0> is used. C<post> callbacks or sorted
based on weight with higher values being run later.

=back

=head1 OPTIONS INSTANCES

In general you should not be using the options instance directly. Options
instances are mostly an implementation detail that should be treated as a black
box. There are however a few valid reasons to interact with them directly. In
those cases there are a few public attributes/methods you can work with. This
section documents the public interface.

=head2 ATTRIBUTES

This section only lists attributes that may be useful to people working with
options instances. There are a lot of internal (to yath) attributes that are
implementation details that are not listed here. Attributes not listed here are
not intended for external use and may change at any time.

=over 4

=item $arrayref = $options->all

Arrayref containing all the L<App::Yath::Option> instances in the options
instance.

=item $settings = $options->settings

Get the L<Test2::Harness::Settings> instance.

=item $arrayref = $options->args

Get the reference to the list of command line arguments. This list is modified
as arguments are processed, there are no guarentees about what is in here at
any given stage of argument processing.

=item $class_name = $options->command_class

If yath has determined what command is being executed this will be populated
with that command class. This will be undefined if the class has not been
determined yet.

=item $arrayref = $options->used_plugins

This is a list of all plugins who's options have been used. Plugins may appear
more than once.

=item $hashref = $options->included

A hashref where every key is a package who's options have been included into
this options instance. The values are an implementation detail, do not rely on
them.

=back

=head2 METHODS

This section only lists methods that may be useful to people working with
options instances. There are a lot of internal (to yath) methods that are
implementation details that are not listed here. Methods not listed here are
not intended for external use and may change at any time.

=over 4

=item $opt = $options->option(%OPTION_ATTRIBUTES)

This will create a new option with the provided attributes and add it to the
options instance. A C<trace> attribute will be automatically set for you.

=item $options->include($options_instance)

This method lets you directly include options from a second instance into the
first.

=item $options->include_from(@CLASSES)

This lets you include options from multiple classes that have options defined.

=item $options->include_option($opt)

This lets you include a single already defined option instance.

=item $options->pre_docs($format, @args)

Get documentation for pre-command options. $format may be 'cli' or 'pod'.

=item $options->cmd_docs($format, @args)

Get documentation for command options. $format may be 'cli' or 'pod'.

=back

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
