package App::Yath::Option;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/confess/;

use Test2::Harness::Util::HashBase qw{
    <title
    <field <name <type <trace

    <prefix <short <alt

    <pre_command <from_plugin <from_command

    <default <normalize <action <negate

    <post_process <post_process_weight

    <builds
    <category
    <description
    <short_examples <long_examples

    <meta
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

my %TAKES_ARG = (s => 1, m => 1, h => 1, H => 1);
sub takes_arg { $TAKES_ARG{$_[0]->{+TYPE}} }

my %ALLOWS_ARG = (d => 1, D => 1);
sub allows_arg { $ALLOWS_ARG{$_[0]->{+TYPE}} || $TAKES_ARG{$_[0]->{+TYPE} } }

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
            unless $class->can($self->{+FIELD});
    }

    $self->{+TYPE} //= 'b';
    $self->{+TYPE} = $LONG_TO_SHORT_TYPES{$self->{+TYPE}} // $self->{+TYPE} if length($self->{+TYPE}) > 1;
    confess "Invalid type '$self->{+TYPE}'" unless $TYPES{$self->{+TYPE}};

    if (my $def = $self->{+DEFAULT}) {
        my $ref = ref($def);
        confess "'default' must be a simple scalar, or a coderef, got a '$ref'" if $ref && $ref ne 'CODE';
    }

    for my $key (NORMALIZE(), ACTION(), POST_PROCESS()) {
        my $val = $self->{$key} or next;
        my $ref = ref($val) || 'not a ref';
        next if $ref eq 'CODE';
        confess "'$key' must be undef, or a coderef, got '$ref'";
    }

    $self->{+TRACE}       //= [caller(1)];
    $self->{+CATEGORY}    //= 'NO CATEGORY - FIX ME';
    $self->{+DESCRIPTION} //= 'NO DESCRIPTION - FIX ME';

    $self->{+POST_PROCESS_WEIGHT} //= 0;

    for my $key (sort keys %$self) {
        confess "'$key' is not a valid option attribute"
            unless $self->can(uc($key));
    }

    return $self;
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
    m => sub { push @{${$_[0]} //= []} => $_[1] },
    D => sub { push @{${$_[0]} //= []} => $_[1] },
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
    my ($raw, $settings) = @_;

    confess "A settings instance is required" unless $settings;

    my $slot = $self->option_slot($settings);
    my $norm = $self->get_normalized($raw);

    my $handler = $HANDLERS{$self->{+TYPE}} //= sub { ${$_[0]} = $_[1] };

    return $self->{+ACTION}->($self->{+PREFIX}, $self->{+FIELD}, $raw, $norm, $slot, $settings, $handler)
        if $self->{+ACTION};

    return $handler->($slot, $norm);
}

sub handle_negation {
    my $self = shift;
    my ($settings) = @_;

    confess "A settings instance is required" unless $settings;

    my $slot = $self->option_slot($settings);

    return $self->{+NEGATE}->($self->{+PREFIX}, $self->{+FIELD}, $slot, $settings)
        if $self->{+NEGATE};

    return $$slot = 0
        if $self->{+TYPE} eq 'b'
        || $self->{+TYPE} eq 'c';

    return @{$$slot //= []} = ()
        if $self->{+TYPE} eq 'm'
        || $self->{+TYPE} eq 'D';

    return @{$$slot //= {}} = ()
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

    push @out => "\n  Note: " . $TYPE_NOTES{$self->{+TYPE}} if $TYPE_NOTES{$self->{+TYPE}};

    return join "\n" => @out;
}

sub pod_docs {
    my $self = shift;

    my @forms = (map { "--$self->{+NAME}$_" } @{$self->{+LONG_EXAMPLES}  || $TYPE_LONG_ARGS{$self->{+TYPE}}});
    push @forms => map { "-$self->{+SHORT}$_" } @{$self->{+SHORT_EXAMPLES} || $TYPE_SHORT_ARGS{$self->{+TYPE}}}
        if $self->{+SHORT};
    push @forms => "--no-$self->{+NAME}";

    my @out = map { "=item $_" } @forms;

    push @out => $self->{+DESCRIPTION};

    push @out => $TYPE_NOTES{$self->{+TYPE}} if $TYPE_NOTES{$self->{+TYPE}};

    return join "\n\n" => @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Option - Encapsulation of a yath CLI option.

=head1 DESCRIPTION

This class is an encapsulation of a single yath CLI option.

=head1 SYNOPSIS

This library is rarely instantiated directly. See L<App::Yath::Options> for the
normal way to define these.

    my $opt = App::Yath::Option->new(...);

=head1 METHODS

=head2 ATTRIBUTES

These are accessor methods as well as construction arguments.

=head3 ATTRIBUTES THAT EFFECT COMMAND LINE FLAGS OR SETTINGS KEY

=over 4

=item $string = $opt->name()

=item App::Yath::Option->new(name => $string, ...)

This attribute is required. If this attribute is ommited but C<field> is
provided then this will be auto-populated with the value of the C<field>
attribute, but underscores will be replaced with dashes.

This attribute determines the primary command line argument name for this
option. For example a C<name> of 'foo' would result in C<--foo>. If the
C<prefix> attribute is also specified then the auto-computed name will be
compound: C<--PREFIX-foo>.

See the C<short> and C<alt> attributes if you want to provide aliases for your
option.

=item $string = $opt->field()

=item App::Yath::Option->new(field => $string, ...)

This attribute is required. If this attribute is ommited but C<name> is
provided then this will be auto-populated with the value of the C<name>
attribute, but dashes will be replaced with underscores.

This attribute specifies the hash key under which the option value will be
stored in the settings instance. B<NOTE:> if the C<prefix> attribute is also set
then the value will be stored in settings under the prefix:
C<$settings{PREFIX}{FIELD}>.

=item $string = $opt->prefix()

=item App::Yath::Option->new(prefix => $string, ...)

This attribute is optional for command-specific options, but is typically required
for all others.

The settings instance into which options are stored is a 2-level structure. There
are top-level options with no prefix which store their values directly into the
settings instance. Options with a prefix group their settings into a second level
hash under the prefix.

Example, if prefix is 'foo', and field is 'bar', then the option value is
stored in C<$settings{foo}{bar}>. The command line flag for this option would
be C<--foo-bar>.

Prefixes are primarily here to make plugins and other sets of related args
group their settings under a prefix to avoid conflicts and clutter in the main
settings instance.

B<Top level settings are typically reserved for Yath itself>, though any
command may also specify its own top-level options which can override/replace
global ones.

=item $char = $opt->short()

=item App::Yath::Option->new(short => $char, ...)

This attribute is optional.

If you want to provide a short-form C<-X> for your option then you set the
C<short> attribute at construction. Because Yath uses option bundling this
should be a single character. The prefix is ignored for this form (though it is
still used to store the value in the settings instance).

=item $arrayref = $opt->alt()

=item App::Yath::Opt->new(alt => [qw/foo bar baz/], ...)

This attribute is optional.

If you wish to provide aliases for your option you may do so here. Please note
that all aliases will have the prefix prepended to them for command line use.

    my $opt = App::Yath::Opt->new(..., alt => [qw/foo bar baz/]);

    # yath --PREFIX-foo
    # yath --PREFIX-bar
    # yath --PREFIX-baz

=back

=head3 CONTROLLING/MODIFYING THE OPTION VALUE

=over 4

=item $type = $opt->type()

=item App::Yath::Opt->new(type => 's', ...)

This attribute is optional, it defaults to 'bool'

Allowed options are:

=over 4

=item 'b' - bool

Either on or off, option takes no arguments.

Examples:

    $ yath -V
    $ yath --version

=item 'c' - counter

It is an integer that is normally 0 (unless another default is specified) that
is incremented every time the argument is seen. Example C<yath -vvv> would
result in 3.

    $ yath -vvv
    $ yath --verbose --verbose --verbose

=item 's' - scalar

Option requires an argument.

Examples:

    $ yath -n "foo"
    $ yath --name "foo"

=item 'm' - multi

Same as scalar except it can be specified multiple times and all values are
pushed onto an arrayref.

Example:

    $ yath -I lib -I t/lib -I blib

=item 'd' - default

This is a hybrid between scalar and boolean. It does not require an argument,
and thus will not slurp the next arg as its value. You can however make it
accept a value:

Say you have an option called C<--zoo> with a short flag C<-z> that is of type
'd'.

    $ yath -z foo     # 'zoo' is set to 1, 'foo' is treated as a seperate argument
    $ yath --zoo foo  # Same

    $ yath -zfoo      # 'zoo' is set to 'foo', the other characters are the value, not bundled arguments
    $ yath -z=foo     # Same
    $ yath --zoo=foo  # same

So as you can see, C<-z> and C<--zoo> normally work as booleans being set to
true if specified. However you can give them a scalar value if you use the C<=>
operator or omit a space with the short form of the option.

=item 'D' - multi-default

Same is 'd' except it is like a hybrid of a boolean and a multi-value. It can
appear more than once on the command line, and each time a value is pushed to
the array. If no argument is provided a '1' is pushed to the array, otherwise
the value is pushed.

=back

=item $scalar_or_coderef = $opt->default()

=item App::Yath::Opt->new(default => $def, ...)

You can provide a default for the setting. This attribute may be a simple
scalar (number, string, etc). Or it can be a coderef that generates a value.
You B<MUST> use a coderef if you want the default to be a hashref or an
arrayref.

    my $opt = App::Yath::Opt->new(..., default => 1);             # good
    my $opt = App::Yath::Opt->new(..., default => "hi");          # good
    my $opt = App::Yath::Opt->new(..., default => sub { [] });    # good

    my $opt = App::Yath::Opt->new(..., default => []);            # bad, will throw exception
    my $opt = App::Yath::Opt->new(..., default => {});            # bad, will throw exception

=back

=head3 CONTROLLING/MODIFYING THE OPTION VALUE

=over 4

=item $coderef = $opt->normalize()

=item App::Yath::Opt->new(normalize => sub {...}, ...)

A coderef that will take the raw value provided at the command line and
possibly transform it.

    my $opt = App::Yath::Opt->new(..., normalize => sub {
        my $raw = shift;
        $raw =~ m/(\d+)/;
        return $1;
    });

B<Note:> even default values are passed through the normaliztion sub if it is
provided.

=item $coderef = $opt->action()

=item App::Yath::Opt->new(action => sub {...}, ...)

A coderef that will be called whenever the value is changed. B<Note:> the
action is called I<INSTEAD> of assigning the value into the settings instance! If
you want an action and a value set in the hash you must do the latter yourself
inside the action coderef.

    my $opt = App::Yath::Opt->new(..., action => sub {
        my ($prefix, $field, $raw_val, $normalized_val, $slot_ref, $settings) = @_;

        ...

        # Set the value in the settings instance
        $$slot_ref = $normalized_val;
    });

This sub recieves the C<$prefix> which may be C<undef>, the C<$field>, the
original C<$raw_val>, the C<$normalized_val> which may be the same as the
C<$raw_val>, the C<$slot_ref> which is a scalar reference into the proper place
in the C<$settings> hash, which is also the final argument.

=item $coderef = $opt->negate()

=item App::Yath::Opt->new(negate => sub {...}, ...)

A coderef that will be called whenever the option is negated
(C<yath --no-OPTION>). This is called instead of the normal negation behavior
of resetting the option to an empty/false default. If you want negation to do
that you must do it yourself in your callback.

    my $opt = App::Yath::Opt->new(..., negate => sub {
        my ($prefix, $field, $slot_ref, $settings) = @_;

        ...

        # clear the value
        $$slot_ref = undef;
    });

This sub recieves the C<$prefix> which may be C<undef>, the C<$field>, the
C<$slot_ref> which is a scalar reference into the proper place in the
C<$settings> hash, which is also the final argument.

=item $coderef = $opt->post_process()

=item App::Yath::Opt->new(post_process => sub {...}, ...)

This callback is called AFTER all options have been processed.

This is an options last chance to make sure everything is good. This is also a
place to check for conflicting settings.

An example callback:

    my $cb = sub {
        my %in = @_;

        my $opt      = $in{opt};         # The option instance
        my $args     = $in{args};        # The \@args array after processing
        my $settings = $in{settings};    # The \%settings instance after processing

        # The following may be undef if no command was specified/found/used
        my $command = $in{command};      # Command

        print "My callback was called!";

        # any return value is ignored
        return;
    };

=back

=head3 ATTRIBUTES THAT SPECIFY WHERE THE OPTION IS USED

=over 4

=item my $bool = $opt->pre_command()

=item App::Yath::Opt->new(pre_command => $bool, ...)

If this is true then the option applies to yath regardless of what command is
used. These options are parsed before any command is loaded.

=item my $category = $opt->category

=item App::Yath::Opt->new(category => $category, ...)

Used by the command line help tools to sort options into headings. Second this
may be used to help command subclasses filter out options from their parent
command that do not apply to them when they import options from their parent.

=back

=head3 OPTION META-DATA

=over 4

=item $plugin = $opt->from_plugin()

=item App::Yath::Opt->new(from_plugin => $plugin, ...)

If the option was defined by a plugin then this should contain the name of the
plugin. The name is taken from the package name:
C<App::Yath::Plugin::[PLUGIN NAME]::*>

=item $command = $opt->from_command()

=item App::Yath::Opt->new(from_command => $command, ...)

If the option was defined by a command then this should contain the name of the
command. The name is taken from the package name:
C<App::Yath::Command::[COMMAND NAME]::*>

=item $caller_arrayref = $opt->trace()

=item App::Yath::Opt->new(trace => [$PACKAGE, $FILE, $LINE], ...)

This is a trace to help find where an option was defined.

=back

=head3 OPTION USAGE/HELP INFO

=over 4

=item $arrayref = $opt->examples()

=item App::Yath::Opt->new(examples => ['foo', 'bar'], ...)

If the option takes arguments you can provide examples of that here.

    --name EXAMPLE1
    --name EXAMPLE2

Generic default examples will be provided automatically based on type if you
leave this empty.

=item $string = $opt->description()

=item App::Yath::Opt->new(description => $string, ...)

Long-form human readable description of this option.

=back

=head2 OTHER METHODS

=over 4

=item $scalar_ref = $opt->option_slot(\%settings)

This returns a scalar-ref pointing to the right slot inside C<$settings>.

    $scalar_ref = \($settings->{$prefix}->{$field});

or

    $scalar_ref = \($settings->{$field});

=item $value = $opt->get_default(\%settings)

If there is no default value/generator this will return an empty list.

If there is a default value/generator this will return the value that should be
set.

This does NOT modify the C<$settings> hash, but it does pass it into the
generator.

=item $norm = $opt->get_normalized($raw)

This will return the normalized value. If no C<normalize> callback was provided
this will simply return C<$raw>. This is a convenience method so you do not
need to check for a callback.

=item $ref = $opt->handle($val, \%settings)

This sets the proper key in C<$settings> to C<$val> after applying the
C<normalize> callback if one was specified. If an C<action> callback was
specified it will be run after normalization instead of assigning the value to
the proper settings key.

=item $ref = $opt->handle_negation(\%settings)

This clears the proper key in C<$settings> OR calls the C<negate> callback if
one was provided.

Scalar options are reset to undef, boolean and counter options are reset to 0,
multi-options have their arrays cleared (but they keep the same reference, so
if something else has a reference to that array it is clear there as well).

=item $string = $opt->trace_string()

If a trace was provided during construction this will return
C<"FILENAME line LINE">.

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
