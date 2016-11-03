use Test2::Bundle::Extended -target => 'Test2::Harness::Runner';

use File::Temp;

sub spew_tmp {
    my $temp = File::Temp->new( UNLINK => 0 );

    print $temp @_;

    return $temp->filename;
}


subtest "_parse_shbang good" => sub {
    my $runner = $CLASS->new;
    
    my %is_shbang = (
        "#! /usr/bin/perl"              => [],
        "#!/usr/bin/perl"               => [],
        "#!/usr/bin/perl -Tw"           => ["-Tw"],
        "#!/usr/bin/perl -T -w"         => ["-T", "-w"],
        "#!/usr/bin/perl -t -w"         => ["-t", "-w"],
        "#!/perl/blah/perl"             => [],
        "#!/perl/blah/perl5 -w"         => ["-w"],
        "#!/perl/blah/perl5.10 -w"      => ["-w"],
        "#!/usr/bin/env perl -Tw"       => ["-Tw"],
        "#!/usr/bin/env perl -Tw"       => ["-Tw"],
    );

    while( my($line, $switches) = each %is_shbang ) {
        note $line;

        my $want = hash {
            field switches => $switches;
            field shbang   => $line;
            etc;
        };
        
        is $runner->_parse_shbang($line), $want, "_parse_shbang()";

        my $tmp = spew_tmp($line);
        is $runner->header($tmp), $want, "header()";
    }
};


subtest "_parse_shbang bad" => sub {
    my $runner = $CLASS->new;
    
    my @lines = (
        "!/usr/bin/perl",
        "#/usr/bin/perl -Tw",
        "#!/usr/bin/bash",
        "#!/usr/bin/prel",
        "#!/usr/bin/env virus -Tw",
        " #!/usr/bin/perl",
    );

    for my $line (@lines) {
        note $line;

        is $runner->_parse_shbang($line), {}, "_parse_shbang()";
    }
};


subtest "header" => sub {
    my %tests = (
        empty_file => {
            want => hash {
                field shbang   => '';
                field features => {};
                etc;
            },
            file => "",
        },
        
        blank_file => {
            want => hash {
                field shbang   => '';
                field features => {};
                etc;
            },
            file => "   \n  \t\n  \n  ",
        },

        shbang => {
            want => hash {
                field shbang   => "#!/usr/bin/perl -w";
                field switches => ["-w"];
                field features => {};
                etc;
            },
            file => <<'END',
#!/usr/bin/perl -w

stuff
END
        },

        features => {
            want => hash {
                field shbang   => "#!/usr/bin/perl";
                field features => { foo => 1, bar => 0 };
                etc;
            },
            file => <<'END',
#!/usr/bin/perl
# HARNESS-YES-FOO
# HARNESS-NO-BAR
END
        },

        first_line_feature => {
            want => hash {
                field shbang   => '';
                field features => { foo => 1 };
                etc;
            },
            file => <<'END',
# HARNESS-YES-FOO
END
        },
    );
    
    while( my($name, $test) = each %tests ) {
        my $runner = $CLASS->new;

        my $tmp = spew_tmp($test->{file});

        is $runner->header($tmp), $test->{want}, $name;
    }
};


done_testing;

