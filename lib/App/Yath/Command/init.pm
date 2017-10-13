package App::Yath::Command::init;
use strict;
use warnings;

use parent 'App::Yath::Command';

our $VERSION = '0.001021';

use Test2::Harness::Util qw/open_file/;
use App::Yath::Util qw/is_generated_test_pl/;

sub show_bench { 0 }

sub summary { "Create/update test.pl to run tests via Test2::Harness" }

sub run {
    die "'test.pl' already exists, and does not appear to be a yath runner.\n"
        if -f 'test.pl' && !is_generated_test_pl('test.pl');

    print "\nWriting test.pl...\n\n";

    my $fh = open_file('test.pl', '>');

    print $fh <<'    EOT';
#!/usr/bin/env perl
# HARNESS-NO-PRELOAD
# HARNESS-CAT-LONG
# THIS IS A GENERATED YATH RUNNER TEST
use strict;
use warnings;

use App::Yath::Util qw/find_yath/;

system($^X, '-Ilib', find_yath(), 'test', 't', (-d 't2' ? ('t2') : ()), @ARGV);
my $exit = $?;

# This makes sure it works with prove.
print "1..1\n";
print "not " if $exit;
print "ok 1 - Passed tests when run by yath\n";
print STDERR "yath exited with $exit" if $exit;

exit($exit ? 255 : 0);
    EOT
}

1;


__END__

=pod

=encoding UTF-8

=head1 NAME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 COMMAND LINE USAGE

B<THIS SECTION IS AUTO-GENERATED AT BUILD>

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
