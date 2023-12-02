BEGIN { die "FIXME: These options got lost and need to be fixed!" };

__END__

    option summary => (
        type        => 'd',
        description => "Write out a summary json file, if no path is provided 'summary.json' will be used. The .json extension is added automatically if omitted.",

        long_examples => ['', '=/path/to/summary.json'],

        normalize  => \&normalize_summary,
        action     => \&summary_action,
        applicable => sub {
            my ($option, $options) = @_;

            return 1 if $options->included->{'App::Yath::Options::Run'};
            return 0;
        },
    );

    option clear => (
        short       => 'C',
        description => 'Clear the work directory if it is not already empty',
    );


    option no_wrap => (
