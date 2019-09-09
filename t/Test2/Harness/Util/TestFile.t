use Test2::V0 -target => 'Test2::Harness::Util::TestFile';
# HARNESS-DURATION-SHORT

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
    meta   => "#HARNESS-META-mykey-myval\n# HARNESS-META-otherkey-otherval\n# HARNESS-META mykey my-val2\n# HARNESS-META slack #my-val # comment after harness statement\n",

    package => "package Foo::Bar::Baz;\n# HARNESS-NO-PRELOAD\n",

    timeout    => "# HARNESS-TIMEOUT-EVENT 90\n# HARNESS-TIMEOUT-POSTEXIT 85\n",
    timeout2   => "# HARNESS-TIMEOUT-EVENT-90\n# HARNESS-TIMEOUT-POSTEXIT   85\n",
    badtimeout => "# HARNESS-TIMEOUT-EVENTX 90\n# HARNESS-TIMEOUT-POSTEXITX 85\n",

    conflicts1 => "# HARNESS-CONFLICTS PASSWD\n",
    conflicts2 => "# HARNESS-CONFLICTS PASSWD DAEMON\n",
    conflicts3 => "# HARNESS-CONFLICTS PASSWD\n# HARNESS-CONFLICTS DAEMON   # Nothing to see here\n",
    conflicts4 => "# HARNESS-CONFLICTS PASSWD DAEMON\n# HARNESS-CONFLICTS PASSWD\n# HARNESS-CONFLICTS PASSWD\n# HARNESS-CONFLICTS PASSWD DAEMON\n",

    extra_comments => "#!/usr/bin/perl\n\nuse strict;\n# comment here\n use warnings\n\n# copyright Dewey Cheatem and Howe\n# HARNESS-CAT-LONG\n# HARNESS-NO-TIMEOUT\n# HARNESS-USE-ISOLATION\n",

    not_perl     => "#!/usr/bin/bash\n",
    not_env_perl => "#!/usr/bin/env bash\n",
    binary       => "\0\a\cX\e\n\cR",
);

subtest timeouts => sub {
    my $one = $CLASS->new(file => File::Spec->catfile($tmp, 'timeout'));
    is($one->event_timeout,    90, "set event timeout");
    is($one->postexit_timeout, 85, "set event timeout");

    my $two = $CLASS->new(file => File::Spec->catfile($tmp, 'timeout2'));
    is($two->event_timeout,    90, "set event timeout");
    is($two->postexit_timeout, 85, "set event timeout");

    my $bad = $CLASS->new(file => File::Spec->catfile($tmp, 'badtimeout'));
    is(
        warnings { $bad->headers },
        [
            "'EVENTX' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at " . $bad->file . " line 1.\n",
            "'POSTEXITX' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at " . $bad->file . " line 2.\n",
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

subtest meta => sub {
    my $foo = $CLASS->new(file => File::Spec->catfile($tmp, 'meta'));

    is([$foo->meta],             [],                  "No key returns empty list");
    is([$foo->meta('foo')],      [],                  "Empty key returns empty list");
    is([$foo->meta('mykey')],    [qw/myval my-val2/], "Got both values for the 'mykey' key");
    is([$foo->meta('otherkey')], ['otherval'],        "Got other key");
    is([$foo->meta('slack')],    ['#my-val'],         "Got hyphenated key");
};

subtest foo => sub {
    my $foo = $CLASS->new(file => File::Spec->catfile($tmp, 'foo'));
    is($foo->check_category, 'foo', "Category is foo");
    is($foo->check_stage,    'foo', "Stage is foo");
};

subtest package => sub {
    my $one = $CLASS->new(file => File::Spec->catfile($tmp, 'package'));
    is($one->queue_item(42)->{use_preload}, 0, "No preload");
};

subtest taint => sub {
    my $taint = $CLASS->new(file => File::Spec->catfile($tmp, 'taint'), queue_args => [via => ['xxx']]);

    is($taint->switches, ['-t', '-w'], "No SHBANG switches");
    is($taint->shbang, {switches => ['-t', '-w'], line => "#!/usr/bin/env perl -t -w"}, "Parsed shbang");

    is(
        $taint->queue_item(42),
        {
            category    => 'general',
            duration    => 'medium',
            stage       => 'default',
            file        => $taint->file,
            job_name    => 42,
            job_id      => T(),
            stamp       => T(),
            switches    => ['-t', '-w'],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 1,
            binary      => 0,
            non_perl    => 0,
            conflicts   => [],
            via         => ['xxx'],
            shbang      => {line => "#!/usr/bin/env perl -t -w", switches => ['-t', '-w']},
            headers     => {},

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
            duration    => 'medium',
            stage       => 'default',
            file        => $warn->file,
            job_name    => 42,
            job_id      => T(),
            stamp       => T(),
            switches    => ['-w'],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 1,
            binary      => 0,
            non_perl    => 0,
            conflicts   => [],
            shbang      => {line => "#!/usr/bin/perl -w", switches => ['-w']},
            headers     => {},

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

    is($notime->check_category, 'general', "Category is general");
    is($notime->check_duration, 'long', "Duration is long");

    is($notime->switches, [], "No SHBANG switches");
    is($notime->shbang, {}, "No shbang");

    is(
        $notime->queue_item(42),
        {
            category    => 'general',
            duration    => 'long',
            stage       => 'default',
            file        => $notime->file,
            job_name    => 42,
            job_id      => T(),
            stamp       => T(),
            switches    => [],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 0,
            binary      => 0,
            non_perl    => 0,
            conflicts   => [],
            shbang      => {},
            headers     => {features => {timeout => 0}},

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
            duration    => 'long',
            stage       => 'default',
            file        => $all->file,
            job_name    => 42,
            job_id      => T(),
            stamp       => T(),
            switches    => [],
            use_fork    => 0,
            use_preload => 0,
            use_stream  => 0,
            use_timeout => 0,
            conflicts   => [],
            shbang      => {},
            binary      => 0,
            non_perl    => 0,
            headers     => {
                'features' => {
                    'timeout'   => 0,
                    'stream'    => 0,
                    'fork'      => 0,
                    'isolation' => 1,
                    'preload'   => 0
                },
            },

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

    is($med2->check_category, 'general', "Category is general");
    is($med2->check_duration, 'medium', "duration is medium");

    is($med2->switches, [], "No SHBANG switches");
    is($med2->shbang, {}, "No shbang");

    is(
        $med2->queue_item(42),
        {
            category    => 'general',
            duration    => 'medium',
            stage       => 'default',
            file        => $med2->file,
            job_name    => 42,
            job_id      => T(),
            stamp       => T(),
            switches    => [],
            use_fork    => 0,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 1,
            binary      => 0,
            non_perl    => 0,
            conflicts   => [],
            shbang      => {},
            headers     => {features => {fork => 0}},

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

    is($med1->check_category, 'general', "Category is general");
    is($med1->check_duration, 'medium', "duration is medium");

    is($med1->switches, [], "No SHBANG switches");
    is($med1->shbang, {}, "No shbang");

    is(
        $med1->queue_item(42),
        {
            category    => 'general',
            duration    => 'medium',
            stage       => 'default',
            file        => $med1->file,
            job_name    => 42,
            stamp       => T(),
            job_id      => T(),
            switches    => [],
            use_fork    => 1,
            use_preload => 0,
            use_stream  => 1,
            use_timeout => 1,
            binary      => 0,
            non_perl    => 0,
            conflicts   => [],
            shbang      => {},
            headers     => {features => {preload => 0}},

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

    is($long->check_category, 'isolation', "Category is isolation");
    is($long->check_duration, 'long',    "duration is long");

    ok(!exists $long->headers->{SEE}, "Did not see directive after code line");

    is($long->switches, [], "No SHBANG switches");
    is($long->shbang, {switches => [], line => "#!/usr/bin/perl"}, "got shbang");

    is(
        $long->queue_item(42),
        {
            category    => 'isolation',
            duration    => 'long',
            stage       => 'default',
            file        => $long->file,
            job_name    => 42,
            job_id      => T(),
            stamp       => T(),
            switches    => [],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 0,
            binary      => 0,
            non_perl    => 0,
            conflicts   => [],
            shbang      => {line => "#!/usr/bin/perl", switches => []},
            headers     => {
                duration => 'long',
                features => {
                    isolation => 1,
                    timeout   => 0,
                },
            },

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};

subtest extra_comments => sub {
    my $long = $CLASS->new(file => File::Spec->catfile($tmp, 'extra_comments'));

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

    is($long->check_category, 'isolation', "Category is isolation");
    is($long->check_duration, 'long', "Duration is long");

    is($long->switches, [], "No SHBANG switches");
    is($long->shbang, {switches => [], line => "#!/usr/bin/perl"}, "got shbang");

    is(
        $long->queue_item(42),
        {
            category    => 'isolation',
            duration    => 'long',
            stage       => 'default',
            file        => $long->file,
            job_name    => 42,
            job_id      => T(),
            stamp       => T(),
            switches    => [],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 0,
            binary      => 0,
            non_perl    => 0,
            conflicts   => [],
            shbang      => {line => "#!/usr/bin/perl", switches => []},
            headers     => {
                duration => 'long',
                features => {
                    isolation => 1,
                    timeout   => 0,
                },
            },

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};

subtest conflicts => sub {
    my $parsed_file = $CLASS->new(file => File::Spec->catfile($tmp, 'conflicts1'));
    is($parsed_file->conflicts_list, ['passwd'], "1 conflict line is reflected as an array");

    $parsed_file = $CLASS->new(file => File::Spec->catfile($tmp, 'conflicts2'));
    is([sort @{$parsed_file->conflicts_list}], ['daemon', 'passwd'], "1 conflict line with 2 conflict categories");

    $parsed_file = $CLASS->new(file => File::Spec->catfile($tmp, 'conflicts3'));
    is([sort @{$parsed_file->conflicts_list}], ['daemon', 'passwd'], "2 conflict lines with some comments on one of them");

    $parsed_file = $CLASS->new(file => File::Spec->catfile($tmp, 'conflicts4'));
    is([sort @{$parsed_file->conflicts_list}], ['daemon', 'passwd'], "Duplicate conflict lines only lead to 2 conflict items.");

};

subtest binary => sub {
    my $path = File::Spec->catfile($tmp, 'binary');
    ok(-B $path, "File is binary");

    is(
        dies { my $binary = $CLASS->new(file => $path); $binary->shbang },
        "Cannot run binary test file '$path': file is not executable.\n",
        "File must be executable",
    );

    my $control = mock $CLASS => (
        override => [
            is_executable => sub { 1 },
        ],
    );

    my $binary = $CLASS->new(file => $path);
    is($binary->switches, [], "No SHBANG switches");
    is($binary->shbang, {}, "No shbang");

    is(
        $binary->queue_item(42),
        {
            category    => 'general',
            duration    => 'medium',
            stage       => 'default',
            file        => $path,
            job_name    => 42,
            job_id      => T(),
            stamp       => T(),
            switches    => [],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 1,
            conflicts   => [],
            shbang      => {},
            headers     => {},
            binary      => 1,
            non_perl    => 1,

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};

subtest not_perl => sub {
    my $path = File::Spec->catfile($tmp, 'not_perl');

    is(
        dies { my $not_perl = $CLASS->new(file => $path); $not_perl->shbang },
        "Cannot run non-perl test file '$path': file is not executable.\n",
        "File must be executable",
    );

    my $control = mock $CLASS => (
        override => [
            is_executable => sub { 1 },
        ],
    );

    my $not_perl = $CLASS->new(file => File::Spec->catfile($tmp, 'not_perl'));

    is($not_perl->switches, [], "No SHBANG switches");
    is($not_perl->shbang, {line => "#!/usr/bin/bash", non_perl => 1}, "Non-perl shbang");

    is(
        $not_perl->queue_item(42),
        {
            category    => 'general',
            duration    => 'medium',
            stage       => 'default',
            file        => $not_perl->file,
            job_name    => 42,
            job_id      => T(),
            stamp       => T(),
            switches    => [],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 1,
            conflicts   => [],
            shbang      => {
                line     => "#!/usr/bin/bash",
                non_perl => 1,
            },
            headers  => {},
            binary   => 0,
            non_perl => 1,

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};


subtest not_env_perl => sub {
    my $path = File::Spec->catfile($tmp, 'not_env_perl');

    is(
        dies { my $not_env_perl = $CLASS->new(file => $path); $not_env_perl->shbang },
        "Cannot run non-perl test file '$path': file is not executable.\n",
        "File must be executable",
    );

    my $control = mock $CLASS => (
        override => [
            is_executable => sub { 1 },
        ],
    );

    my $not_env_perl = $CLASS->new(file => File::Spec->catfile($tmp, 'not_env_perl'));

    is($not_env_perl->switches, [], "No SHBANG switches");
    is($not_env_perl->shbang, {line => "#!/usr/bin/env bash", non_perl => 1}, "Non-perl shbang");

    is(
        $not_env_perl->queue_item(42),
        {
            category    => 'general',
            duration    => 'medium',
            stage       => 'default',
            file        => $not_env_perl->file,
            job_name    => 42,
            job_id      => T(),
            stamp       => T(),
            switches    => [],
            use_fork    => 1,
            use_preload => 1,
            use_stream  => 1,
            use_timeout => 1,
            conflicts   => [],
            shbang      => {
                line     => "#!/usr/bin/env bash",
                non_perl => 1,
            },
            headers  => {},
            binary   => 0,
            non_perl => 1,

            event_timeout    => undef,
            postexit_timeout => undef,
        },
        "Got queue item data",
    );
};

done_testing;
