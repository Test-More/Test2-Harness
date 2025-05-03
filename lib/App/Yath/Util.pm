package App::Yath::Util;
use strict;
use warnings;

our $VERSION = '2.000005';

use File::Spec();
use File::ShareDir();

use Test2::Harness::Util qw/clean_path/;

use Importer Importer => 'import';
use Config qw/%Config/;
use Carp qw/croak/;

BEGIN {
    if (eval { require IO::Pager; 1 }) {
        *paged_print = sub {
            local $SIG{PIPE} = sub {};
            local $ENV{LESS} = "-r";
            my $pager = IO::Pager->new(*STDOUT);
            $pager->print($_) for @_;
        };
    }
    else {
        *paged_print = sub { print @_ };
    }
}

our @EXPORT_OK = qw{
    is_generated_test_pl
    find_yath
    share_dir share_file
    paged_print
};

sub share_file {
    my ($file) = @_;

    my $path = "share/$file";
    return $path if -e "share/Test2-Harness" && -f $path;

    return File::ShareDir::dist_file('Test2-Harness' => $file);

    croak "Could not find '$file'";
}

sub share_dir {
    my ($dir) = @_;

    my $path = "share/$dir";
    return $path if -e "share/Test2-Harness" && -d $path;

    my $root = File::ShareDir::dist_dir('Test2-Harness');

    $path = "$root/$dir";

    croak "Could not find '$dir'" unless -d $path;

    return $path;
}

sub find_yath {
    return $App::Yath::Script::SCRIPT if defined $App::Yath::Script::SCRIPT;

    if (-d 'scripts') {
        my $script = File::Spec->catfile('scripts', 'yath');
        return $App::Yath::Script::SCRIPT = clean_path($script) if -e $script && -x $script;
    }

    my @keys = qw{
        bin binexp initialinstalllocation installbin installscript
        installsitebin installsitescript installusrbinperl installvendorbin
        scriptdir scriptdirexp sitebin sitebinexp sitescript sitescriptexp
        vendorbin vendorbinexp
    };

    my %seen;
    for my $path (@Config{@keys}) {
        next unless $path;
        next if $seen{$path}++;

        my $script = File::Spec->catfile($path, 'yath');
        next unless -f $script && -x $script;

        $App::Yath::Script::SCRIPT = $script = clean_path($script);
        return $script;
    }

    die "Could not find yath in Config paths";
}

sub is_generated_test_pl {
    my ($file) = @_;

    open(my $fh, '<', $file) or die "Could not open '$file': $!";

    my $count = 0;
    while (my $line = <$fh>) {
        last if $count++ > 5;
        next unless $line =~ m/^# THIS IS A GENERATED YATH RUNNER TEST$/;
        return 1;
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Util - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

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

