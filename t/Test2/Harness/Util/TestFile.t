use Test2::V0 -target => 'Test2::Harness::Util::TestFile';

use ok $CLASS;

use Test2::Tools::GenTemp qw/gen_temp/;

my $tmp = gen_temp(
    long   => "#!/usr/bin/perl\n\nuse strict;\n use warnings\n\n# HARNESS-CAT-LONG\n# HARNESS-NO-TIMEOUT\n# HARNESS-USE-ISOLATION\nfoo\n# HARNESS-NO-SEE\n",
    med1   => "# HARNESS-NO-PRELOAD\n",
    med2   => "#HARNESS-NO-FORK\n",
    all    => "#HARNESS-NO-TIMEOUT\n# HARNESS-NO-STREAM\n# HARNESS-NO-FORK\n# HARNESS-NO-PRELOAD\n# HARNESS-USE-ISOLATION\n",
    notime => "#HARNESS-NO-TIMEOUT\n",
    warn   => "#!/usr/bin/perl -w\n",
    taint  => "#!/usr/bin/env perl -t -w\n",
    foo    => "#HARNESS-CATEGORY-FOO\n#HARNESS-STAGE-FOO",

    timeout    => "# HARNESS-TIMEOUT-EVENT 90\n# HARNESS-TIMEOUT-POSTEXIT 85\n",
    badtimeout => "# HARNESS-TIMEOUT-EVENTX 90\n# HARNESS-TIMEOUT-POSTEXITX 85\n",
);

subtest timeouts => sub {
    my $one = $CLASS->new(file => File::Spec->catfile($tmp, 'timeout'));
    is($one->event_timeout, 90, "set event timeout");
    is($one->postexit_timeout, 85, "set event timeout");

    my $two = $CLASS->new(file => File::Spec->catfile($tmp, 'badtimeout'));
    is(
        warnings { $two->headers },
        [
            "'EVENTX' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at " . $two->file . " line 1.\n",
            "'POSTEXITX' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at " . $two->file . " line 2.\n",
        ],
        "Got warnings"
    );
};

subtest invalid => sub {
    like(
        dies { $CLASS->new(file => File::Spec->catfile($tmp, 'invalid')) },
        qr/^Invalid test file/,
        "Need a valid test file"
    );
};

subtest foo => sub {
    my $foo = $CLASS->new(file => File::Spec->catfile($tmp, 'foo'));
    is($foo->check_category, 'foo', "Category is foo");
    is($foo->check_stage, 'foo', "Stage is foo");
};

subtest taint => sub {
    my $taint = $CLASS->new(file => File::Spec->catfile($tmp, 'taint'), queue_args => [via => ['xxx']]);

    is($taint->switches, ['-t', '-w'], "No SHBANG switches");
    is($taint->shbang, {switches => ['-t', '-w'], line => "#!/usr/bin/env perl -t -w"}, "Parsed shbang");

    is(
        $taint->queue_item(42),
        {
            category    => 'general',
            stage       => 'default',
            file        => $taint->file,
            job_id      => 42,
            stamp       => T(),
            switches    => ['-t', '-w'],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 1,
            via         => ['xxx'],

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};

subtest warn => sub {
    my $warn = $CLASS->new(file => File::Spec->catfile($tmp, 'warn'));

    is($warn->switches, ['-w'], "got SHBANG switches");
    is($warn->shbang, {switches => ['-w'], line => "#!/usr/bin/perl -w"}, "Parsed shbang");

    is(
        $warn->queue_item(42),
        {
            category    => 'general',
            stage       => 'default',
            file        => $warn->file,
            job_id      => 42,
            stamp       => T(),
            switches    => ['-w'],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 1,

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};


subtest notime => sub {
    my $notime = $CLASS->new(file => File::Spec->catfile($tmp, 'notime'));

    is($notime->check_feature('timeout'), 0, "Timeouts turned off");
    is($notime->check_feature('timeout', 1), 0, "Timeouts turned off with default 1");

    is($notime->check_category, 'long', "Category is long");

    is($notime->switches, [], "No SHBANG switches");
    is($notime->shbang, {}, "No shbang");

    is(
        $notime->queue_item(42),
        {
            category    => 'long',
            stage       => 'default',
            file        => $notime->file,
            job_id      => 42,
            stamp       => T(),
            switches    => [],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 0,

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};

subtest all => sub {
    my $all = $CLASS->new(file => File::Spec->catfile($tmp, 'all'));

    is($all->check_feature('timeout'), 0, "Timeouts turned off");
    is($all->check_feature('timeout', 1), 0, "Timeouts turned off with default 1");

    is($all->check_feature('fork'), 0, "Forking is off");
    is($all->check_feature('fork', 1), 0, "Checking fork with different default");

    is($all->check_feature('preload'), 0, "Preload is off");
    is($all->check_feature('preload', 1), 0, "Checking preload with different default");

    is($all->check_feature('isolation'), 1, "No isolation");
    is($all->check_feature('isolation', 0), 1, "Use isolation with a default of false");

    is($all->check_feature('stream'), 0, "Use stream");
    is($all->check_feature('stream', 1), 0, "no stream with a default of true");

    is($all->check_category, 'isolation', "Category is isolation");

    is($all->switches, [], "No SHBANG switches");
    is($all->shbang, {}, "No shbang");

    is(
        $all->queue_item(42),
        {
            category    => 'isolation',
            stage       => 'default',
            file        => $all->file,
            job_id      => 42,
            stamp       => T(),
            switches    => [],
            use_fork    => 0,
            use_preload => 0,
            use_stream  => 0,
            use_timeout => 0,

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};

subtest med2 => sub {
    my $med2 = $CLASS->new(file => File::Spec->catfile($tmp, 'med2'));

    is($med2->check_feature('timeout'), 1, "Timeouts turned on");
    is($med2->check_feature('timeout', 0), 0, "Timeouts turned off with default 0");

    is($med2->check_feature('fork'), 0, "Forking is off");
    is($med2->check_feature('fork', 1), 0, "Checking fork with different default");

    is($med2->check_feature('preload'), 1, "Preload is on");
    is($med2->check_feature('preload', 0), 0, "Checking preload with different default");

    is($med2->check_feature('isolation'), 0, "No isolation");
    is($med2->check_feature('isolation', 1), 1, "Use isolation with a default of true");

    is($med2->check_feature('stream'), 1, "Use stream");
    is($med2->check_feature('stream', 0), 0, "no stream with a default of false");

    is($med2->check_category, 'medium', "Category is medium");

    is($med2->switches, [], "No SHBANG switches");
    is($med2->shbang, {}, "No shbang");

    is(
        $med2->queue_item(42),
        {
            category    => 'medium',
            stage       => 'default',
            file        => $med2->file,
            job_id      => 42,
            stamp       => T(),
            switches    => [],
            use_fork    => 0,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 1,

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};

subtest med1 => sub {
    my $med1 = $CLASS->new(file => File::Spec->catfile($tmp, 'med1'));

    is($med1->check_feature('timeout'), 1, "Timeouts turned on");
    is($med1->check_feature('timeout', 0), 0, "Timeouts turned off with default 0");

    is($med1->check_feature('fork'), 1, "Forking is ok");
    is($med1->check_feature('fork', 0), 0, "Checking fork with different default");

    is($med1->check_feature('preload'), 0, "Preload is off");
    is($med1->check_feature('preload', 1), 0, "Checking preload with different default");

    is($med1->check_feature('isolation'), 0, "No isolation");
    is($med1->check_feature('isolation', 1), 1, "Use isolation with a default of true");

    is($med1->check_feature('stream'), 1, "Use stream");
    is($med1->check_feature('stream', 0), 0, "no stream with a default of false");

    is($med1->check_category, 'medium', "Category is medium");

    is($med1->switches, [], "No SHBANG switches");
    is($med1->shbang, {}, "No shbang");

    is(
        $med1->queue_item(42),
        {
            category    => 'medium',
            stage       => 'default',
            file        => $med1->file,
            job_id      => 42,
            stamp       => T(),
            switches    => [],
            use_fork    => 1,
            use_preload => 0,
            use_stream  => 1,
            use_timeout => 1,

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};

subtest long => sub {
    my $long = $CLASS->new(file => File::Spec->catfile($tmp, 'long'));

    is($long->check_feature('timeout'), 0, "Timeouts turned off");
    is($long->check_feature('timeout', 1), 0, "Timeouts turned off even with default 1");

    is($long->check_feature('fork'), 1, "Forking is ok");
    is($long->check_feature('fork', 0), 0, "Checking fork with different default");

    is($long->check_feature('preload'), 1, "Preload is ok");
    is($long->check_feature('preload', 0), 0, "Checking preload with different default");

    is($long->check_feature('isolation'), 1, "Use isolation");
    is($long->check_feature('isolation', 0), 1, "Use isolation even with a default of false");

    is($long->check_feature('stream'), 1, "Use stream");
    is($long->check_feature('stream', 0), 0, "no stream with a default of false");

    is($long->check_category, 'long', "Category is long");

    ok(!exists $long->headers->{SEE}, "Did not see directive after code line");

    is($long->switches, [], "No SHBANG switches");
    is($long->shbang, {switches => [], line => "#!/usr/bin/perl"}, "got shbang");

    is(
        $long->queue_item(42),
        {
            category    => 'long',
            stage       => 'default',
            file        => $long->file,
            job_id      => 42,
            stamp       => T(),
            switches    => [],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 0,

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};

done_testing;
