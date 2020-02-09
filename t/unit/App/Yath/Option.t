use Test2::V0 -target => 'App::Yath::Option';

use Test2::Harness::Settings;

subtest types => sub {
    ok($CLASS->valid_type($_), "'$_' is a valid type") for qw/b c s m d D h H/;
    ok(!$CLASS->valid_type('x'), "'x' is not a valid type");

    is($CLASS->canon_type($_), 'b', "Converted '$_' to 'b'") for qw/bool boolean/;
    is($CLASS->canon_type($_), 'c', "Converted '$_' to 'c'") for qw/count counter counting/;
    is($CLASS->canon_type($_), 's', "Converted '$_' to 's'") for qw/scalar string number/;
    is($CLASS->canon_type($_), 'm', "Converted '$_' to 'm'") for qw/multi multiple list array/;
    is($CLASS->canon_type($_), 'd', "Converted '$_' to 'd'") for qw/default def/;
    is($CLASS->canon_type($_), 'D', "Converted '$_' to 'D'") for qw/multi-def multiple-default list-default array-default/;
    is($CLASS->canon_type($_), 'h', "Converted '$_' to 'h'") for qw/hash/;
    is($CLASS->canon_type($_), 'H', "Converted '$_' to 'H'") for qw/hash-list/;

    for my $t (qw/s m h H/) {
        my $one = bless {type => $t}, $CLASS;
        is($one->requires_arg(), T(), "type '$t' requires an arg");
        is($one->allows_arg(), T(), "type '$t' does allow an arg");
    }

    for my $t (qw/d D/) {
        my $one = bless {type => $t}, $CLASS;
        is($one->requires_arg(), F(), "type '$t' does not require an arg");
        is($one->allows_arg(), T(), "type '$t' does allow an arg");
    }

    for my $t (qw/b c/) {
        my $one = bless {type => $t}, $CLASS;
        is($one->requires_arg(), F(), "type '$t' does not require an arg");
        is($one->allows_arg(), F(), "type '$t' does not allow an arg");
    }
};

subtest init => sub {
    like(
        dies { $CLASS->new() },
        qr/You must specify 'title' or both 'field' and 'name'/,
        "Need 'title', or 'field' and 'name'"
    );

    like(
        dies { $CLASS->new(title => 'foo') },
        qr/The 'prefix' attribute is required/,
        "prefix is required"
    );

    like(
        dies { $CLASS->new(title => 'foo', prefix => 'xxx', alt => 'xxx') },
        qr/The 'alt' attribute must be an array-ref/,
        "Alt, when present must be an arrayref"
    );

    my $one = $CLASS->new(title => 'foo-bar_baz', prefix => 'xxx');
    isa_ok($one, [$CLASS], "Instance of $CLASS");
    is($one->title, 'foo-bar_baz', "set title");
    is($one->field, 'foo_bar_baz', "field has underscores");
    is($one->name, 'foo-bar-baz', "name has dashes");
    is($one->type, 'b', "Default type is boolean");

    $one = $CLASS->new(title => 'foo-bar_baz', prefix => 'xxx', from_plugin => 1);
    is($one->title, 'foo-bar_baz', "set title");
    is($one->field, 'foo_bar_baz', "field has underscores");
    is($one->name, 'xxx-foo-bar-baz', "name has dashes, prefix is in place if it is a plugin option");
    is($one->type, 'b', "Default type is boolean");

    {
        package Foo;
        Test2::Harness::Util::HashBase->import(qw/bar/);
    }

    like(
        dies { $CLASS->new(title => 'baz', prefix => 'xxx', builds => 'Foo') },
        qr/class 'Foo' does not have a 'baz' method/,
        "If the option is supposed to build a specific class, make sure the class knows"
    );

    ok($CLASS->new(title => 'bar', prefix => 'xxx', builds => 'Foo'), "Construction is fine if build package has the right method");

    ok($CLASS->new(title => 'bar', prefix => 'xxx', type => 's'), "'s' is a valid type");
    is($CLASS->new(title => 'bar', prefix => 'xxx', type => 'scalar')->type, 's', "'scalar' is a valid type, turns into 's'");

    like(
        dies { $CLASS->new(title => 'bar', prefix => 'xxx', type => 'uhg') },
        qr/Invalid type 'uhg'/,
        "Type must be valid"
    );

    is($CLASS->new(title => 'foo', prefix => 'xxx', default => 'foo')->default, 'foo', "Simple string default is fine");
    is($CLASS->new(title => 'foo', prefix => 'xxx', default => 123)->default, 123, "Simple number default is fine");
    is($CLASS->new(title => 'foo', prefix => 'xxx', default => \&T)->default, exact_ref(\&T), "Can use a coderef for default");
    like(
        dies { $CLASS->new(title => 'foo', prefix => 'xxx', default => []) },
        qr/'default' must be a simple scalar, or a coderef, got a 'ARRAY/,
        "Cannot use a non-coderef ref as a default"
    );

    for my $attr (qw/normalize action/) {
        is($CLASS->new(title => 'foo', prefix => 'xxx', $attr => \&T)->$attr,   exact_ref(\&T), "Can set $attr to a coderef");
        is($CLASS->new(title => 'foo', prefix => 'xxx', $attr => undef)->$attr, undef,          "Can set $attr to undef");

        like(
            dies { $CLASS->new(title => 'foo', prefix => 'xxx', $attr => []) },
            qr/'$attr' must be undef, or a coderef, got 'ARRAY/,
            "Cannot use a non-coderef ref with $attr"
        );

        like(
            dies { $CLASS->new(title => 'foo', prefix => 'xxx', $attr => 1) },
            qr/'$attr' must be undef, or a coderef, got 'not a ref'/,
            "Cannot use a scalar with $attr"
        );
    }

    $one = $CLASS->new(title => 'foo', prefix => 'xxx');
    is($one->trace, array { item __PACKAGE__; item __FILE__; item __LINE__ - 1; etc; }, "Got correct trace");
    is($one->category, 'NO CATEGORY - FIX ME', "Default category");
    is($one->description, 'NO DESCRIPTION - FIX ME', "Default description");

    like(
        dies { $CLASS->new(title => 'foo', prefix => 'xxx', foo => 'bar') },
        qr/'foo' is not a valid option attribute/,
        "All construction args must be valid"
    );
};

subtest applicable => sub {
    my $options = 'foo';
    my $one = $CLASS->new(title => 'foo', prefix => 'xxx');
    is($one->applicable($options), T(), "Unless a callback was provided and option is always applicable.");

    my $args;
    $one = $CLASS->new(title => 'foo', prefix => 'xxx', applicable => sub {$args = [@_]; 0});

    is($one->applicable($options), F(), "Used value from callback");
    is($args, [exact_ref($one), $options], "Callback got the necessary args");
};

subtest long_args => sub {
    my $one = $CLASS->new(title => 'foo', prefix => 'xxx');
    is([$one->long_args], [qw/foo/], "Got long args");

    $one = $CLASS->new(title => 'foo', prefix => 'xxx', alt => [qw/a b c/]);
    is([$one->long_args], [qw/foo a b c/], "Got long args");
};

subtest option_slot => sub {
    my $one = $CLASS->new(title => 'foo', prefix => 'xxx');

    my $settings = Test2::Harness::Settings->new();

    ok(my $slot = $one->option_slot($settings), "Got the slot");
    is($$slot, undef, "slot is a reference pointing to a scalar with an undef value");
    is($settings->xxx->foo, undef, "Vivified in settings");
    $$slot = 123;
    is($settings->xxx->foo, 123, "Setting the slotref sets it in settings");

    like(
        dies { $one->option_slot() },
        qr/A settings instance is required/,
        "Need to pass in settings"
    );
};

subtest get_default => sub {
    my $new = sub { $CLASS->new(title => 'foo', prefix => 'xxx', @_) };
    is($new->(type => 's')->get_default, undef, "default for scalar is undef");
    is($new->(type => 'd')->get_default, undef, "default for 'd' is undef");
    is($new->(type => 'b')->get_default, 0,     "default for boolean is 0");
    is($new->(type => 'c')->get_default, 0,     "default for count is 0");
    is($new->(type => 'm')->get_default, [], "default for multi is an empty array");
    is($new->(type => 'D')->get_default, [], "default for multi-d is an empty array");
    is($new->(type => 'h')->get_default, {}, "default for hash is an empty hash");
    is($new->(type => 'H')->get_default, {}, "default for multi-hash is an empty hash");

    is($new->(type => 's', default => 123)->get_default, 123, "Used simple default");
    is($new->(type => 's', default => sub { 'xxx' })->get_default, 'xxx', "Used default generator");
};

subtest get_normalized => sub {
    my $new = sub { $CLASS->new(title => 'foo', prefix => 'xxx', @_) };

    is($new->(type => 'b')->get_normalized('a'), 1, "Boolean normalized to true");
    is($new->(type => 'b')->get_normalized(''),  0, "Boolean normalized to false");

    is($new->(type => 's')->get_normalized('foo'), 'foo', "Normalize does not change most things");

    is($new->(type => 'h')->get_normalized('foo=bar'), ['foo', 'bar'], "Simple hash parse/normalize");
    is($new->(type => 'h')->get_normalized('foo=bar=baz,bat'), ['foo', 'bar=baz,bat'], "Do not do anything special for 'h' values");
    is($new->(type => 'h')->get_normalized('foo'), ['foo', 1], "Value is 1 if nothing is specified");

    is($new->(type => 'H')->get_normalized('foo=bar'), ['foo', ['bar']], "Simple multi-hash parse/normalize");
    is($new->(type => 'H')->get_normalized('foo=bar=baz,bat'), ['foo', ['bar=baz', 'bat']], "Split 'H' by comma");
    is($new->(type => 'H')->get_normalized('foo'), ['foo', []], "Value is [] if nothing is specified");
};

subtest handle => sub {
    require App::Yath::Options;
    my $options = App::Yath::Options->new();
    my $new = sub { $CLASS->new(title => 'foo', prefix => 'xxx', @_), Test2::Harness::Settings->new() };

    my ($one, $settings) = $new->(type => 'c');
    $one->handle(1, $settings, $options);
    is($settings->xxx->foo, 1, "increment by 1");
    $one->handle('a', $settings, $options);
    is($settings->xxx->foo, 2, "increment by 1 again");

    ($one, $settings) = $new->(type => 'm');
    $one->handle('a', $settings, $options);
    is($settings->xxx->foo, ['a'], "Pushed value");
    $one->handle('b', $settings, $options);
    is($settings->xxx->foo, ['a', 'b'], "Pushed value again");

    ($one, $settings) = $new->(type => 'D');
    $one->handle('a', $settings, $options);
    is($settings->xxx->foo, ['a'], "Pushed value");
    $one->handle('b', $settings, $options);
    is($settings->xxx->foo, ['a', 'b'], "Pushed value again");

    ($one, $settings) = $new->(type => 'h');
    $one->handle('foo=bar', $settings, $options);
    is($settings->xxx->foo, {'@' => ['foo'], foo => 'bar'}, "Set value and added it to the list key");
    $one->handle('foo=baz', $settings, $options);
    is($settings->xxx->foo, {'@' => ['foo'], foo => 'baz'}, "Reset value, not duplicated in the list key");
    $one->handle('fog=baz', $settings, $options);
    is($settings->xxx->foo, {'@' => ['foo', 'fog'], foo => 'baz', fog => 'baz'}, "Set second key");

    ($one, $settings) = $new->(type => 'H');
    $one->handle('foo=bar', $settings, $options);
    is($settings->xxx->foo, {'@' => ['foo'], foo => ['bar']}, "Set value and added it to the list key");
    $one->handle('foo=baz,bat', $settings, $options);
    is($settings->xxx->foo, {'@' => ['foo'], foo => ['bar', 'baz', 'bat']}, "Added more values");
    $one->handle('fog', $settings, $options);
    is($settings->xxx->foo, {'@' => ['foo', 'fog'], foo => ['bar', 'baz', 'bat'], fog => []}, "Set second key");

    my $args;
    ($one, $settings) = $new->(type => 'H', action => sub {
        my ($prefix, $field, $raw, $norm, $slot, $settings, $handler) = @_;
        $args = [@_];
        $handler->($slot, $norm);
        return 'xxx';
    });

    is($one->handle('foo=baz,bat', $settings, $options), 'xxx', "Returned value from action");
    is($settings->xxx->foo, {'@' => ['foo'], foo => ['baz', 'bat']}, "Set value via handler");
    is(
        $args,
        [
            $one->prefix,
            $one->field,
            "foo=baz,bat",
            [foo => ['baz', 'bat']],
            exact_ref($one->option_slot($settings)),
            exact_ref($settings),
            meta { prop reftype => 'CODE' },
            exact_ref($options),
        ],
        "Got args"
    );
};

subtest handle_negation => sub {
    require App::Yath::Options;
    my $options = App::Yath::Options->new();
    my $new = sub { $CLASS->new(title => 'foo', prefix => 'xxx', @_), Test2::Harness::Settings->new() };

    for my $type (qw/b c/) {
        my ($one, $settings) = $new->(type => $type);
        $one->handle(1, $settings, $options);
        is($settings->xxx->foo, 1, "'$type' Is set");
        $one->handle_negation($settings, $options);
        is($settings->xxx->foo, 0, "'$type' Cleared");
    }

    for my $type (qw/m D/) {
        my ($one, $settings) = $new->(type => $type);
        $one->handle('abc', $settings, $options);
        is($settings->xxx->foo, ['abc'], "'$type' Is set");
        $one->handle_negation($settings, $options);
        is($settings->xxx->foo, [], "'$type' Cleared");
    }

    for my $type (qw/h H/) {
        my ($one, $settings) = $new->(type => $type);
        $one->handle('abc', $settings, $options);
        is($settings->xxx->foo, {'@' => ['abc'], abc => T()}, "'$type' Is set");
        $one->handle_negation($settings, $options);
        is($settings->xxx->foo, {}, "'$type' Cleared");
    }

    my ($one, $settings) = $new->(type => 's');
    $one->handle('abc', $settings, $options);
    is($settings->xxx->foo, 'abc', "'s' Is set");
    $one->handle_negation($settings, $options);
    is($settings->xxx->foo, undef, "'s' Cleared");
};

subtest trace_string => sub {
    my $one = $CLASS->new(prefix => 'xxx', title => 'foo', trace => ['Foo', 'foo.pm', 42]);
    is($one->trace_string(), "foo.pm line 42", "Valid trace string");
};

subtest cli_docs => sub {
    my $one = $CLASS->new(
        type => 'b',
        prefix => 'xxx',
        title => 'foo',
        short => 'F',
        description => 'This is foo bar baz bat gsdgdsgfsdd',
    );

    require Test2::Util::Term;
    my $c = mock 'Test2::Util::Term' => (
        override => [term_size => sub { 10 }], # Default to super small to make sure we do something sane
    );

    is($one->cli_docs, "--foo,  -F,  --no-foo\n  This is foo bar baz bat gsdgdsgfsdd", "Got docs");

    $one = $CLASS->new(
        type => 'H',
        prefix => 'xxx',
        title => 'foo',
        short => 'F',
        description => 'This is foo bar baz bat gsdgdsgfsdd',
    );

    chomp(my $res = <<'    EOT');
--foo KEY=VAL1,VAL2,...,  --foo=KEY=VAL1,VAL2,...,  -F KEY=VAL1,VAL2,...
-F=KEY=VAL1,VAL2,...,  --no-foo
  This is foo bar baz bat gsdgdsgfsdd

  Note: Can be specified multiple times. If the same key is listed multiple times the value lists will be appended together.
    EOT

    is($one->cli_docs, $res, "Got more complex docs");

    $one = $CLASS->new(
        type => 'H',
        prefix => 'xxx',
        title => 'foo',
        alt => ['bar', 'baz'],
        short => 'F',
        description => 'This is foo bar baz bat gsdgdsgfsdd',
        long_examples => [' KEY=VALX,VALY,...', '=KEY=VALX,VALY,...'],
        short_examples => [' KEY=VALX,VALY,...', '=KEY=VALX,VALY,...'],
    );

    chomp($res = <<'    EOT');
--foo KEY=VALX,VALY,...,  --foo=KEY=VALX,VALY,...,  --bar KEY=VALX,VALY,...
--bar=KEY=VALX,VALY,...,  --baz KEY=VALX,VALY,...,  --baz=KEY=VALX,VALY,...
-F KEY=VALX,VALY,...,  -F=KEY=VALX,VALY,...,  --no-foo
  This is foo bar baz bat gsdgdsgfsdd

  Note: Can be specified multiple times. If the same key is listed multiple times the value lists will be appended together.
    EOT

    is($one->cli_docs, $res, "Got more complex docs with custom examples");
};

subtest pod_docs => sub {
    my $one = $CLASS->new(
        type => 'b',
        prefix => 'xxx',
        title => 'foo',
        short => 'F',
        description => 'This is foo bar baz bat gsdgdsgfsdd',
    );

    require Test2::Util::Term;
    my $c = mock 'Test2::Util::Term' => (
        override => [term_size => sub { 10 }], # Default to super small to make sure we do something sane
    );

    is($one->pod_docs, <<'    EOT', "Got docs");
=item --foo

=item -F

=item --no-foo

This is foo bar baz bat gsdgdsgfsdd
    EOT

    $one = $CLASS->new(
        type => 'H',
        prefix => 'xxx',
        title => 'foo',
        short => 'F',
        description => 'This is foo bar baz bat gsdgdsgfsdd',
    );

    is($one->pod_docs, <<'    EOT', "Got more complex docs");
=item --foo KEY=VAL1,VAL2,...

=item --foo=KEY=VAL1,VAL2,...

=item -F KEY=VAL1,VAL2,...

=item -F=KEY=VAL1,VAL2,...

=item --no-foo

This is foo bar baz bat gsdgdsgfsdd

Can be specified multiple times. If the same key is listed multiple times the value lists will be appended together.
    EOT

    $one = $CLASS->new(
        type => 'H',
        prefix => 'xxx',
        title => 'foo',
        alt => ['bar', 'baz'],
        short => 'F',
        description => 'This is foo bar baz bat gsdgdsgfsdd',
        long_examples => [' KEY=VALX,VALY,...', '=KEY=VALX,VALY,...'],
        short_examples => [' KEY=VALX,VALY,...', '=KEY=VALX,VALY,...'],
    );

    is($one->pod_docs, <<'    EOT', "Got more complex docs with custom examples");
=item --foo KEY=VALX,VALY,...

=item --foo=KEY=VALX,VALY,...

=item --bar KEY=VALX,VALY,...

=item --bar=KEY=VALX,VALY,...

=item --baz KEY=VALX,VALY,...

=item --baz=KEY=VALX,VALY,...

=item -F KEY=VALX,VALY,...

=item -F=KEY=VALX,VALY,...

=item --no-foo

This is foo bar baz bat gsdgdsgfsdd

Can be specified multiple times. If the same key is listed multiple times the value lists will be appended together.
    EOT
};


done_testing;
