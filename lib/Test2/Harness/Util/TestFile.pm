package Test2::Harness::Util::TestFile;
use strict;
use warnings;

our $VERSION = '0.001050';

use Carp qw/croak/;

use Time::HiRes qw/time/;

use File::Spec();

use Test2::Harness::Util qw/open_file/;

use Test2::Harness::Util::HashBase qw{
    -file -_scanned -_headers -_shbang -queue_args
};

sub init {
    my $self = shift;

    my $file = $self->file;

    # We want absolute path
    $file = File::Spec->rel2abs($file);
    $self->{+FILE} = $file;

    $self->{+QUEUE_ARGS} ||= [];

    croak "Invalid test file '$file'" unless -f $file;
}

my %DEFAULTS = (
    timeout   => 1,
    fork      => 1,
    preload   => 1,
    stream    => 1,
    isolation => 0,
);

sub check_feature {
    my $self = shift;
    my ($feature, $default) = @_;

    $default = $DEFAULTS{$feature} unless defined $default;

    return $default unless defined $self->headers->{features}->{$feature};
    return 1 if $self->headers->{features}->{$feature};
    return 0;
}

sub check_stage {
    my $self = shift;
    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{stage} || 'default';
}

sub meta {
    my $self = shift;
    my ($key) = @_;

    $self->_scan unless $self->{+_SCANNED};
    my $meta = $self->{+_HEADERS}->{meta} or return ();

    return () unless $key && $meta->{$key};

    return @{$meta->{$key}};
}

sub check_category {
    my $self = shift;
    $self->_scan unless $self->{+_SCANNED};
    my $category = $self->{+_HEADERS}->{category};

    return $category if $category;

    my $fork    = $self->check_feature(fork      => 1);
    my $preload = $self->check_feature(preload   => 1);
    my $timeout = $self->check_feature(timeout   => 1);
    my $isolate = $self->check_feature(isolation => 0);

    # 'isolation' queue if isolation requested
    return 'isolation' if $isolate;

    # 'medium' queue for anything that cannot preload or fork
    return 'medium' unless $preload && $fork;

    # 'long' for anything with no timeout
    return 'long' unless $timeout;

    return 'general';
}

sub event_timeout    { $_[0]->headers->{timeout}->{event} }
sub postexit_timeout { $_[0]->headers->{timeout}->{postexit} }

sub headers {
    my $self = shift;
    $self->_scan unless $self->{+_SCANNED};
    return {} unless $self->{+_HEADERS};
    return {%{$self->{+_HEADERS}}};
}

sub shbang {
    my $self = shift;
    $self->_scan unless $self->{+_SCANNED};
    return {} unless $self->{+_SHBANG};
    return {%{$self->{+_SHBANG}}};
}

sub switches {
    my $self = shift;

    my $shbang   = $self->shbang       or return [];
    my $switches = $shbang->{switches} or return [];

    return $switches;
}

sub _scan {
    my $self = shift;

    return if $self->{+_SCANNED}++;

    my $fh = open_file($self->{+FILE});

    my %headers;
    for (my $ln = 1; my $line = <$fh>; $ln++) {
        chomp($line);
        next if $line =~ m/^\s*$/;

        if ($ln == 1 && $line =~ m/^#!/) {
            my $shbang = $self->_parse_shbang($line);
            if ($shbang) {
                $self->{+_SHBANG} = $shbang;
                next;
            }
        }

        next if $line =~ m/^\s*(use|require|BEGIN|package)\b/;
        last unless $line =~ m/^\s*#\s*HARNESS-(.+)$/;

        my ($dir, @args) = split /[-\s]/, lc($1);

        if ($dir eq 'no') {
            my ($feature) = @args;
            $headers{features}->{$feature} = 0;
        }
        elsif ($dir eq 'yes' || $dir eq 'use') {
            my ($feature) = @args;
            $headers{features}->{$feature} = 1;
        }
        elsif ($dir eq 'stage') {
            my ($name) = @args;
            $headers{stage} = $name;
        }
        elsif ($dir eq 'meta') {
            my ($key, $val) = @args;
            push @{$headers{meta}->{$key}} => $val;
        }
        elsif ($dir eq 'category' || $dir eq 'cat') {
            my ($name) = @args;
            $headers{category} = $name;
        }
        elsif ($dir eq 'timeout') {
            my ($type, $num) = @args;

            warn "'" . uc($type) . "' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at $self->{+FILE} line $ln.\n"
                unless $type =~ m/^(event|postexit)$/;

            $headers{timeout}->{$type} = $num;
        }
        else {
            warn "Unknown harness directive '$dir' at $self->{+FILE} line $ln.\n";
        }
    }

    $self->{+_HEADERS} = \%headers;
}

sub _parse_shbang {
    my $self = shift;
    my $line = shift;

    return {} if !defined $line;

    my %shbang;

    # NOTE: Test this, the dashes should be included with the switches
    my $shbang_re = qr{
        ^
          \#!.*perl.*?        # the perl path
          (?: \s (-.+) )?       # the switches, maybe
          \s*
        $
    }xi;

    if ($line =~ $shbang_re) {
        my @switches = grep { m/\S/ } split /\s+/, $1 if defined $1;
        $shbang{switches} = \@switches;
        $shbang{line}     = $line;
    }

    return \%shbang;
}

sub queue_item {
    my $self = shift;
    my ($job_id) = @_;

    my $category = $self->check_category;
    my $stage = $self->check_stage;

    my $fork    = $self->check_feature(fork    => 1);
    my $preload = $self->check_feature(preload => 1);
    my $timeout = $self->check_feature(timeout => 1);
    my $stream  = $self->check_feature(stream  => 1);

    return {
        category    => $category,
        file        => $self->file,
        headers     => $self->headers,
        job_id      => $job_id,
        shbang      => $self->shbang,
        stage       => $stage,
        stamp       => time,
        switches    => $self->switches,
        use_fork    => $fork,
        use_preload => $preload,
        use_stream  => $stream,
        use_timeout => $timeout,

        event_timeout    => $self->event_timeout,
        postexit_timeout => $self->postexit_timeout,

        @{$self->{+QUEUE_ARGS}},
    };
}

my %RANK = (
    immiscible => 1,
    long       => 2,
    medium     => 3,
    general    => 4,
    isolation  => 5,
);
sub rank {
    my $self = shift;
    return $RANK{$self->check_category} || 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Job::TestFile - Logic to scan a test file.

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
