use Test2::V0 -target => 'App::Yath::Option';
use Test2::Plugin::DieOnFail;

subtest init => sub {
    like(dies { $CLASS->new() }, qr/Either 'field' or 'name', or both must be provided/, "Need 'field'");

    my $one = $CLASS->new(field => 'foo');
    isa_ok($one, [$CLASS], "New instance");
    is($one->type, 'b', "Default type is 'b'");

    for my $t (qw/b c m s d D default def multi-def multiple-default list-default array-default bool boolean count counter counting scalar string number multi multiple list array/) {
        ok(my $one = $CLASS->new(field => 'foo', type => $t), "type '$t' is valid");
        is($one->type, $t, "Did not modify type") if $t =~ m/^[bcsm]$/;
    }

    for my $t (qw/a e f h hash json/) {
        like(
            dies { $CLASS->new(field => 'foo', type => $t) },
            qr/Invalid type '\Q$t\E'/,
            "type '$t' is not valid"
        );
    }

    is($CLASS->new(field => 'foo', default => 1)->default,             1,     "Can use scalar as default (number)");
    is($CLASS->new(field => 'foo', default => 'foo')->default,         'foo', "Can use scalar as default (string)");
    is($CLASS->new(field => 'foo', default => sub { 1 })->default->(), 1,     "sub as default");

    like(
        dies { $CLASS->new(field => 'foo', default => {}) },
        qr/'default' must be a simple scalar, or a coderef, got a 'HASH'/,
        "Default must not be a non-code ref",
    );

    for my $arg (qw/normalize action/) {
        $one = $CLASS->new(field => 'foo', type => 's', $arg => sub { 'yup' });
        is($one->$arg->(), 'yup', "Set coderef for $arg");

        like(
            dies { $CLASS->new(field => 'foo', type => 's', $arg => 'foo') },
            qr/'$arg' must be undef, or a coderef, got 'not a ref'/,
            "'$arg' must be a coderef, not a scalar",
        );

        like(
            dies { $CLASS->new(field => 'foo', type => 's', $arg => {}) },
            qr/'$arg' must be undef, or a coderef, got 'HASH'/,
            "'$arg' must be a coderef, not a hashref",
        );
    }

    $one = $CLASS->new(field => 'foo');
    is($one->description, "NO DESCRIPTION - FIX ME", "Default help section");
    is($one->category,    "NO CATEGORY - FIX ME",    "Default category");
    like($one->trace, [__PACKAGE__, __FILE__, T()], "Added a trace");

    $one = $CLASS->new(field => 'foo', category => 'foo', description => 'bar');
    is($one->description, 'bar', "set description");
    is($one->category,    "foo", "set category");


    $one = $CLASS->new(field => 'foo');
    is($one->name, 'foo', "Generated name, no prefix");

    $one = $CLASS->new(field => 'foo', prefix => 'xxx');
    is($one->name, 'xxx-foo', "Generated name with prefix");

    $one = $CLASS->new(name => 'foo', prefix => 'xxx');
    is($one->field, 'foo', "Generated field, prefix does not effect it");
};

subtest trace_string => sub {
    my $one = $CLASS->new(field => 'foo', trace => ['My::Pkg', 'file.pm', 123]);
    is($one->trace_string, "file.pm line 123", "Got trace line");
};

subtest long_args => sub {
    my $one = $CLASS->new(
        field => 'foo',
        short => 'f',
        alt   => [qw/bar baz bat/],
    );

    is(
        [$one->long_args],
        [qw/ foo bar baz bat /],
        "got options strings, no prefix"
    );

    $one = $CLASS->new(
        field  => 'foo',
        prefix => 'pre',
        short  => 'f',
        alt    => [qw/bar baz bat/],
    );

    is(
        [$one->long_args],
        [qw/ pre-foo bar baz bat /],
        "got options strings"
    );

    $one = $CLASS->new(field => 'foo');
    is([$one->long_args], [qw/ foo /], "got options string no prefix set");

    $one = $CLASS->new(field => 'foo', prefix => 'pre');
    is([$one->long_args], [qw/ pre-foo /], "got options string, prefix was auto-included in the generated name");
};

subtest option_slot => sub {
    my $settings = {};

    my $one = $CLASS->new(field => 'foo');
    ref_is($one->option_slot($settings), \($settings->{foo}), "options_slot returns ref into settings hash (no prefix)");

    $one = $CLASS->new(field => 'foo', prefix => 'pre');
    ref_is($one->option_slot($settings), \($settings->{pre}->{foo}), "options_slot returns ref into settings hash (with prefix)");
};

subtest get_default => sub {
    my $settings = {};

    my $one = $CLASS->new(field => 'foo', type => 's', default => 123);
    is($one->get_default($settings), 123, "Got simple scalar default");

    $one = $CLASS->new(field => 'foo', type => 's', default => 0);
    is($one->get_default($settings), 0, "Got falsy scalar default");

    $one = $CLASS->new(field => 'foo', type => 's');
    is([$one->get_default($settings)], [], "No default means empty list");

    $one = $CLASS->new(field => 'foo', type => 'd');
    is([$one->get_default($settings)], [], "No default means empty list");

    my $args;
    $one = $CLASS->new(field => 'foo', type => 's', default => sub { $args = [@_]; 'hi' });
    is($one->get_default($settings), "hi", "Got the default");
    is($args, [exact_ref($settings)], "Settings was passed into default generator");

    like(dies { $one->get_default }, qr/A settings hash is required/, "get_default needs the settings hash");

    $one = $CLASS->new(field => 'foo', type => 'b');
    is($one->get_default($settings), 0, "boolean gets a automatic default of 0");

    $one = $CLASS->new(field => 'foo', type => 'c');
    is($one->get_default($settings), 0, "counter gets a automatic default of 0");

    $one = $CLASS->new(field => 'foo', type => 'm');
    is($one->get_default($settings), [], "multi defaults to an empty list");

    $one = $CLASS->new(field => 'foo', type => 'D');
    is($one->get_default($settings), [], "D defaults to an empty list");
};

subtest get_normalized => sub {
    my $settings = {};

    for my $type (qw/s c m d D/) {
        my $one = $CLASS->new(field => 'foo', type => $type);
        is($one->get_normalized('foo'), 'foo', "No change by default for '$type'");
    }

    my $one = $CLASS->new(field => 'foo', type => 'b');
    is($one->get_normalized('foo'), 1, "boolean is normalized to 1 for truthy values");
    is($one->get_normalized(''), 0, "boolean is normalized to 0 for falsy values");

    $one = $CLASS->new(field => 'foo', type => 's', normalize => sub { "norma-$_[0]" });
    is($one->get_normalized('foo'), 'norma-foo', "Normalize callback is used when present");
};

subtest handle => sub {
    my $one;
    my $settings = {};

    $one = $CLASS->new(field => 'foo', type => 's');
    %$settings = ();
    $one->handle('foo', $settings);
    is($settings->{foo}, 'foo', "Set the value directly in the hash for string");

    $one = $CLASS->new(field => 'foo', type => 'd');
    %$settings = ();
    $one->handle('foo', $settings);
    is($settings->{foo}, 'foo', "Set the value directly in the hash for string (default)");

    $one = $CLASS->new(field => 'foo', type => 'b');
    %$settings = ();
    $one->handle('foo', $settings);
    is($settings->{foo}, 1, "Set the boolean");

    $one = $CLASS->new(field => 'foo', type => 'm');
    %$settings = ();
    $one->handle('foo', $settings);
    $one->handle('bar', $settings);
    is($settings->{foo}, ['foo', 'bar'], "Added to list for multi");

    $one = $CLASS->new(field => 'foo', type => 'D');
    %$settings = ();
    $one->handle('foo', $settings);
    $one->handle('bar', $settings);
    is($settings->{foo}, ['foo', 'bar'], "Added to list for multi-default");

    $one = $CLASS->new(field => 'foo', type => 'c');
    %$settings = ();
    $one->handle('-anything', $settings);
    is($settings->{foo}, 1, "Incremented counter");
    $one->handle(undef, $settings);
    is($settings->{foo}, 2, "Incremented counter again");

    my $args;
    $one = $CLASS->new(field => 'foo', type => 's', action => sub {$args = [@_]}, normalize => sub { "norm-$_[0]" } );
    %$settings = ();
    $one->handle('foo', $settings);
    is($settings->{foo}, undef, "Action instead of setting the value");
    is($args, [undef, 'foo', 'foo', 'norm-foo', exact_ref(\($settings->{foo})), exact_ref($settings)], "Got proper args in action");
};

subtest handle_negation => sub {
    my $one;
    my $settings = {};

    $one = $CLASS->new(field => 'foo', type => 's');
    %$settings = (foo => 'bar');
    $one->handle_negation($settings);
    is($settings->{foo}, undef, "cleared value for string");

    $one = $CLASS->new(field => 'foo', type => 'b');
    %$settings = (foo => 1);
    $one->handle_negation($settings);
    is($settings->{foo}, 0, "Unset the boolean");

    $one = $CLASS->new(field => 'foo', type => 'm');
    my $list = [qw/a b c/];
    %$settings = (foo => $list);
    $one->handle_negation($settings);
    is($settings->{foo}, [], "Cleared list for multi");
    is($settings->{foo}, exact_ref($list), "Kept original list reference");

    $one = $CLASS->new(field => 'foo', type => 'D');
    $list = [qw/a b c/];
    %$settings = (foo => $list);
    $one->handle_negation($settings);
    is($settings->{foo}, [], "Cleared list for multi-default");
    is($settings->{foo}, exact_ref($list), "Kept original list reference");

    $one = $CLASS->new(field => 'foo', type => 'c');
    %$settings = (foo => 2);
    $one->handle_negation($settings);
    is($settings->{foo}, 0, "reset counter to 0");
    $one->handle_negation($settings);
    is($settings->{foo}, 0, "Still 0 after a second reset");

    my $args;
    $one = $CLASS->new(field => 'foo', type => 's', negate => sub { $args = [@_] });
    %$settings = (foo => 1);
    $one->handle_negation($settings);
    is($settings->{foo}, 1, "negate callback instead of resetting the value");
    is($args, [undef, 'foo', exact_ref(\($settings->{foo})), exact_ref($settings)], "Got proper args in callback");
};

subtest takes_arg => sub {
    my %map = (s => T(), m => T(), b => F(), c => F(), d => F(), D => F());
    for my $type (keys %map) {
        my $res = $map{$type};

        my $one = $CLASS->new(field => 'foo', type => $type);
        is($one->takes_arg, $res, "Correct arg mapping for type $type");
    }
};

subtest allows_arg => sub {
    my %map = (s => T(), m => T(), b => F(), c => F(), d => T(), D => T());
    for my $type (keys %map) {
        my $res = $map{$type};

        my $one = $CLASS->new(field => 'foo', type => $type);
        is($one->allows_arg, $res, "Correct arg mapping for type $type");
    }
};


done_testing;

__END__

my %TYPE_LONG_ARGS = (
    b => [''],
    c => [''],
    s => [' ARG', '=ARG'],
    m => [' ARG', '=ARG'],
    d => ['[=ARG]'],
    D => ['[=ARG]'],
);

my %TYPE_SHORT_ARGS = (
    b => [''],
    c => [''],
    s => [' ARG', '=ARG'],
    m => [' ARG', '=ARG'],
    d => ['[=ARG]', '[ARG]'],
    D => ['[=ARG]', '[ARG]'],
);

my %TYPE_NOTES = (
    'c' => "Can be specified multiple times",
    'm' => "Can be specified multiple times",
    'D' => "Can be specified multiple times",
);

sub cli_help {
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

    return join("\n" => @out);
}


