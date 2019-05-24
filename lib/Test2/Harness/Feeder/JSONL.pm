package Test2::Harness::Feeder::JSONL;
use strict;
use warnings;

our $VERSION = '0.001077';

use Carp qw/croak/;

use Test2::Harness::Event;
use Test2::Harness::Job;
use Test2::Harness::Run;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util qw/open_file/;

use IO::Uncompress::Bunzip2 qw($Bunzip2Error);
use IO::Uncompress::Gunzip qw($GunzipError);

BEGIN { require Test2::Harness::Feeder; our @ISA = ('Test2::Harness::Feeder') }

use Test2::Harness::Util::HashBase qw{ -file };

sub complete { 1 }

sub init {
    my $self = shift;

    $self->SUPER::init();

    my $file = delete $self->{+FILE} or croak "'file' is a required attribute";

    my $fh;
    if ($file =~ m/\.bz2$/) {
        $fh = IO::Uncompress::Bunzip2->new($file) or die "Could not open bz2 file '$file': $Bunzip2Error";
    }
    elsif ($file =~ m/\.gz/) {
        $fh = IO::Uncompress::Gunzip2->new($file) or die "Could not open gz file '$file': $GunzipError";
    }
    else {
        $fh = open_file($file, '<');
    }

    $self->{+FILE} = Test2::Harness::Util::File::JSONL->new(
        name => $file,
        fh   => $fh,
    );
}

sub poll {
    my $self = shift;
    my ($max) = @_;

    my @out;
    while (my $line = $self->{+FILE}->read_line) {
        my $watcher = delete $line->{facet_data}->{harness_watcher};
        next if $watcher->{added_by_watcher};

        bless($line->{facet_data}->{harness_run}, 'Test2::Harness::Run')
            if $line->{facet_data}->{harness_run};

        bless($line->{facet_data}->{harness_job}, 'Test2::Harness::Job')
            if $line->{facet_data}->{harness_job};

        # Strip out any previous harness errors
        if (my $errors = $line->{facet_data}->{errors}) {
            @$errors = grep { !$_->{from_harness} } @$errors;
        }

        push @out => Test2::Harness::Event->new(stamp => time, %$line);
        last if $max && @out >= $max;
    }

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Feeder::JSONL - Get a feed of events from an event log file.

=head1 DESCRIPTION

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
