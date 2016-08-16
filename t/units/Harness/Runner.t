use Test2::Bundle::Extended -target => 'Test2::Harness::Runner';

use File::Temp;

sub spew_tmp {
    my $temp = File::Temp->new( UNLINK => 0 );

    print $temp @_;

    return $temp->filename;
}


subtest "header" => sub {
    my %tests = (
        empty_file => {
            want => hash {
                field shbang   => '';
                field features => {};
            },
            file => "",
        },
        
        blank_file => {
            want => hash {
                field shbang   => '';
                field features => {};
            },
            file => "   \n  \t\n  \n  ",
        },

        shbang => {
            want => hash {
                field shbang   => "#!/usr/bin/perl -w";
                field switches => ["-w"];
                field features => {};
            },
            file => <<'END',
#!/usr/bin/perl -w

stuff
END
        },

        features => {
            want => hash {
                field shbang   => "";
                field features => { foo => 1, bar => 0 };
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
            },
            file => <<'END',
# HARNESS-YES-FOO
END
        },
    );
    
    while( my($name, $test) = each %tests ) {
        my $runner = $CLASS->new;

        my $tmp = spew_tmp($test->{file});

        $DB::single = $name =~ /features/;
        is $runner->header($tmp), $test->{want}, $name;
    }
};


done_testing;

