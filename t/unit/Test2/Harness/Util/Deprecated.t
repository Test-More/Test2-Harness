use Test2::V0 -target => 'Test2::Harness::Util::Deprecated';

subtest 'fatal deprecation by default' => sub {
    local $Test2::Harness::Util::Deprecated::IGNORE_IMPORT = 0;

    my $pkg = 'TestDeprecated::Fatal::' . $$;
    like(
        dies { eval "package $pkg; use Test2::Harness::Util::Deprecated; 1" or die $@ },
        qr/has been deprecated/,
        "fatal deprecation dies with message"
    );
};

subtest 'ignored via IGNORE_IMPORT' => sub {
    local $Test2::Harness::Util::Deprecated::IGNORE_IMPORT = 1;

    my $pkg = 'TestDeprecated::Ignored::' . $$;
    ok(
        lives { eval "package $pkg; use Test2::Harness::Util::Deprecated; 1" or die $@ },
        "IGNORE_IMPORT prevents fatal error"
    );
};

subtest 'delegate sets up inheritance' => sub {
    local $Test2::Harness::Util::Deprecated::IGNORE_IMPORT = 1;

    my $base = 'TestDeprecated::Base::' . $$;
    my $dep  = 'TestDeprecated::Delegated::' . $$;
    {
        no strict 'refs';
        *{"${base}::hello"} = sub { 'world' };
    }

    eval "package $dep; use Test2::Harness::Util::Deprecated delegate => '$base'; 1" or die $@;

    {
        no strict 'refs';
        my @isa = @{"${dep}::ISA"};
        ok(grep { $_ eq $base } @isa, "delegate sets up ISA");
    }
};

subtest 'replaced message included' => sub {
    local $Test2::Harness::Util::Deprecated::IGNORE_IMPORT = 0;
    my $pkg = 'TestDeprecated::Replaced::' . $$;

    like(
        dies { eval "package $pkg; use Test2::Harness::Util::Deprecated replaced => 'Some::NewModule'; 1" or die $@ },
        qr/Some::NewModule/,
        "replacement module name appears in error"
    );
};

subtest 'deprecated() and deprecated_core() methods injected' => sub {
    local $Test2::Harness::Util::Deprecated::IGNORE_IMPORT = 1;

    my $pkg = 'TestDeprecated::Injected::' . $$;
    eval "package $pkg; use Test2::Harness::Util::Deprecated; 1" or die $@;

    # Note: the inject block overrides 'can' itself, so we inspect the
    # symbol table directly rather than calling ->can() on the package.
    {
        no strict 'refs';
        ok(defined &{"${pkg}::deprecated"},      "deprecated() method injected");
        ok(defined &{"${pkg}::deprecated_core"}, "deprecated_core() method injected");
        my $dep  = \&{"${pkg}::deprecated"};
        my $core = \&{"${pkg}::deprecated_core"};
        is($dep->(),  1, "deprecated() returns true");
        is($core->(), 0, "deprecated_core() returns false by default");
    }
};

done_testing;
