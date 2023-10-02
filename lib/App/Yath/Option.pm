package App::Yath::Option;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp qw/confess/;

use Test2::Harness::Util::HashBase qw{
    <title
    <field <name <type <trace
    <ignore_for_build

    <prefix <short <alt

    <pre_command <from_plugin <from_command

    <pre_process
    <adds_options

    <default <normalize <action <negate <autofill
    <env_vars <clear_env_vars

    +applicable

    <builds
    <category
    <description
    <short_examples <long_examples
};

my %TYPES = (
    b => 1,
    c => 1,
    s => 1,
    m => 1,
    d => 1,
    D => 1,
    h => 1,
    H => 1,
);
sub valid_type { $TYPES{$_[-1]} }

my %LONG_TO_SHORT_TYPES = (
    bool    => 'b',
    boolean => 'b',

    count    => 'c',
    counter  => 'c',
    counting => 'c',

    scalar => 's',
    string => 's',
    number => 's',

    multi    => 'm',
    multiple => 'm',
    list     => 'm',
    array    => 'm',

    default => 'd',
    def     => 'd',

    'multi-def'        => 'D',
    'multiple-default' => 'D',
    'list-default'     => 'D',
    'array-default'    => 'D',

    'hash' => 'h',
    'hash-list' => 'H',
);
sub canon_type { $LONG_TO_SHORT_TYPES{$_[-1]} }

my %REQUIRES_ARG = (s => 1, m => 1, h => 1, H => 1);
sub requires_arg { $REQUIRES_ARG{$_[0]->{+TYPE}} }

my %ALLOWS_ARG = (d => 1, D => 1);
sub allows_arg { $ALLOWS_ARG{$_[0]->{+TYPE}} || $REQUIRES_ARG{$_[0]->{+TYPE} } }

sub init {
    my $self = shift;

    confess "You must specify 'title' or both 'field' and 'name'"
        unless $self->{+TITLE} || ($self->{+FIELD} && $self->{+NAME});

    confess "The 'prefix' attribute is required"
        unless $self->{+PREFIX};

    confess "The 'alt' attribute must be an array-ref"
        if $self->{+ALT} && ref($self->{+ALT}) ne 'ARRAY';

    if (my $title = $self->{+TITLE}) {
        $self->{+FIELD} //= $title;
        $self->{+NAME} //= ($self->{+FROM_PLUGIN} && $self->{+PREFIX}) ? "$self->{+PREFIX}-$title" : $title;
    }

    $self->{+FIELD} =~ s/-/_/g;
    $self->{+NAME}  =~ s/_/-/g;

    if (my $class = $self->{+BUILDS}) {
        confess "class '$class' does not have a '$self->{+FIELD}' method"
            unless $class->can($self->{+FIELD}) || $self->{+IGNORE_FOR_BUILD};
    }

    $self->{+TYPE} //= 'b';
    $self->{+TYPE} = $self->canon_type($self->{+TYPE}) // $self->{+TYPE} if length($self->{+TYPE}) > 1;
    confess "Invalid type '$self->{+TYPE}'" unless $self->valid_type($self->{+TYPE});

    if ($self->{+TYPE} eq 'd' || $self->{+TYPE} eq 'D') {
        $self->{+AUTOFILL} //= 1;
    }
    elsif(defined $self->{+AUTOFILL}) {
        confess "'autofill' not supported for this type ('$self->{+TYPE}')";
    }

    if (my $def = $self->{+DEFAULT}) {
        my $ref = ref($def);
        confess "'default' must be a simple scalar, or a coderef, got a '$ref'" if $ref && $ref ne 'CODE';
    }

    for my $key (NORMALIZE(), ACTION()) {
        my $val = $self->{$key} or next;
        my $ref = ref($val) || 'not a ref';
        next if $ref eq 'CODE';
        confess "'$key' must be undef, or a coderef, got '$ref'";
    }

    $self->{+TRACE}       //= [caller(1)];
    $self->{+CATEGORY}    //= 'NO CATEGORY - FIX ME';
    $self->{+DESCRIPTION} //= 'NO DESCRIPTION - FIX ME';

    for my $key (sort keys %$self) {
        confess "'$key' is not a valid option attribute"
            unless $self->can(uc($key));
    }

    return $self;
}

sub applicable {
    my $self = shift;
    my ($options) = @_;
    my $cb = $self->{+APPLICABLE} or return 1;
    return $self->$cb($options);
}

sub long_args {
    my $self = shift;

    return ($self->{+NAME}, @{$self->{+ALT} || []});
}

sub option_slot {
    my $self = shift;
    my ($settings) = @_;

    confess "A settings instance is required" unless $settings;
    return $settings->define_prefix($self->{+PREFIX})->vivify_field($self->{+FIELD});
}

sub get_default {
    my $self = shift;

    for my $var (@{$self->{+ENV_VARS} // []}) {
        my ($neg) = $var =~ s/^(!)//;
        next unless exists $ENV{$var};
        return !$ENV{$var} if $neg;
        return $ENV{$var};
    }

    if (defined $self->{+DEFAULT}) {
        my $def = $self->{+DEFAULT};

        return $self->$def() if ref($def);

        return $def;
    }

    return 0
        if $self->{+TYPE} eq 'c'
        || $self->{+TYPE} eq 'b';

    return []
        if $self->{+TYPE} eq 'm'
        || $self->{+TYPE} eq 'D';

    return {}
        if $self->{+TYPE} eq 'h'
        || $self->{+TYPE} eq 'H';

    return undef;
}

sub get_normalized {
    my $self = shift;
    my ($raw) = @_;

    return $self->{+NORMALIZE}->($raw)
        if $self->{+NORMALIZE};

    return $raw ? 1 : 0
        if $self->{+TYPE} eq 'b';

    if (lc($self->{+TYPE}) eq 'h') {
        my ($key, $val) = split /=/, $raw, 2;

        if ($self->{+TYPE} eq 'H') {
            $val //= '';
            $val = [split /,/, $val];
            return [$key, $val];
        }

        return [$key, $val // 1];
    }

    return $raw;
}

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

    my $handler = $HANDLERS{$self->{+TYPE}} //= sub { ${$_[0]} = $_[1] };

    return $self->{+ACTION}->($self->{+PREFIX}, $self->{+FIELD}, $raw, $norm, $slot, $settings, $handler, $options)
        if $self->{+ACTION};

    return $handler->($slot, $norm);
}

sub handle_negation {
    my $self = shift;
    my ($settings, $options) = @_;

    confess "A settings instance is required" unless $settings;
    confess "An options instance is required" unless $options;

    my $slot = $self->option_slot($settings);

    return $self->{+NEGATE}->($self->{+PREFIX}, $self->{+FIELD}, $slot, $settings, $options)
        if $self->{+NEGATE};

    return $$slot = 0
        if $self->{+TYPE} eq 'b'
        || $self->{+TYPE} eq 'c';

    return @{$$slot //= []} = ()
        if $self->{+TYPE} eq 'm'
        || $self->{+TYPE} eq 'D';

    return %{$$slot //= {}} = ()
        if $self->{+TYPE} eq 'h'
        || $self->{+TYPE} eq 'H';

    return $$slot = undef;
}

sub trace_string {
    my $self  = shift;
    my $trace = $self->{+TRACE} or return "[UNKNOWN]";
    return "$trace->[1] line $trace->[2]";
}

my %TYPE_LONG_ARGS = (
    b => [''],
    c => [''],
    s => [' ARG', '=ARG'],
    m => [' ARG', '=ARG'],
    d => ['[=ARG]'],
    D => ['[=ARG]'],
    h => [' KEY=VAL', '=KEY=VAL'],
    H => [' KEY=VAL1,VAL2,...', '=KEY=VAL1,VAL2,...'],
);

my %TYPE_SHORT_ARGS = (
    b => [''],
    c => [''],
    s => [' ARG', '=ARG'],
    m => [' ARG', '=ARG'],
    d => ['[=ARG]', '[ARG]'],
    D => ['[=ARG]', '[ARG]'],
    h => [' KEY=VAL', '=KEY=VAL'],
    H => [' KEY=VAL1,VAL2,...', '=KEY=VAL1,VAL2,...'],
);

my %TYPE_NOTES = (
    'c' => "Can be specified multiple times",
    'm' => "Can be specified multiple times",
    'D' => "Can be specified multiple times",
    'h' => "Can be specified multiple times",
    'H' => "Can be specified multiple times. If the same key is listed multiple times the value lists will be appended together.",
);

sub cli_docs {
    my $self = shift;

    my @forms = (map { "--$self->{+NAME}$_" } @{$self->{+LONG_EXAMPLES}  || $TYPE_LONG_ARGS{$self->{+TYPE}}});

    for my $alt (@{$self->{+ALT} || []}) {
        push @forms => (map { "--$alt$_" } @{$self->{+LONG_EXAMPLES}  || $TYPE_LONG_ARGS{$self->{+TYPE}}});
    }

    push @forms => map { "-$self->{+SHORT}$_" } @{$self->{+SHORT_EXAMPLES} || $TYPE_SHORT_ARGS{$self->{+TYPE}}}
        if $self->{+SHORT};

    push @forms => "--no-$self->{+NAME}";

    my @out;

    require App::Yath::Util;
    require Test2::Util::Term;

    my $width = Test2::Util::Term::term_size() - 20;
    $width = 80 unless $width && $width >= 80;

    push @out => App::Yath::Util::fit_to_width($width, ",  ", \@forms);

    my $desc = App::Yath::Util::fit_to_width($width, " ", $self->{+DESCRIPTION});
    $desc =~ s/^/  /gm;
    push @out => $desc;

    push @out => "\n  Can also be set with the following environment variables: " . join(", ", @{$self->{+ENV_VARS}}) if $self->{+ENV_VARS};

    push @out => "\n  Note: " . $TYPE_NOTES{$self->{+TYPE}} if $TYPE_NOTES{$self->{+TYPE}};

    return join "\n" => @out;
}

sub pod_docs {
    my $self = shift;

    my @forms = (map { "--$self->{+NAME}$_" } @{$self->{+LONG_EXAMPLES}  || $TYPE_LONG_ARGS{$self->{+TYPE}}});
    for my $alt (@{$self->{+ALT} || []}) {
        push @forms => (map { "--$alt$_" } @{$self->{+LONG_EXAMPLES}  || $TYPE_LONG_ARGS{$self->{+TYPE}}});
    }
    push @forms => map { "-$self->{+SHORT}$_" } @{$self->{+SHORT_EXAMPLES} || $TYPE_SHORT_ARGS{$self->{+TYPE}}}
        if $self->{+SHORT};
    push @forms => "--no-$self->{+NAME}";

    my @out = map { "=item $_" } @forms;

    push @out => $self->{+DESCRIPTION};

    push @out => "Can also be set with the following environment variables: " . join(", ", map { "C<$_>" } @{$self->{+ENV_VARS}}) if $self->{+ENV_VARS};

    push @out => $TYPE_NOTES{$self->{+TYPE}} if $TYPE_NOTES{$self->{+TYPE}};

    return join("\n\n" => @out) . "\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Option - Representation of a yath option.

=head1 DESCRIPTION

This class represents a single command line option for yath.

=head1 SYNOPSIS

You usually will not be creating option instances directly. Usually you will
use App::Yath::Options which provides sugar, and helps make sure options get to
the right place.

    use App::Yath::Options;

    # You can specify a single option:
    option color => (
        prefix      => 'display',
        category    => "Display Options",
        description => "Turn color on, default is true if STDOUT is a TTY.",
        default     => sub { -t STDOUT ? 1 : 0 },
    );

    # If you are specifying multiple options you can use an option_group to
    # define common parameters.
    option_group {prefix => 'display', category => "Display Options"} => sub {
        option color => (
            description => "Turn color on, default is true if STDOUT is a TTY.",
            default     => sub { -t STDOUT ? 1 : 0 },
        );

        option verbose => (
            short       => 'v',
            type        => 'c',
            description => "Be more verbose",
            default     => 0,
        );
    };

=head1 ATTRIBUTES

These can be provided at object construction, or are generated internally.

=head2 CONSTRUCTION ONLY

=over 4

=item applicable => sub { ... }

This is callback is used by the C<applicable()> method.

    option foo => (
        ...,
        applicable => sub {
            my ($opt, $options) = @_;
            ...
            return $bool;
        },
    );

=back

=head2 READ-ONLY

=head3 REQUIRED

=over 4

=item $class->new(prefix => 'my_prefix')

=item $scalar = $opt->prefix()

A prefix is required. All options have their values inserted into the settings
structure, an instance of L<Test2::Harness::Settings>. The structure is
C<< $settings->PREFIX->OPTION >>.

If you do not specify a C<name> attribute then the default name will be
C<PREFIX-TITLE>. The name is the main command line argument, so
C<--PREFIX-TITLE> is the default name.

=item $class->new(type => $type)

=item $type = $opt->type()

All options must have a type, if non is specified the default is C<'b'> aka
boolean.

Here are all the possible types, along with their aliases. You may use the type
character, or any of the aliases to specify that type.

=over 4

=item b bool boolean

True of false values, will be normalized to 0 or 1 in most cases.

=item c count counter counting

Counter, starts at 0 and then increments every time the option is used.

=item s scalar string number

Requires an argument which is treated as a scalar value. No type checking is
done by the option itself, though you can check it using C<action> or
C<normalize> callbacks which are documented under those attributes.

=item m multi multiple list array

Requires an argument which is treated as a scalar value. Can be used multiple
times. All arguments provided are appended to an array.

=item d def default

Argument is optional, scalar when provided. C<--opt=arg> to provide an
argument, C<--opt arg> will not work, C<arg> will be seen as its own item on
the command line. Can be specified without an arg C<--opt> to signify a default
argument should be used (set via the C<action> callback, not the C<default>
attribute which is a default value regardless of if the option is used.)

Real world example from the debug options (simplified for doc purposes):

    option summary => (
        type        => 'd',
        description => "Write out a summary json file, if no path is provided 'summary.json' will be used. The .json extension is added automatically if omitted.",

        long_examples => ['', '=/path/to/summary.json'],

        # New way to specify an auto-fill value for when no =VAL is provided.
        # If you do not specify this the default autofill is '1' for legacy support.
        autofill => 'VALUE',

        # Old way to autofill a value (default is 1 for auto-fill)
        # Using autofill is significantly better.
        # You can also use action for additional behavior along with autofill,
        # but the default will be your auto-fill value, not '1'.
        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;

            # $norm will be '1' if option was used without an argument, so we
            # just use the provided value when it is not 1'.
            return $$slot = $norm unless $norm eq '1';

            # $norm was 1, so this is our no-arg "default" behavior

            # Do nothing if a value is already set
            return if $$slot;

            # Set the default value of 'summary.json'
            return $$slot = 'summary.json';
        },
    );
};

=item D multi-def multiple-default list-default array-default

This is a combination of C<d> and C<m>. You can use the opt multiple times to
list multiple values, and you can call it without args to add a set of
"default" values (not to be confused with THE default attribute, which is used
even if the option never appears on the command line.)

Real world example (simplified for doc purposes):

    option dev_libs => (
        type  => 'D',
        short => 'D',
        name  => 'dev-lib',

        category    => 'Developer',
        description => 'Add paths to @INC before loading ANYTHING. This is what you use if you are developing yath or yath plugins to make sure the yath script finds the local code instead of the installed versions of the same code. You can provide an argument (-Dfoo) to provide a custom path, or you can just use -D without and arg to add lib, blib/lib and blib/arch.',

        long_examples  => ['', '=lib'],
        short_examples => ['', '=lib', 'lib'],

        # New way to specify the auto-fill values. This may be a single scalar,
        # or an arrayref.
        autofill => [ 'lib', 'blib/lib', 'blib/arch' ],

        # Old way to specify the auto-fill values.
        action => sub {
            my ($prefix, $field, $raw, $norm, $slot, $settings) = @_;

            # If no argument was provided use the 'lib', 'blib/lib', and 'blib/arch' defaults.
            # If an argument was provided, use it.
            push @{$$slot} => ($norm eq '1') ? ('lib', 'blib/lib', 'blib/arch') : ($norm);
        },
    );

=item h hash

The hash type. Each time the option is used it is to add a single key/value pair
to the hash. Use an C<=> sign to split the key and value. The option can be
used multiple times. A value is required.

    yath --opt foo=bar --opt baz=bat

=item H hash-list

Similar to the 'h' type except the key/value pair expects a comma separated
list for the value, and it will be placed under the key as an arrayef.

    yath --opt foo=a,b,c --opt bar=1,2,3

The yath command obove would produce this structure:

    {
        foo => ['a', 'b', 'c'],
        bar => ['1', '2', '3'],
    }

=back

=item $class->new(title => 'my_title')

=item $title = $opt->title()

You B<MUST> specify either a title, or BOTH a name and field. If you only
specify a title it will be used to generate the name and field.

If your title is C<'foo-bar_baz'> then your field will be C<'foo_bar_baz'> and
your name will be C<'$PREFIX-foo-bar-baz'>.

Basically title is used to generate a sane field and/or name if niether are
specified. For field all dashes are changed to underscores. The field is used
as a key in the settings: C<< $settings->prefix->field >>. For the name all
underscores are changed to dashes, if the option is provided by a plugin then
C<'prefix-'> is prepended as well. The name is used for the command line
argument C<'--name'>.

If you do not want/like the name and field generated from a title then you can
specify a name or title directly.

=item $class->new(name => 'my-name')

=item $name = $opt->name()

You B<MUST> specify either a title, or BOTH a name and field. If you only
specify a title it will be used to generate the name and field.

This name is used as your primary command line argument. If your name is C<foo>
then your command line argument is C<--foo>.

=item $class->new(field => 'my_field')

=item $field = $opt->field()

You B<MUST> specify either a title, or BOTH a name and field. If you only
specify a title it will be used to generate the name and field.

The field is used in the settings hash. If your field is C<foo> then your
settings path is C<< $setting->prefix->foo >>.

=back

=head3 OPTIONAL

=over 4

=item $class->new(action => sub ...)

=item $coderef = $opt->action()

    option foo => (
        ...,
        action => sub {
            my ($prefix, $field_name, $raw_value, $normalized_value, $slot_ref, $settings, $handler, $options) = @_;

            # If no action is specified the following is all that is normally
            # done. Having an action means this is not done, so if you want the
            # value stored you must call this or similar.
            $handler->($slot, $normalized_value);
        },
    );

=over 4

=item $prefix

The prefix for the option, specified when the option was defined.

=item $field_name

The field for the option, specified whent the option was defined.

=item $raw_value

The value/argument provided at the command line C<--foo bar> would give us
C<"bar">. This is BEFORE any processing/normalizing is done.

For options that do not take arguments, or where argumentes are optional and none are provided, this
will be '1'.

=item $normalized_value

If a normalize callback was provided this will be the result of putting the
$raw_value through the normalize callback.

=item $slot_ref

This is a scalar reference to the settings slot that holds the option value(s).

The default behavior when no action is specified is usually one of these:

    $$slot_ref = $normalized_value;
    push @{$$slot_ref} => $normalized_value;

However, to save yourself trouble you can use the C<$handler> instead (see below).

=item $settings

The L<Test2::Harness::Settings> instance.

=item $handler

A callback that "does the right thing" as far as setting the value in the
settings hash. This is what is used when you do not set an action callback.

    $handler->($slot, $normalized_value);

=item $options

The L<App::Yath::Options> instance this options belongs to. This is mainly
useful if you have an option that may add even more options (such as the
C<--plugin> option can do). Note that if you do this you should also set the
C<adds_options> attribute to true, if you do not then the options list will not
be refreshed and your new options may not show up.

=back

=item $class->new(adds_options => $bool)

=item $bool = $opt->adds_options()

If this is true then it means using this option could result in more options
being available (example: Loading a plugin).

=item $class->new(alt => ['alt1', 'alt2', ...])

=item $arrayref = $opt->alt()

Provide alternative names for the option. These are aliases that can be used to
achieve the same thing on the command line. This is mainly useful for
backcompat if an option is renamed.

=item $class->new(builds => 'My::Class')

=item $my_class = $opt->builds()

If this option is used in the construction of another object (such as the group
it belongs to is composed of options that translate 1-to-1 to fields in another
object to build) then this can be used to specify that. The ultimate effect is
that an exception will be thrown if that class does not have the correct
attribute. This is a safety net to catch errors early if field names change, or
are missing between this representation and the object being composed.

=item $class->new(category => 'My Category')

=item $category = $opt->category()

This is used to sort/display help and POD documentation for your option. If you
do not provide a category it is set to C<'NO CATEGORY - FIX ME'>. The default
value makes sure everyone knows that you do not know what you are doing :-).

=item $class->new(clear_env_vars => $bool)

=item $bool = $opt->clear_env_vars()

This option is only useful when paired with the C<env_vars> attribute.

Example:

    option foo => (
        ...
        env_vars => ['foo', 'bar', 'baz'],
        clear_env_vars => 1,
    ):

In this case you are saying option foo can be set to the value of C<$ENV{foo}>,
C<$ENV{bar}>, or C<$ENV{baz}> vars if any are defined. The C<clear_env_vars>
tell it to then delete the environment variables after they are used to set the
option. This is useful if you want to use the env var to set an option, but do
not want any tests to be able to see the env var after it is used to set the
option.

=item $class->new(default => $scalar)

=item $class->new(default => sub { return $default })

=item $scalar_or_coderef = $opt->default()

This sets a default value for the field in the settings hash, the default is
set before any command line processing is done, so if the option is never used
in the command line the default value will be there.

Be sure to use the correct default value for your type. A scalar for 's', an
arrayref for 'm', etc.

Note, for any non-scalar type you want to use a subref to define the value:

    option foo => (
        ...
        type => 'm',
        default => sub { [qw/a b c/] },
    );

=item $class->new(description => "Fe Fi Fo Fum")

=item $multiline_string = $opt->description()

Description of your option. This is used in help output and POD. If you do not
provide a value the default is C<'NO DESCRIPTION - FIX ME'>.

=item $class->new(env_vars => \@LIST)

=item $arrayref = $opt->env_vars()

If set, this should be an arrayref of environment variable names. If any of the
environment variables are defined then the settings will be updated as though
the option was provided onthe command line with that value.

Example:

    option foo => (
        prefix => 'blah',
        type => 's',
        env_vars => ['FOO', 'BAR'],
    );

Then command line:

    FOO="xxx" yath test

Should be the same as

    yath test --foo "xxx"

You can also ask to have the environment variables cleared after they are checked:

    option foo => (
        prefix => 'blah',
        type => 's',
        env_vars => ['FOO', 'BAR'],
        clear_env_vars => 1, # This tells yath to clear the env vars after they
        are used.
    );

If you would like the option set to the opposite of the envarinment variable
you can prefix it with a C<'!'> character:

    option foo =>(
        ...
        env_vars => ['!FOO'],
    );

In this case these are equivelent:

    FOO=0 yath test
    yath test --foo=1

Note that this only works when the variable is defined. If C<$ENV{FOO}> is not
defined then the variable is not used.

=item $class->new(from_command => 'App::Yath::Command::COMMAND')

=item $cmd_class = $opt->from_command()

If your option was defined for a specific command this will be set. You do not
normally set this yourself, the tools in L<App::Yath::Options> usually handle
that for you.

=item $class->new(from_plugin => 'App::Yath::Plugin::PLUGIN')

=item $plugin_class = $opt->from_plugin()

If your option was defined for a specific plugin this will be set. You do not
normally set this yourself, the tools in L<App::Yath::Options> usually handle
that for you.

=item $class->new(long_examples => [' foo', '=bar', ...])

=item $arrayref = $opt->long_examples()

Used for documentation purposes. If your option takes arguments then you can
give examples here. The examples should not include the option itself, so
C<--foo bar> would be wrong, you should just do C< bar>.

=item $class->new(negate => sub { ... })

=item $coderef = $opt->negate()

If you want a custom handler for negation C<--no-OPT> you can provide one here.

    option foo => (
        ...
        negate => sub {
            my ($prefix, $field, $slot, $settings, $options) = @_;

            ...
        },
    );

The variables are the same as those in the C<action> callback.

=item $class->new(normalize => sub { ... })

=item $coderef = $opt->normalize()

The normalize attribute holds a callback sub that takes the raw value as input
and returns the normalized form.

    option foo => (
        ...,
        normalize => sub {
            my $raw = shift;

            ...

            return $norm;
        },
    );

=item $class->new(pre_command => $bool)

=item $bool = $opt->pre_command()

Options are either command-specific, or pre-command. Pre-command options are
ones yath processes even if it has not determined what comamnd is being used.
Good examples are C<--dev-lib> and C<--plugin>.

    yath --pre-command-opt COMMAND --command-opt

Most of the time this should be false, very few options qualify as pre-command.

=item $class->new(pre_process => sub { ... })

=item $coderef = $opt->pre_process()

This is essentially a BEGIN block for options. This callback is called as soon
as the option is parsed from the command line, well before the value is
normalized and added to settings. A good use for this is if your option needs
to inject additional L<App::Yath::Option> instances into the
L<App::Yath::Options> instance.

    option foo => (
        ...

        pre_process => sub {
            my %params = @_;

            my $opt     = $params{opt};
            my $options = $params{options};
            my $action  = $params{action};
            my $type    = $params{type};
            my $val     = $params{val};

            ...;
        },
    );

Explanation of paremeters:

=over 4

=item $params{opt}

The op instance

=item $params{options}

The L<App::Yath::Options> instance.

=item $params{action}

A string, usually either "handle" or "handle_negation"

=item $params{type}

A string, usually C<"pre-command"> or C<"command ($CLASS)"> where the second
has the command package in the parentheses.

=item $params{val}

The value being set, if any. For options that do not take arguments, or in the
case of negation this key may not exist.

=back

=item $class->new(short => $single_character_string)

=item $single_character_string = $opt->short()

If you want your option to be usable as a short option (single character,
single dash C<-X>) then you can provide the character to use here. If the
option does not require an argument then it can be used along with other
no-argument short options: C<-xyz> would be equivilent to C<-x -y -z>.

There are only so many single-characters available, so options are restricted
to picking only 1.

B<Please note:> Yath reserves the right to add any single-character short
options in the main distribution, if they conflict with third party
plugins/commands then the third party must adapt and change its options. As
such it is not recommended to use any short options in third party addons.

=item $class->new(short_examples => [' foo', ...])

=item $arrayref = $opt->short_examples()

Used for documentation purposes. If your option takes arguments then you can
give examples here. The examples should not include the option itself, so
C<-f bar> would be wrong, you should just do C< bar>.

This attribute is not used if you do not provide a C<short> attribute.

=item $class->new(trace => [$package, $file, $line])

=item $arrayref = $opt->trace()

This is almost always auto-populated for you via C<caller()>. It should be an
arrayref with a package, filename and line number. This is used if there is a
conflict between parameter names and/or short options. If such a situation
arises the file/line number of all conflicting options will be reported so it
can be fixed.

=back

=head1 METHODS

=over 4

=item $bool = $opt->allows_arg()

True if arguments can be provided to the option (based on type). This does not
mean the option MUST accept arguments. 'D' type options can accept arguments,
but can also be used without arguments.

=item $bool = $opt->applicable($options)

If an option provides an applicability callback this will use it to determine
if the option is applicable given the L<App::Yath::Options> instance.

If no callback was provided then this returns true.

=item $character = $opt->canon_type($type_name)

Given a long alias for an option type this will return the single-character
canonical name. This will return undef for any unknown strings. This will not
translate single character names to themselves, so C<< $opt->canon_type('s') >>
will return undef while C<< $opt->canon_type('string') >> will return C<'s'>.

=item $val = $opt->get_default()

This will return the proper default value for the option. If a custom default
was provided it will be returned, otherwise the correct generic default for the
option type will be used.

Here is a snippet showing the defaults for types:

    # First check env vars and return any values from there
    ...
    # Then check for a custom default and use it.
    ...

    return 0
        if $self->{+TYPE} eq 'c'
        || $self->{+TYPE} eq 'b';

    return []
        if $self->{+TYPE} eq 'm'
        || $self->{+TYPE} eq 'D';

    return {}
        if $self->{+TYPE} eq 'h'
        || $self->{+TYPE} eq 'H';

    # All others get undef
    return undef;

=item $val $opt->get_normalized($raw)

This converts a raw value to a normalized one. If a custom C<normalize>
attribute was set then it will be used, otherwise it is normalized in
accordance to the type.

This is where booleans are turned into 0 or 1, hashes are split, hash-lists are
split further, etc.

=item $opt->handle($raw, $settings, $options, $list)

This method handles setting the value in $settings. You should not normally
need to call this yourself.

=item $opt->handle_negation()

This method is used to handle a negated option. You should not normally need to
call this yourself.

=item @list = $opt->long_args()

Returns the name and any aliases.

=item $ref = $opt->option_slot($settings)

Get the settings->prefix->field reference. This creates the setting field if
necessary.

=item $bool = $opt->requires_arg()

Returns true if this option requires an argument when used.

=item $string = $opt->trace_string()

return a string like C<"somefile.pm line 42"> based on where the option was
defined.

=item $bool = $opt->valid_type($character)

Check if a single character type is valid.

=back

=head2 DOCUMENTATION GENERATION

=over 4

=item $string = $opt->cli_docs()

Get the option documentation in a format that works for the C<yath help
COMMAND> command.

=item $string = $opt->pod_docs()

Get the option documentation in POD format.

    =item ....

    .. option details ...

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
