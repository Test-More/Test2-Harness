package App::Yath::Options;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;
use Test2::Harness::Util qw/mod2file/;

use App::Yath::Option();
use App::Yath::Settings();

use Test2::Harness::Util::HashBase qw{
    <all <lookup

    <pre_list <cmd_list <post_list

    <post_list_sorted

    <settings

    <args
    <command_class

    <pending_pre <pending_cmd <pending_post
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

    my $group = sub {
        my ($set, $sub) = @_;

        my $common = {@common ? (%{$common[-1]}) : (), %$set};
        push @common => $common;

        if (my $class = $common->{builds}) {
            require(mod2file($class));
        }

        my $ok  = eval { $sub->(); 1 };
        my $err = $@;

        pop @common;

        die $err unless $ok;
    };

    {
        no strict 'refs';
        *{"$caller\::options"}         = $options;
        *{"$caller\::option"}          = $option;
        *{"$caller\::option_group"}    = $group;
        *{"$caller\::include_options"} = $include;
    }

    return 1;
}

sub init {
    my $self = shift;

    $self->{+ALL}   //= [];
    $self->{+LOOKUP} //= {};

    $self->{+PRE_LIST} //= [];
    $self->{+CMD_LIST} //= [];
    $self->{+POST_LIST} //= [];

    $self->{+SETTINGS} //= App::Yath::Settings->new();

    return $self;
}

sub reset_processing {
    my $self = shift;

    $self->{+SETTINGS} = {};
    delete $self->{+ARGS};
    delete $self->{+COMMAND_CLASS};
    delete $self->{+PENDING_PRE};
    delete $self->{+PENDING_CMD};

    return;
}

sub option {
    my $self = shift;
    $self->_option([caller()], @_);
}

sub include {
    my $self = shift;
    my ($inc) = @_;

    $self->include_option($_) for @{$inc->all};

    return;
}

sub include_from {
    my $self = shift;

    for my $pkg (@_) {
        require(mod2file($pkg));

        my $options = $pkg->can('options') ? $pkg->options : undef;
        croak "$pkg' does not have any options to include" unless $options;
        $self->include($options);
    }

    return;
}

sub populate_pre_defaults {
    my $self = shift;

    for my $opt (@{$self->_pre_command_options}) {
        my @val = $opt->get_default($self->{+SETTINGS});
        next unless @val;

        my $slot = $opt->option_slot($self->{+SETTINGS});
        $$slot //= $val[0];
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
        $self->_pre_command_options(),
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

    if ($class->can('options')) {
        my $cmd_options = $class->options;
        $self->include($cmd_options) if $cmd_options;
    }

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
        $self->_command_options(),
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
        @{$self->{+POST_LIST}} = sort { $a->post_process_weight <=> $b->post_process_weight } @{$self->{+POST_LIST}};
    }

    for my $opt (@{$self->{+POST_LIST}}) {
        my $post = $opt->post_process;
        $post->(
            options  => $self,
            option   => $opt,
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

    return [@$cmd_options];
}

sub _process_opts {
    my $self = shift;
    my ($list) = @_;

    for my $opt_set (@$list) {
        my ($opt, $meth, @args) = @$opt_set;
        $opt->$meth(@args, $self->{+SETTINGS});
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
        if ($opt->takes_arg) {
            $val //= shift(@$args) // die "Option --$full requires an argument.\n";
        }
        elsif($opt->allows_arg) {
            $val //= 1;
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
        my $val = 1;
        if ($opt->allows_arg) {
            $val = $remain;

            $val //= '' if $assign;

            if ($opt->takes_arg) {
                $val //= shift(@$args) // die "Option -$main requires an argument.\n";
            }
            else {
                $val //= 1;
            }

            return [$opt, 'handle', $val];
        }
        elsif ($assign) {
            die "Option -$main does not take an argument\n";
        }
        elsif(defined($remain) && length($remain)) {
            unshift @$args => "-$remain";
        }

        return [$opt, 'handle', $val];
    }

    return undef;
}

my %ARG_ENDS = ('--' => 1, '::' => 1);

sub _grab_opts {
    my $self = shift;
    my ($opts, $type, %config) = @_;

    croak "The opts array is required" unless $opts;
    croak "The arg type is required"   unless $type;

    my $args = $config{args} || $self->{+ARGS} or confess "The 'args' attribute has not yet been set";

    my $lookup = $self->_build_lookup($opts);

    my (@keep_args, @opts);
    while (my $arg = shift @$args) {
        if ($ARG_ENDS{$arg}) {
            push @keep_args => $arg;
            last;
        }

        if (substr($arg, 0, 1) eq '-') {
            my $handler = (substr($arg, 1, 1) eq '-') ? '_handle_long_option' : '_handle_short_option';
            if(my $opt_set = $self->$handler($arg, $lookup, $args)) {
                push @opts => $opt_set;
                next;
            }
            elsif (!$config{passthrough}) {
                die "Invalid $type option: $arg\n";
            }
        }

        die "Invalid $type option: $arg" if $config{die_at_non_opt};

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

    croak "Could not find an option prefix and option is not top-level ($proto->{field})"
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

    for my $n ($opt->name, @{$opt->alt || []}) {
        if (my $existing = $index->{$n}) {
            return 0 if "$existing" eq "$opt";
            croak "Option '$n' was already defined (" . $existing->trace_string . ")";
        }

        $index->{$n} = $opt;
    }

    if (my $short = $opt->short) {
        if (my $existing = $index->{$short}) {
            return 0 if "$existing" eq "$opt";
            croak "Option '$short' was already defined (" . $existing->trace_string . ")";
        }

        $index->{$short} = $opt;
    }

    return 1;
}

sub _list_option {
    my $self = shift;
    my ($opt) = @_;

    if (my $post = $opt->post_process) {
        $self->{+POST_LIST_SORTED} = 0;
        push @{$self->{+POST_LIST} //= []} => $opt;
    }

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

    return $self->_docs($self->_command_options(), @_);
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
        sub { ($_[0] ? ("=back") : (), "=head3 $_[1]", "=over 4") },    # how to render the category
        sub { $_[0] },                                                  # transform the value from the opt
        sub { $_[0] ? ("=back") : () },                                 # add this at the end
    ],
);

sub _docs {
    my $self = shift;
    my ($opts, $format) = @_;

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
            push @out => $fcat->($cat, $opt->category);
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

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options - Tools for defining and tracking yath CLI options.

=head1 DESCRIPTION

This package exports the tools used to provide options for Yath. All exports
act on the singleton instance of L<App::Yath::Options>.

=head1 SYNOPSIS


=head1 EXPORTS


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
