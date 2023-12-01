package Getopt::Yath::Instance;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness::Util qw/mod2file fqmod/;

use Getopt::Yath::Option;
use Getopt::Yath::Settings;
use Getopt::Yath::Term qw/USE_COLOR color/;

use Test2::Harness::Util::HashBase qw{
    +options <included
    <posts
    <stops

    <class

    +dedup

    +options_map_cache +options_map_cache_key

    category_sort_map
};

sub init {
    my $self = shift;

    $self->{+OPTIONS}    //= [];    # List of option instances
    $self->{+POSTS}      //= {};    # weight => {...}
    $self->{+INCLUDED}   //= {};    # type => [$inst],

    $self->{+CATEGORY_SORT_MAP} //= {'NO CATEGORY - FIX ME' => 99999};

    $self->{+DEDUP} = {};
}

sub add_option {
    my $self = shift;
    my $option = Getopt::Yath::Option->create(trace => [caller()], @_);
    return $self->_option($option);
}

sub add_post_process {
    my $self = shift;
    return $self->_post([caller()], @_);
}

sub _post {
    my $self = shift;
    my ($caller, $weight, $applicable, $cb) = @_;

    $weight //= 0;

    return if $self->{+DEDUP}->{$cb}++;
    push @{$self->{+POSTS}->{$weight}} => {caller => $caller, weight => $weight, applicable => $applicable, callback => $cb};
}

sub include {
    my $self = shift;
    my ($other) = @_;

    return unless $other;
    return if $self->{+DEDUP}->{$other}++;

    push @{$self->included->{ref($other)} //= []} => $other;

    if (my $other_include = $other->included) {
        for my $key (keys %{$other_include}) {
            push @{$self->included->{$key}} => @{$other_include->{$key} // []};
        }
    }

    $self->_option($_) for @{$other->options};

    for my $set (values %{$other->posts}) {
        for my $post (@$set) {
            $self->_post(@{$post}{qw/caller weight applicable callback/});
        }
    }
}

sub _option {
    my $self = shift;
    my ($option) = @_;

    my $options = $self->{+OPTIONS} //= [];    # List of option instances

    return if $self->{+DEDUP}->{$option}++;
    push @{$options} => $option;
}

sub options {
    my $self = shift;
    return [grep { $_->is_applicable($self) } @{$self->{+OPTIONS}}];
}

sub option_map {
    my $self = shift;
    my ($options) = @_;

    $options //= $self->options;

    my $new_key = @$options;

    if (my $old_key = $self->{+OPTIONS_MAP_CACHE_KEY}) {
        if ($old_key != $new_key) {
            delete $self->{+OPTIONS_MAP_CACHE};
            delete $self->{+OPTIONS_MAP_CACHE_KEY};
        }

        return $self->{+OPTIONS_MAP_CACHE}
            if $self->{+OPTIONS_MAP_CACHE};
    }

    my $map = {
        custom_match => [],
        # --whatever => $option
    };

    for my $option (@$options) {
        push @{$map->{custom_match}} => $option->custom_matches
            if $option->can('custom_matches');

        for my $form (keys %{$option->forms}) {
            if (my $existing = $map->{$form}) {
                croak "Option form '$form' defined twice, first in '" . $existing->trace_string . "' and again in '" . $option->trace_string . "'" if $existing ne $option;
                next;
            }

            $map->{$form} = $option;
        }
    }

    $self->{+OPTIONS_MAP_CACHE_KEY} = $new_key;
    return $self->{+OPTIONS_MAP_CACHE} = $map;
}

sub process_args {
    my $self = shift;
    my ($args, %params) = @_;

    croak "Must provide an argv arrayref" unless $args && ref($args) eq 'ARRAY';

    my $argv = [@$args];    # Make a copy

    my $settings = $params{settings} // Getopt::Yath::Settings->new({});
    my $stops  = $params{stops} // [];
    my $groups = $params{groups} // {};
    $stops = { map { ($_ => 1) } @$stops } if $stops && ref($stops) eq 'ARRAY';

    my $options = $self->options;

    my @skip;
    my $state = {
        settings => $settings,
        skipped  => \@skip,
        remains  => $argv,
        env      => $params{env}     // {},
        cleared  => $params{cleared} // {},
        modules  => $params{modules} // {},
        stop     => undef,
    };

    for my $opt (@$options) {
        my $group = $settings->group($opt->group, 1);
        my $ref   = $group->option_ref($opt->field, 1);
        ${$ref} //= $opt->get_initial_value($settings);
        $opt->init_settings($state, $settings, $group, $ref);
    }

    my $invalid = $params{invalid_opt_callback} // sub { die "'$_[0]' is not a valid option.\n" };

    my $parse_group;
    $parse_group = sub {
        my $end = shift;

        my $group = [];
        while (@$argv) {
            my $arg = shift(@$argv);
            return $group if $arg eq $end;

            if (my $nest = $groups->{$arg}) {
                $arg = $parse_group->($nest);
            }

            push @$group => $arg;
        }

        die "Could not find end token '$end' before end of arguments.\n";
    };

    while (@$argv) {
        my $map = $self->option_map($options);
        my $base = shift @$argv;

        if (my $end = $groups->{$base}) {
            push @skip => $parse_group->($end);
            next;
        }

        if ($stops->{$base}) {
            $state->{stop} = $base;
            last;
        }

        if ($base !~ m/^-/) {
            if ($params{stop_at_non_opts}) {
                $state->{stop} = $base;
                last;
            }

            if ($params{skip_non_opts}) {
                push @skip => $base;
                next;
            }

            $invalid->($base);
        }

        my ($first, $set, $arg, $opt, $delta);

        if ($base =~ m/^(-[^-])(=?)(.*)$/) {
            my ($other, $eq);
            ($first, $set, $other) = ($1, $2, $3);

            if ($opt = $map->{$first}) {
                if ($opt->allows_shortval && ($set || $other)) {
                    $set = 1;
                    $arg = $other;
                }
                elsif ($set) {
                    $arg = $other;
                }
                else {
                    unshift @$argv => "-$other" if $other;
                }
            }
        }
        else {
            ($first, $set, $arg) = split(/(=)/, $base, 2);
            $opt = $map->{$first};
        }

        unless ($opt) {
            if (my $list = $map->{custom_match}) {
                for my $match (@$list) {
                    ($opt, $delta, $arg) = $match->($base, $state);
                    next unless $opt;
                    $set = 1;
                    last;
                }
            }
        }

        die "Use of 'arg=val' form without a value is not valid in option '$base'.\n"
            if $set && !defined($arg);

        unless ($opt) {
            if ($params{skip_invalid_opts}) {
                push @skip => $base;
                next;
            }

            if ($params{stop_at_invalid_opts}) {
                $state->{stop} = $base;
                last;
            }

            $invalid->($base);
        }

        die "Use of 'arg=val' form is not allowed in option '$base'. Arguments are not allowed for this option type.\n"
            if $set && !$opt->allows_arg;

        $delta //= $opt->forms->{$first};

        $state->{modules}->{$opt->module}++ unless $opt->no_module;

        my $group_name = $opt->group;
        my $field_name = $opt->field;
        my $group = $settings->group($group_name, 1);
        my $ref   = $group->option_ref($field_name, 1);

        if ($delta < 0) {
            $opt->clear_field($ref);
            $opt->trigger(action => 'clear', ref => $ref, val => undef, state => $state, options => $self, settings => $settings, group => $group);
            $state->{cleared}->{$group_name}->{$field_name} = 1;
            next unless $set;
        }

        delete $state->{cleared}->{$group_name}->{$field_name} if $state->{cleared}->{$group_name};

        if ($opt->requires_arg && !$set) {
            die "No argument provided to '$base'.\n" unless @$argv;
            $arg = shift(@$argv);
        }

        if ($arg) {
            if (my $end = $groups->{$arg}) {
                $arg = $parse_group->($end);
            }
        }

        if (ref($arg) && @$arg > 1 && !$opt->allows_list) {
            die "Option '$base' cannot take multiple values, got: [" . join(', ' => @$arg) . "].\n";
        }

        my @val;
        if (defined $arg) {
            @val = $opt->normalize_value(ref($arg) ? @$arg : $arg);
        }
        elsif ($opt->allows_autofill) {
            @val = $opt->get_autofill_value($settings);
        }
        else {
            @val = $opt->no_arg_value($settings);
        }

        if ($opt->mod_adds_options) {
            my ($class) = @val;
            require(mod2file($class));
            if ($class->can('options')) {
                if (my $add = $class->options) {
                    $options->include($add);
                }
            }
        }

        $opt->trigger(action => 'set', ref => $ref, val => \@val, state => $state, options => $self, settings => $settings, group => $group);
        $opt->add_value($ref, @val);
    }

    for my $opt (@$options) {
        my $group_name = $opt->group;
        my $field_name = $opt->field;
        my $group = $settings->group($group_name, 1);
        my $ref   = $group->option_ref($field_name, 1);

        # Do not set the default if the --no-OPT form was used.
        next if $state->{cleared} && $state->{cleared}->{$group_name} && $state->{cleared}->{$group_name}->{$field_name};
        next if $opt->is_populated($ref);
        $opt->add_value($ref, $opt->get_default_value($settings));
    }

    for my $weight (sort { $a <=> $b } keys %{$self->{+POSTS}}) {
        for my $set (@{$self->{+POSTS}->{$weight}}) {
            next if $set->{applicable} && !$set->{applicable}->($self);
            $set->{callback}->($self, $state);
        }
    }

    for my $opt (@$options) {
        my $group = $settings->group($opt->group, 1);
        my $ref   = $group->option_ref($opt->field, 1);

        for my $env (@{$opt->clear_env_vars // []}) {
            $state->{env}->{$env} = undef;
            delete $ENV{$env} unless $params{no_set_env};
        }

        $opt->finalize_settings($state, $settings, $group, $ref);

        next unless $opt->can_set_env;

        my $to_set = $opt->set_env_vars or next;
        next unless @$to_set;

        next unless $opt->is_populated($ref);

        for my $name (@$to_set) {
            my $env = "$name";
            $env =~ s/^(!)//;
            my $neg = $1;
            my @val = $opt->get_env_value($env => $ref) or next;
            if (@val > 1) {
                my $title = $opt->title;
                my $trace = $opt->trace // ['', 'unknown', 'n/a'];
                die "Option '$title' defined in $trace->[1] line $trace->[2] returned more than one value when get_env_value($env) was called.\n";
            }

            my $setval = $val[0];
            $setval = $setval ? 0 : 1 if $neg;

            $state->{env}->{$env} = $val[0];
            $ENV{$env} = $val[0] unless $params{no_set_env};
        }
    }

    return $state;
}

my %DOC_FORMATS = (
    'cli' => [
        'cli_docs',                                                                                         # Method to call on opt
        "\n",                                                                                               # how to join lines
        sub { USE_COLOR() ? "\n" . color('bold underline white') . $_[1] . color('reset') : "\n$_[1]" },    # how to render the category
        sub { $_[0] =~ s/^/  /mg; "$_[0]\n" },                                                              # transform the value from the opt
        sub { },                                                                                            # add this at the end
    ],
    'pod' => [
        'pod_docs',                                                                                         # Method to call on opt
        "\n\n",                                                                                             # how to join lines
        sub { ($_[0] ? ("=back") : (), "=head$_[2] $_[1]", "=over 4") },                                    # how to render the category
        sub { $_[0] },                                                                                      # transform the value from the opt
        sub { $_[0] ? ("=back\n") : () },                                                                   # add this at the end
    ],
);

sub docs {
    my $self = shift;
    my ($format, %params) = @_;

    my $opts = $self->options;

    $format //= "UNDEFINED";
    my $fset = $DOC_FORMATS{$format} or croak "Invalid documentation format '$format'";
    my ($fmeth, $join, $fcat, $ftrans, $fend) = @$fset;

    return unless $opts;
    return unless @$opts;

    my @render = @$opts;

    @render = grep { $_->category eq $params{category} } @render if $params{category};

    return "\n\n!! Invalid option category: $params{category} !!"
        unless @render;

    @render = sort { $self->_doc_sort_ops($a, $b) } @render;

    my @out;

    my $cat;
    for my $opt (@render) {
        if (!$cat || $opt->category ne $cat) {
            push @out => $fcat->($cat, $opt->category, $params{head});
            $cat = $opt->category;
        }

        my $help = $opt->$fmeth(%params);
        push @out => $ftrans->($help);
    }

    push @out => $fend->($cat);
    s/[ \t]+$//gm for @out;

    return join $join => @out;
}

sub _doc_sort_ops {
    my $self = shift;
    my ($a, $b) = @_;

    my $map = $self->{+CATEGORY_SORT_MAP};
    my $aw = $map->{$a->category} || 0;
    my $bw = $map->{$b->category} || 0;

    my $ret = $aw <=> $bw;
    $ret ||= $a->category cmp $b->category;
    $ret ||= ($a->prefix || '') cmp ($b->prefix || '');
    $ret ||= $a->name cmp $b->name;

    return $ret;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Getopt::Yath::Instance - An instance of options.

=head1 DESCRIPTION

This does the real work for L<Getopt::Yath> under the hood. It is probably
better not to use this directly.

=head1 SYNOPSIS

Do not use this directly. The user interface you should be looking at is
L<Getopt::Yath>.

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

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

