package Getopt::Yath;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/croak/;

use Test2::Harness::Util qw/mod2file/;

use Getopt::Yath::Instance;
use Getopt::Yath::Option;

sub import {
    my $class  = shift;
    my %params = @_;

    my $caller = caller();

    my $inst_class = $params{inst_class} // 'Getopt::Yath::Instance';

    my $instance = $inst_class->new(class => $class);
    $instance->include($class->options) if $params{inherit} && $class->can('options');

    my %export;
    my @common;
    $export{options} = sub { $instance };

    $export{option} = sub {
        my $title = shift;
        my $option = Getopt::Yath::Option->create(trace => [caller()], title => $title, @common ? (%{$common[-1]}) : (), @_);
        $instance->_option($option);
    };

    $export{include_options} = sub {
        while (my $module = shift @_) {
            my $file = mod2file($module);
            require $file unless $INC{$file};

            croak "Module '$module' does not have an 'options' method"
                unless $module->can('options');

            my $list = @_ && ref($_[0]) eq 'ARRAY' ? shift(@_) : undef;

            $instance->include($module->options, $list);
        }
    };

    $export{option_post_process} = sub {
        my $cb           = pop;
        my $weight       = shift // 0;
        my ($applicable) = @_;

        $applicable //= $common[-1]->{applicable} if @common;

        croak "You must provide a callback coderef" unless $cb && ref($cb) eq 'CODE';

        $instance->_post([caller()], $weight, $applicable, $cb);
    };

    $export{option_group} = sub {
        my ($set, $sub) = @_;

        my $common = {@common ? (%{$common[-1]}) : (), %$set};

        $common->{module} = caller unless $common->{no_module};

        push @common => $common;
        my $ok  = eval { $sub->(); 1 };
        my $err = $@;
        pop @common;

        die $err unless $ok;
    };

    $export{parse_options} = sub { $instance->process_args(@_) };

    $export{category_sort_map} = sub { $instance->set_category_sort_map(@_) };

    for my $name (keys %export) {
        no strict 'refs';
        croak "$caller already has an '$name' method"
            if defined(&{"${caller}\::${name}"});

        *{"${caller}\::${name}"} = $export{$name};
    }

    return 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Getopt::Yath - Option processing yath style.

=head1 DESCRIPTION

This is the internal getopt processor yath uses. It should work perfectly fine
outside of yath as well.

=head1 SYNOPSIS

=head2 DEFINING OPTIONS

    package My::Package;
    use Getopt::Yath;

    # Include options from other modules that use Getopt::Yath
    include_options(
        'Some::Options::Package',
        ...,
    );

    # an option group is basically a way to specify common parameters for all
    # options defined in the codeblock.
    option_group {category => 'Human readable category', group => 'settings_group'} => sub {

        # In addition to the fields specified here, all the fields from the
        # 'option_group' above are included:
        option verbose => (
            type => 'Bool',                 # This is a boolean type, it does not take an argument

            # Optional fields
            short => 'v',                   # Allow -v in addition to --verbose
            default => 0,                   # What value to use if none is specified (booleans default to 0 anyway)
            from_env_vars => ['VERBOSE'],   # If the $VERBOSE environment variable is set, this will be set to true.
            set_env_vars  => ['VERBOSE'],   # If this is set to true it will also set the $VERBOSE environment variable

            description => "This turns on verbose output",
        );

        option username => (
            type => 'Scalar',           # Scalar type, requires an argument

            # Optional
            short => 'U',               # Allow: -U Bob
            alt => ['user', 'uname'],   # Allow: --user Bob, --uname Bob
            from_env_vars => ['USER'],  # Get the value from the $USER env var if it is not provided.
            default => sub { "bob" . rand(100) }, # If none is specified, and the env var is empty, generate a default.

            description => "This sets your username",
        );

        # Other options
        ...
    };

=head2 PARSING OPTIONS

    my $parsed = parse_options(
        ['-v', '--user', 'fred', 'not_an_opt', '--', '--will-not-process'],    # Normally you might pass in \@ARGV
        skip_non_opts => 1,                                                    # Skip non-opts, that is any argument that does not start with a '-' it will just skip.
        stops         => ['--'],                                               # Stop processing
        no_set_env    => 1,                                                    # Do not actually change %ENV
        groups        => { ':{' => '}:' },                                     # Arguemnts between the :{ and }: will be captured into an arrayref, they can be used as option values, or stand-alone
    );

The C<$parsed> structure:

    $parsed = {
        'cleared' => {},                       # Options that were cleared with --no-opt
        'skipped' => ['not_an_opt'],           # Skipped non options
        'settings' => {                        # Blessed as Getopt::Yath::Settings
            'settings_group' => {              # Blessed as Getopt::Yath::Settings::Group
                'verbose'  => 1,               # The option and its value
                'username' => 'fred',          # Another option and value
            },
        },
        'stop'    => '--',                     # We stopped at '--', if there was no '--' this would be undef
        'remains' => ['--will-not-process'],   # Stuff after the '--' that we did not process
        'modules' => {'My::Package' => 2},     # Any module that provided options that were seen will be listed
        'env'     => {'VERBOSE' => 1}          # Environment variabvles that would have been set if not for 'no_set_env'
    };

=head2 GENERATING COMMAND LINE HELP OUTPUT:

    sub help {
        print options()->docs('cli');
    }

    help();

Produces:

    Human readable category
     --username ARG,  --username=ARG,  --user ARG,  --user=ARG,  --uname ARG
     --uname=ARG,  -U ARG,  -U=ARG,  --no-username
       This sets your username

       Can also be set with the following environment variables: USER

     --verbose,  -v,  --no-verbose
       This turns on verbose output

       Can also be set with the following environment variables: VERBOSE

       The following environment variables will be set after arguments are processed: VERBOSE

=head2 GENERATING POD:

    sub pod {
        print options()->docs('pod', head => 2); # The '2' specifies what heading level to use
    }

    pod();

Produces:

   =head2 Human readable category

   =over 4

   =item --username ARG

   =item --username=ARG

   =item --user ARG

   =item --user=ARG

   =item --uname ARG

   =item --uname=ARG

   =item -U ARG

   =item -U=ARG

   =item --no-username

   This sets your username

   Can also be set with the following environment variables: C<USER>


   =item --verbose

   =item -v

   =item --no-verbose

   This turns on verbose output

   Can also be set with the following environment variables: C<VERBOSE>

   The following environment variables will be set after arguments are processed: C<VERBOSE>


   =back

=head1 EXPORTS

=over 4

=item $opts = options()

This will return an L<Getopt::Yath::Instance> object. This object holds all the
defined options, and does all the real work under the hood.

=item $parsed = parse_options(\@ARGV)

=item $parsed = parse_options(\@ARGV, %PARAMS)

This processes an arrayref of command line arguments into a structure that can
be easily referenced. If there is a problem parsing, such as invalid options in
the array, exceptions will be thrown.

The C<$parsed> structure will look like this:

    $parsed = {
        'cleared' => {},                       # Options that were cleared with --no-opt
        'skipped' => ['not_an_opt'],           # Skipped non options
        'settings' => {                        # Blessed as Getopt::Yath::Settings
            'settings_group' => {              # Blessed as Getopt::Yath::Settings::Group
                'verbose'  => 1,               # The option and its value
                'username' => 'fred',          # Another option and value
            },
        },
        'stop'    => '--',                     # We stopped at '--', if there was no '--' this would be undef
        'remains' => ['--will-not-process'],   # Stuff after the '--' that we did not process
        'modules' => {'My::Package' => 2},     # Any module that provided options that were seen will be listed
        'env'     => {'VERBOSE' => 1}          # Environment variabvles that would have been set if not for 'no_set_env'
    };

Available parameters that effect parsing are:

=over 4

=item stops => \@STOP_LIST

=item stops => ['--']

This is a list of string that if encountered should stop the parsing process.
The string encountered will be put into the C<stop> field of the C<$parsed>
structure. Any unparsed arguments after the stop will be put into the
C<remains> key of the C<$parsed> structure.

This is mostly useful for supporting the C<--> option.

=item groups => \%GROUP_BORDERS

=item groups => { ':{' => '}:' }

Arguments between the specified start and end tokens will be grouped together into an arrayref.

=item stop_at_non_opts => BOOL

This will cause parsing to stop at any non-option. A non-option in this case is
any argument that does not start with a C<->.

The item stopped at will be placed in the C<stop> field of the C<$parsed>
structure with the remaining arguments placed in the C<remains> field.

=item skip_non_opts => BOOL

This will skip any non-option encountered. A non-option is any argument that
does not start with C<->. All skipped items will be placed into the C<skipped>
field of the <$parsed> structure.

=item skip_invalid_opts => BOOL

This will skip any invalid option encountered. This includes any argument that
starts with C<-> but is not a valid option. All skipped items will be placed
into the C<skipped> field of the <$parsed> structure.

=item stop_at_invalid_opts => BOOL

This will cause parsing to stop at any invalid option. This includes any
argument that starts with C<-> but is not a valid option.

The item stopped at will be placed in the C<stop> field of the C<$parsed>
structure with the remaining arguments placed in the C<remains> field.

=item no_set_env => BOOL

Set this to true to prevent any modifications to C<%ENV>.

The C<env> key of the C<$parsed> structure will contain the environment
variable changes that would have been made.

B<Note:> The env key is always included even if C<%ENV> is modified directly.

=back

=item include_options('Options::Module::A', 'Options::Module::B', ...)

This allows you to build libraries of C<Getopt::Yath> options and include them
as needed. Options from the specified libraries will be merged into the current
packages options.

=item option_group \%fields => sub { ... }

=item option_group {group => 'my_group'} => sub { option ...; ... }

Create a group of options with common parameters.

=item option TITLE => \%SPECIFICATION

=item option TITLE => (type => '+My::Type', ...)

=item option TITLE => (type => 'Getopt::Yath::Option::Type', ...)

=item option TITLE => (type => 'Type', ...)

This is used to define a single option. You must specify an option NAME and
'type', which must be a valid L<Getopt::Yath::Option> subclass.

The TILE is used to produce default values for the 'field' and 'name' fields,
both of which can be specidied directly if the automatic values ar enot
sufficient. 'field' gets the value of title with dashes replaced by
underscrores. 'name' gets the value of title with underscores replaced with
dashes.

Most of the time you can just list the type as the part after the last C<::> in
C<Getopt::Yath::Option::TYPE>. You can also specify
C<Getopt::Yath::Option::TYPE> or C<Getopt::Yath::Option::TYPE::SubType>
directly. However if you need to use a module that is not in the
C<Getopt::Yath::Option::> namespace you will need to prefix the module with a
C<+> to indicate that.

    $export{option_post_process} = sub {
        my $cb           = pop;
        my $weight       = shift // 0;
        my ($applicable) = @_;

        $applicable //= $common[-1]->{applicable} if @common;

        croak "You must provide a callback coderef" unless $cb && ref($cb) eq 'CODE';

        $instance->_post([caller()], $weight, $applicable, $cb);
    };

=back

=head1 OPTION TYPES AND SPECIFICATIONS

=head2 REQUIRED WITH NO DEFAULTS

=over 4

=item title

This is the first argument to C<option()>. It is used to build the default
values for both C<field> and C<name>.

=item type => 'TypeName'

=item type => 'Getopt::Yath::Option::TypeName'

=item type => '+My::Custom::Type'

This must be a valid L<Getopt::Yath::Option> subclass:

=item group => "group_name"

Name of the field to use in the options hash under which the option will be
listed:

C<< $parsed->{options}->{$group}->{$field_name} = $val >>

=over 4

=item Scalar

Takes a scalar value. A value is required. Can be used as C<--opt VAL> or
C<--opt=val>. C<--no-opt> can be used to clear the value.

=item Bool

Is either on or off. C<--opt> will turn it onn. C<--no-opt> will turn it off.
Default is off unless the C<default> is parameter is provided.

=item Count

Is an integer value, default is to start at C<0>. C<--opt> increments the
counter. C<--no-opt> resets the counter. C<--opt=VAL> can be used to specify a
desired count.

=item List

Can take multiple values. C<--opt VAL> appends a value to the list. C<--no-opt>
will empty the list. If a C<split_on> parameter is provided then a single use
can set multiple values. For example if C<split_on> is set to C<,> then
C<--opt foo,bar> is provided, then C<foo> and C<bar> will both be added to the
list.

=item Map

Expects all values to be C<key=value> pairs and produces a hashref.
C<--opt foo=bar> will set C<$h{foo} = 'bar'>. If a C<split_on> parameter is
provided then a single use can set multiple values. For example if C<split_on>
is set to C<,> then C<--opt foo=bar,baz=bat> is provided, then the result will
have C<$h{foo} = 'bar'; $h{baz} = 'bat'>.

=item Auto

This type has an 'autofill' value that is used if no argument is provided to
the parameter, IE C<--opt>. But can also be given a specific value using
C<--opt=val>. It B<DOES NOT> support C<--opt VAL> which will most likely result
in an exception.

=item AutoList

This is a combination of 'Auto' and 'List' types. The no-arg form C<--opt> will
add the default values(s) to the list. The C<--opt=VAL> form will add
additional values.

=item AutoMap

This is a combination of 'Auto' and 'Map' types. The no-arg form C<--opt> will
add the default key+value pairs to the hash. The C<--opt=KEY=VAL> form will add
additional values.

=back

=back

=head2 REQUIRED WITH SANE DEFAULTS

=over 4

=item field => "field_name"

Name of the field to use in the group hash for the result of parsing arguments.

C<< $parsed->{options}->{$group}->{$field_name} = $val >>

Default is to take the C<title> value and replace any dashes with underscores.

=item name => "option-name"

Primary name for the option C<--option-name>.

Default is to take the C<title> value and replace any underscores with dashes.

=item trace => [$caller, $file, $line]

This normally resolves to the place C<option()> was called. You can manually
override it with a custom value, but you should rarely ever need to.

=item category => "Human Readable documentation category"

When producing POD or command line documentation, options are put into
"categories" which should be the human readabvle version of the C<group> field.

Default is "NO CATEGORY - FIX ME".

=item description => "Explanation of what the option controls"

Document what the option controls or does.

Default is 'NO DESCRIPTION - FIX ME'.

=back

=head2 OPTIONAL

=over 4

=item short => 's'

Specify a short flag to use. This is how you provide single-dash single-letter options.

=over

=item C<-s>

If no argument is required this form is available.

=item C<-s=VAL>

If an argument is allowed this form is available

=item C<-sVAL>

If an argument is allowed, and this form is not directly disabled by the type
(Types can override C<allows_shortval()> to return false to forbid this form.
Currently L<Getopt::Yath::Option::Bool> and L<Getopt::Yath::Option::Count>
disable this form.

=item C<-sss>

So far only the L<Getopt::Yath::Option::Count> type makes use of this. It
allows you to add the flag multiple times after a single dash to increment the
count.

=back

=item alt => \@LIST

=item alt => ['alt1', 'alt2']

Specify alternate or alias names that can be used to set or toggle a field.

C<--alt1> C<--alt2 foo>

=item prefix => "a-prefix"

Specify a prefix to attach to the name, and to any alternate names. This is mainly useful when specifying an option group:

    option_group {prefix => 'foo'} => sub {
        option bar => (
            type => "Bool",
        );
    };

This would then be used as C<--foo-bar>

=item module => 'My::Module'

Specify the module the argument should be associated with. This defaults to the
caller, so usually you do not need to specify it.

This is mainly used in the case of plugins we only want to load if the option
is used.

=item no_module => BOOL

Default is 0. When this is set to true the module name is not used.

=item applicable => sub { my $options = shift; ... ? 1 : 0 }

This can be used to dynamically show/hide options. When this returns false the
option will not be available.

=item initialize => $scalar

=item initialize => sub { ... }

Initialize the value to this before any arguments are parsed. This is mainly
used so that L<Getopt::Yath::Option::Map> can start with an empty hash, and
L<Getopt::Yath::Option::List> can be initialized to an empty arrayref.

This can be a simple scalar (string or number, not a reference), or it may be a
codeblock that returns anything you want. Only 1 item should be returned, extra
values will result in undefined behavior. For a map this should return an empty
hashref, for a list it should return an empty arrayref.

=item clear => $scalar

=item clear => sub { ... }

Similar to C<initialize>, but this is used when clearing the value. For things
like 'Map' this should return a hashref, etc.

=item default => $scalar

=item default => sub { ... }

Set a default to use if no value is provided at the command line.

This can be a simple scalar (string or number, not a reference), or it may be a
codeblock that returns anything you want.

Most options will only accept a single default value.
L<Getopt::Yath::Option::Map> and L<Getopt::Yath::Option::List> support a list
of defaults for setting key/value pairs, or adding items to an array.

These are valid for anything:

    default => 'foo',
    default => 123,
    default => sub { "hi" }

This is valid for an L<Getopt::Yath::Option::Map>:

    default => sub { return ('foo' => 'bar') }

This is valid for a L<Getopt::Yath::Option::List>:

    default => sub { return (1, 2, 3, 4) }

=item autofill => $scalar

=item autofill => sub { ... }

This is used for L<Getopt::Yath::Option::Auto> and similar. This is the value
used if the command line option is provided, but no value is provided with it.

This can be a simple scalar (string or number, not a reference), or it may be a
codeblock that returns anything you want.

Most options will only accept a single autofill value.
L<Getopt::Yath::Option::Map> and L<Getopt::Yath::Option::List> support a list
of autofill data for setting key/value pairs, or adding items to an array.

These are valid for anything:

    autofill => 'foo',
    autofill => 123,
    autofill => sub { "hi" }

This is valid for an L<Getopt::Yath::Option::Map>:

    autofill => sub { return ('foo' => 'bar') }

This is valid for a L<Getopt::Yath::Option::List>:

    autofill => sub { return (1, 2, 3, 4) }

=item normalize => sub { my ($input) = @_; ...; return $output }

If you wish to normalize or transform a value then you use this hook. The sub
will get the option and the input value as its arguments. You should return the
new value to set, or the input value if it does not need to change.

=item trigger => sub { my ($opt, %params) = @_; ... }

This will be called any time the option is parsed from the command line, or
whenever the command line clears the option.

B<NOTE:> It will not run when initial, autofill, or default values are set.

The C<%params> passed into the sub look like this:

    (
        # If this trigger is called because the value is cleared via --no-OPT:
        action => 'clear',
        val    => undef,

        # If a value is set because of --opt being parsed:
        action   => 'set',
        val      => [...],
        ref      => $ref,
        state    => $state,
        options  => $self,
        settings => $settings,
        group    => $group,
    );

Note that val is always passed in as an arrayref. For simple scalar type
options this will only ever have 1 value. For list or map types it may have
multiple values, also note that for such types the trigger will only see the
newly added values in the 'val' arrayref, not the values already included,
which is important as list and map types can be built over several assignments.

=item from_env_vars => \@LIST

A list of environment variables that will be used to populate the option's
initial value. These will be checked in order, the first one that is set is the
one that will be used, others will not be checked once a value is found. This
will prevent the default value from being used, but using the option on the
command line will override it.

B<Note:> that an environment variable can be prefixed with a C<!> to indicate
the value should be boolean-inverted. This means that an option like C<quiet>
can have C<< from_env_vars => ['!VERBOSE'] >> to be set to true when the
VERBOSE env var is false. This also works when setting a variable, so you could
have C<< set_env_vars => ['!VERBOSE'] >>.

=item clear_env_vars => \@LIST

A list of enviornment variables to clear after the options are all populated.
This is useful if you want to use an env var to set an option, but want to make
sure no child proceses see the environemnt variable.

=item set_env_vars => \@LIST

A list of environment variables that will be set to the value of this option
(if it is set) when argument processing is complete.

B<Note:> This is only supported in types that have a single value, maps and
lists are not supported.

B<Note:> that an environment variable can be prefixed with a C<!> to indicate
the value should be boolean-inverted. This means that an option like C<quiet>
can have C<< from_env_vars => ['!VERBOSE'] >> to be set to true when the
VERBOSE env var is false. This also works when setting a variable, so you could
have C<< set_env_vars => ['!VERBOSE'] >>.

=item short_examples => \@LIST

=item short_examples => ['', 'ARG', '=ARG']

=item short_examples => [' ARG', '=ARG']

Override the default list of arguments when generating docs. This is used for
the short form (single dash followed by a single letter and then a value
C<-Ilib>, C<-I lib>, C<-I=lib>, C<-v>, C<-vv>, C<-vvv...>) documentation.

=item long_examples => \@LIST

=item long_examples => ['', '=ARG']

=item long_examples => [' ARG', '=ARG']

Override the default list of arguments when generating docs. This is used for
the long form (double-dash and option name and then a value C<--include>,
C<--include=lib>, C<--include lib>) documentation.

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

