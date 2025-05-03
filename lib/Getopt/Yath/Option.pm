package Getopt::Yath::Option;
use strict;
use warnings;

use Carp qw/croak/;
our @CARP_NOT = (
    __PACKAGE__,
    'Getopt::Yath',
    'Getopt::Yath::Instance',
);

use Test2::Harness::Util qw/mod2file fqmod/;
use Getopt::Yath::Term qw/USE_COLOR color/;

our $VERSION = '2.000005';

use Test2::Harness::Util::HashBase qw{
    <title
    <field <name <short <alt <alt_no
    <allow_underscore_in_alt

    <group
    <prefix
    <trace

    <module <no_module

    <maybe

    <applicable
    <default <autofill <initialize <clear
    <default_text <autofill_text
    <normalize
    +trigger

    <allowed_values
    <allowed_values_text

    <from_env_vars
    <clear_env_vars
    <set_env_vars

    <category

    <description
    +short_examples
    +long_examples

    +forms

    <mod_adds_options

    <notes
};

sub requires_arg  { croak "'$_[0]' does not define requires_arg()" }
sub add_value     { croak "'$_[0]' does not define add_value()" }
sub is_populated  { croak "'$_[0]' does not define is_populated()" }
sub no_arg_value  { croak "'$_[0]' does not define no_arg_value()" }
sub get_env_value { croak "'$_[0]' does not define get_env_value()" }

sub can_set_env       { 0 }
sub requires_autofill { 0 }

sub allows_shortval { $_[0]->allows_arg }
sub allows_default { 0 }

sub allows_list { 0 }

sub allows_arg      { $_[0]->requires_arg }
sub allows_autofill { $_[0]->requires_autofill }

sub get_autofill_value { shift->_get___value(AUTOFILL(), @_) }
sub get_default_value  { shift->_get___value(DEFAULT(),  @_) }

sub init_settings     { }
sub finalize_settings { }

sub create {
    my $class = shift;
    my %params = @_;

    croak "create() cannot be called on an option subclass" unless $class eq __PACKAGE__;

    my $type = delete $params{type} or croak "No 'type' specified";

    my $new_class = fqmod($type, __PACKAGE__);
    local $Carp::CarpLevel = $Carp::CarpLevel = 1;
    return $new_class->new(%params);
}

sub get_initial_value {
    my $self = shift;

    my $env = $self->from_env_vars;
    for my $name (@{$env || []}) {
        my $env = "$name";
        $env =~ s/^(!)//;
        my $neg = $1;

        next unless exists $ENV{$env};
        return $ENV{$env} unless $neg;
        return $ENV{$env} ? 0 : 1;
    }

    return $self->_get___value(INITIALIZE(), @_);
}

sub get_clear_value {
    my $self = shift;

    return $self->_get___value(CLEAR(), @_);
}

sub _get___value {
    my $self = shift;
    my ($field, @args) = @_;

    return undef if $self->{+MAYBE} && $field eq INITIALIZE();

    return unless exists $self->{$field};
    my $val = $self->{$field};    # May be undef, that is fine if specified.
    return $val unless ref($val);
    croak "'$field' values must either be simple scalars (not references) or a code ref that returns the '$field' value"
        unless ref($val) eq 'CODE';
    return $self->$val(@args);
}

sub normalize_value {
    my $self = shift;
    my (@input) = @_;

    my $cb = $self->{+NORMALIZE} or return @input;
    return $cb->(@input);
}

sub trigger {
    my $self = shift;
    my $cb = $self->{+TRIGGER} or return;
    $self->$cb(@_);
}

sub clear_field {
    my $self = shift;
    my ($ref) = @_;
    return $$ref = $self->get_clear_value();
}

sub is_applicable {
    my $self = shift;
    my ($options, $settings) = @_;
    my $cb = $self->{+APPLICABLE} or return 1;
    return $self->$cb($options, $settings);
}

sub long_args {
    my $self = shift;

    return ($self->{+NAME}, @{$self->{+ALT} || []});
}

sub trace_string {
    my $self  = shift;
    my $trace = $self->{+TRACE} or return "[UNKNOWN]";
    return "$trace->[1] line $trace->[2]";
}

sub long_examples  {
    my $self = shift;
    return @{$self->{+LONG_EXAMPLES}} if $self->{+LONG_EXAMPLES};
    return @{$self->default_long_examples(@_)};
}

sub short_examples  {
    my $self = shift;
    return @{$self->{+SHORT_EXAMPLES}} if $self->{+SHORT_EXAMPLES};
    return @{$self->default_short_examples(@_)};
}

sub init {
    my $self = shift;

    croak "A trace is required"
        unless $self->{+TRACE};

    croak "You must provide either 'module' (a module name for dynamic loading) or set 'no_module'"
        unless $self->{+MODULE} || $self->{+NO_MODULE};

    croak "You must specify 'title' or both 'field' and 'name'"
        unless $self->{+TITLE} || ($self->{+FIELD} && $self->{+NAME});

    croak "The 'group' attribute is required"
        unless $self->{+GROUP};

    croak "'set_env_vars' is not supported for this option type"
        if $self->{+SET_ENV_VARS} && !$self->can_set_env;

    croak "The 'alt' attribute must be an array-ref"
        if $self->{+ALT} && ref($self->{+ALT}) ne 'ARRAY';

    croak "The 'alt_no' attribute must be an array-ref"
        if $self->{+ALT_NO} && ref($self->{+ALT_NO}) ne 'ARRAY';

    $self->{+MODULE} //= $self->{+TRACE}->[0] unless $self->{+NO_MODULE};

    if (my $title = $self->{+TITLE}) {
        $self->{+FIELD} //= $title;
        $self->{+NAME} //= $title;
    }

    $self->{+FIELD} =~ s/-/_/g;
    $self->{+NAME}  =~ s/_/-/g;

    unless ($self->allow_underscore_in_alt) {
        for my $alt (@{$self->{+ALT} // []}) {
            next unless $alt =~ m/_/;
            croak "alt option form '$alt' contains an underscore, replace it with a '-' or set 'allow_underscore_in_alt' to true";
        }
    }

    croak "'default' is not allowed (did you mean 'initialize'" . ($self->allows_autofill ? " or 'autofill'" : "") . "?)"
        if $self->{+DEFAULT} && !$self->allows_default;

    croak "'autofill' is required"    if $self->requires_autofill && !$self->{+AUTOFILL};
    croak "'autofill' is not allowed" if $self->{+AUTOFILL}       && !$self->allows_autofill;

    for my $field (DEFAULT(), AUTOFILL(), INITIALIZE()) {
        my $val = $self->{$field} or next;
        my $ref = ref($val) or next;
        croak "'$field' must be a simple scalar, or a coderef, got a '$ref'" if $ref && $ref ne 'CODE';
    }

    for my $field (NORMALIZE(), APPLICABLE(), TRIGGER()) {
        my $val = $self->{$field} or next;
        my $ref = ref($val) || 'not a ref';
        next if $ref eq 'CODE';
        croak "'$field' must be undef, or a coderef, got '$ref'";
    }

    $self->{+CATEGORY}    //= 'NO CATEGORY - FIX ME';
    $self->{+DESCRIPTION} //= 'NO DESCRIPTION - FIX ME';

    for my $key (sort keys %$self) {
        croak "'$key' is not a valid option attribute" unless $self->can(uc($key));
    }

    return $self;
}

sub check_value {
    my $self = shift;
    my ($val) = @_;

    return unless defined $val;

    $val = [$val] unless ref($val) eq 'ARRAY';

    my $av = $self->allowed_values or return;
    my $r = ref($av);

    my @bad;
    for my $v (@$val) {
        my $ok = 1;
        if ($r eq 'CODE') {
            $ok = $self->$av($v);
        }
        elsif ($r =~ /Regex/i) {
            $ok = $v =~ $av;
        }
        elsif($r eq 'ARRAY') {
            $ok = 0;
            for my $c (@$av) {
                next unless defined $c;
                no warnings;
                $ok = 1 and last if $c eq $v;
                $ok = 1 and last if 0+$c && 0+$v && $c == $v;
            }
        }
        else {
             die "Invalid value check '$av' ($r) defined at " . $self->trace_string . ".\n";
        }
        next if $ok;

        push @bad => $v;
    }

    return @bad;
}

sub forms {
    my $self = shift;
    return $self->{+FORMS} if $self->{+FORMS};

    my $forms = $self->{+FORMS} = {};

    $forms->{'-' . $self->{+SHORT}} = 1 if $self->{+SHORT};

    my $prefix = $self->prefix // '';
    $prefix .= '-' if length $prefix;

    $forms->{$_} = 1  for map { "--${prefix}$_" } @{$self->{+ALT}    // []};
    $forms->{$_} = -1 for map { "--no-${prefix}$_" } @{$self->{+ALT} // []};
    $forms->{$_} = -1 for map { "--${prefix}$_" } @{$self->{+ALT_NO} // []};

    my $name = $self->name;
    $forms->{"--${prefix}${name}"}    = 1;
    $forms->{"--no-${prefix}${name}"} = -1;

    return $forms;
}

sub _example_append {
    my $self = shift;
    my ($params, @prefixes) = @_;

    return unless $self->allows_list;

    my $groups = $params->{groups} // {};

    my @out;

    for my $prefix (@prefixes) {
        for my $group (sort keys %$groups) {
            push @out => "${prefix}${group} ARG1 ARG2 ... $groups->{$group}";
        }
    }

    return @out;
}

sub default_long_examples {
    my $self   = shift;
    my %params = @_;

    return [''] unless $self->allows_arg;

    if ($self->requires_arg) {
        return [' ARG', '=ARG', $self->_example_append(\%params, ' ', '=')];
    }

    return ['', '=ARG', $self->_example_append(\%params, '=')];
}

sub default_short_examples {
    my $self   = shift;
    my %params = @_;

    return [''] unless $self->allows_arg;

    if ($self->requires_arg) {
        return ['ARG', ' ARG', '=ARG', $self->_example_append(\%params, '', ' ', '=')] if $self->allows_shortval;
        return [' ARG', '=ARG', $self->_example_append(\%params, ' ', '=')];
    }

    return ['', 'ARG', '=ARG', $self->_example_append(\%params, '', '=')] if $self->allows_shortval;
    return ['', '=ARG', $self->_example_append(\%params, '=')];
}

sub doc_forms {
    my $self = shift;
    my %params = @_;

    my $name = $self->{+NAME};
    my $prefix = $self->{+PREFIX} ? "$self->{+PREFIX}-" : "";

    my @long_examples = $self->long_examples(%params);
    my @forms = (map { "--${prefix}${name}${_}" } @long_examples );

    for my $alt (@{$self->{+ALT} || []}) {
        push @forms => (map { "--${prefix}${alt}${_}" } @long_examples);
    }

    if (my $short = $self->{+SHORT}) {
        my @short_examples = $self->short_examples(%params);
        push @forms => map { "-${short}${_}" } @short_examples;
    }

    @forms = sort {
        $a =~ m/^(-+)/;
        my $al = length($1 // '');
        $b =~ m/^(-+)/;
        my $bl = length($1 // '');
        $al <=> $bl || length($a) <=> length($b);
    } @forms;

    my @no_forms;
    push @no_forms => "--no-${prefix}${name}";
    push @no_forms => map { "--$_" } @{$self->{+ALT_NO} // []};

    return \@forms, \@no_forms;
}

sub cli_docs {
    my $self = shift;
    my %params = @_;

    $params{color} //= USE_COLOR && -t STDOUT;

    my ($forms, $no_forms, $other_forms) = $self->doc_forms(%params);

    my @out;
    if ($params{color}) {
        @out = (
            color('underline white') . $self->{+NAME} . color('reset'),
            (map { color('green') . $_ . color('reset') } @{$forms      // []}),
            (map { color('yellow') . $_ . color('reset') } @{$no_forms  // []}),
            (map { color('cyan') . $_ . color('reset') } @{$other_forms // []}),
        );
    }
    else {
        @out = (
            "[$self->{+NAME}]",
            @{$forms       // []},
            @{$no_forms    // []},
            @{$other_forms // []},
        );
    }

    push @out => Getopt::Yath::Term::fit_to_width(" ", $self->{+DESCRIPTION}, prefix => "  ");

    push @out => "\n" . Getopt::Yath::Term::fit_to_width(" ", "Can also be set with the following environment variables: " . join(", ", @{$self->{+FROM_ENV_VARS}}),                           prefix => "  ") if $self->{+FROM_ENV_VARS};
    push @out => "\n" . Getopt::Yath::Term::fit_to_width(" ", "The following environment variables will be cleared after arguments are processed: " . join(", ", @{$self->{+CLEAR_ENV_VARS}}), prefix => "  ") if $self->{+CLEAR_ENV_VARS};
    push @out => "\n" . Getopt::Yath::Term::fit_to_width(" ", "The following environment variables will be set after arguments are processed: " . join(", ", @{$self->{+SET_ENV_VARS}}),       prefix => "  ") if $self->{+SET_ENV_VARS};

    if (my @notes = $self->notes) {
        my %seen;
        push @out => map { "\n" . Getopt::Yath::Term::fit_to_width(" ", "Note: $_", prefix => "  ") } grep { $_ && !$seen{$_}++ } @notes;
    }

    for my $field (qw/default autofill/) {
        my $t = "${field}_text";
        my $val = $self->$t || $self->$field // next;
        next if ref($val);
        push @out => "\n" . Getopt::Yath::Term::fit_to_width(" ", "$field: $val", prefix => "  ");
    }

    if (my $avt = $self->allowed_values_text) {
        push @out => "\n" . Getopt::Yath::Term::fit_to_width(" ", "Allowed Values: $avt", prefix => "  ");
    }
    elsif (my $vals = $self->allowed_values) {
        push @out => "\n" . Getopt::Yath::Term::fit_to_width(" ", "Allowed Values: " . join(", " => @$vals), prefix => "  ") if @$vals;
    }

    return join "\n" => @out;
}

sub pod_docs {
    my $self = shift;
    my %params = @_;

    my ($forms, $no_forms, $other_forms) = $self->doc_forms(%params);

    my @out = map { "=item $_" } grep { $_ } @$forms, @$no_forms, @$other_forms;

    push @out => $self->description;

    push @out => "Can also be set with the following environment variables: " . join(", ", map { "C<$_>" } @{$self->{+FROM_ENV_VARS}}) if $self->{+FROM_ENV_VARS};
    push @out => "The following environment variables will be cleared after arguments are processed: " . join(", ", map { "C<$_>" } @{$self->{+CLEAR_ENV_VARS}}) if $self->{+CLEAR_ENV_VARS};
    push @out => "The following environment variables will be set after arguments are processed: " . join(", ", map { "C<$_>" } @{$self->{+SET_ENV_VARS}}) if $self->{+SET_ENV_VARS};

    my %seen;
    push @out => map { "Note: $_" } grep { $_ && !$seen{$_}++ } $self->notes;

    return join("\n\n" => @out) . "\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Getopt::Yath::Option - Base class for options.

=head1 DESCRIPTION

This is the base class for option types used in L<Getopt::Yath>.

=head1 SYNOPSIS

To create a new type you want to start with this template:

    package Getopt::Yath::Option::MyType;
    use strict;
    use warnings;

    # Become a subclass
    use parent 'Getopt::Yath::Option';

    # Bring in some useful constants;
    use Test2::Harness::Util::HashBase;

    # Must define these:
    #######

    # True if an arg is required
    # True means you can do '--flag value'
    # Without this you must do '--flag=value' to set a value, otherwise it can
    # act like a bool or a counter and not need a value.
    sub requires_arg { ... }

    sub add_value {
        my $self = shift;
        my ($ref, $val) = @_;

        # $ref contains a scalar ref to where the value is stored
        # $val is the value being assigned to the option
        # Most types can get away with this:
        ${$ref} = $val;
    }

    sub is_populated {
        my $self = shift;
        my ($ref) = @_;

        # $$ref contains the slot where the value would be stored if it was set.
        # Most types can get away with this:
        return defined(${$ref}) ? 1 : 0;
    }

    sub no_arg_value {
        my $self = shift;

        # This only happens if you do not require an arg, and do not require an
        # autofill. Only bool nd count types currently do this.
        # This is the value that will be used in such cases.
        # If you do not meet the conditions for this to be called you can simply remove this method.
        ...;
    }

    # May want to define these, otherwise remove them from this file
    #######

    sub notes             { ... }    # Return a list of notes to include in documentation
    sub allows_arg        { ... }    # True if an arg is allowed.
    sub allows_autofill   { ... }    # True if autofill is allowed
    sub allows_default    { ... }    # True if defaults are allowed
    sub requires_autofill { ... }    # True if an auto-fill is allowed

    # Change this to true if this option type can set an environment variable
    sub can_set_env { 0 }

    # You only need this if you can set an environment variable
    get_env_value {
        my $self = shift;
        my ($envname, $ref) = @_;

        # For simple scalar values this is usually good enough
        # This should be the value to assign to environment variables that are
        # set by this option.
        return $$ref;
    }

    sub default_long_examples {
        my $self = shift;

        ...;

        return [' ARG', '=ARG'];    # If you require an argument
        return [''];                # If do not allow arguments
        return ['', '=ARG'];        # If arguments are optional
    }

    sub default_short_examples {
        my $self = shift;

        ...;

        return [' ARG', '=ARG'];    # If you require an argument
        return [''];                # If do not allow arguments
        return ['', '=ARG'];        # If arguments are optional
    }

    # Run right after the initial value for this option is set. Other options
    # may not have their initial values yet.

    sub init_settings {
        my $self = shift;
        my ($state, $settings, $group, $ref) = @_;

        ...
    }

    # Run after all the options have been set, parsed, and post-blocks have
    # been run.
    # This is run before the environment variable for this option has been set,
    # but other options may have had theirs set.
    sub finalize_settings {
        my $self = shift;
        my ($state, $settings, $group, $ref) = @_;

        ...
    }

    # Probably should not define these, but here for reference.
    # Remove these if you do not plan to override them
    # The base class implementations work for most types.
    #######

    sub clear_field        { ... }    # Used to clear the field
    sub get_autofill_value { ... }    # Used to get the autofill value
    sub get_default_value  { ... }    # Used to get the default value

    1;

=head1 EXAMPLES

See the following modules source for examples:

=over 4

=item L<Getopt::Yath::Option::Scalar>

=item L<Getopt::Yath::Option::Bool>

=item L<Getopt::Yath::Option::Count>

=item L<Getopt::Yath::Option::List>

=item L<Getopt::Yath::Option::Map>

=item L<Getopt::Yath::Option::Auto>

=item L<Getopt::Yath::Option::AutoList>

=item L<Getopt::Yath::Option::AutoMap>

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


=pod

=cut POD NEEDS AUDIT

