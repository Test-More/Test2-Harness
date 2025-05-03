package Test2::Harness::TestFile;
use strict;
use warnings;

our $VERSION = '2.000005';

use File::Spec;

use Carp qw/croak/;
use Time::HiRes qw/time/;
use List::Util 1.45 qw/uniq/;

use Test2::Harness::TestSettings;

use Test2::Harness::Util qw/open_file clean_path/;

use Test2::Harness::Util::HashBase qw{
    <file +relative <_scanned <_headers +_shbang <is_binary +non_perl
    comment
    _category _stage _duration _min_slots _max_slots
    +test_settings

    ch_dir
};

sub set_duration { $_[0]->set__duration(lc($_[1])) }
sub set_category { $_[0]->set__category(lc($_[1])) }

sub set_stage     { $_[0]->set__stage($_[1]) }
sub set_min_slots { $_[0]->set__min_slots($_[1]) }
sub set_max_slots { $_[0]->set__max_slots($_[1]) }

sub retry { $_[0]->headers->{retry} }
sub set_retry {
    my $self = shift;
    my $val = @_ ? $_[0] : 1;

    $self->scan;

    $self->{+_HEADERS}->{retry} = $val;
}

sub retry_isolated { $_[0]->headers->{retry_isolated} }
sub set_retry_isolated {
    my $self = shift;
    my $val = @_ ? $_[0] : 1;

    $self->scan;

    $self->{+_HEADERS}->{retry_isolated} = $val;
}

sub set_smoke {
    my $self = shift;
    my $val = @_ ? $_[0] : 1;

    $self->scan;

    $self->{+_HEADERS}->{features}->{smoke} = $val;
}

sub init {
    my $self = shift;

    my $file = $self->file;

    # We want absolute path
    $file = clean_path($file, 0);
    $self->{+FILE} = $file;

    croak "Invalid test file '$file'" unless -f $file;

    if($self->{+IS_BINARY} = -B $file && !-z $file) {
        $self->{+NON_PERL} = 1;
        die "Cannot run binary test file '$file': file is not executable.\n"
            unless $self->is_executable;
    }
}

sub non_perl {
    my $self = shift;
    return $self->{+NON_PERL} if exists $self->{+NON_PERL};
    return $self->{+NON_PERL} = 1 if $self->{+IS_BINARY};

    $self->scan();

    return $self->{+NON_PERL} ? 1 : 0;
}

sub relative {
    my $self = shift;
    return $self->{+RELATIVE} //= File::Spec->abs2rel($self->{+FILE});
}

my %DEFAULTS = (
    timeout   => 1,
    fork      => 1,
    preload   => 1,
    stream    => 1,
    run       => 1,
    isolation => 0,
    smoke     => 0,
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

    return $self->{+_STAGE} if $self->{+_STAGE};

    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{stage} || undef;
}

sub check_min_slots {
    my $self = shift;

    return $self->{+_MIN_SLOTS} if $self->{+_MIN_SLOTS};

    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{min_slots} // undef;
}

sub check_max_slots {
    my $self = shift;

    return $self->{+_MAX_SLOTS} if $self->{+_MAX_SLOTS};

    $self->_scan unless $self->{+_SCANNED};
    return $self->{+_HEADERS}->{max_slots} // undef;
}

sub meta {
    my $self = shift;
    my ($key) = @_;

    $self->_scan unless $self->{+_SCANNED};
    my $meta = $self->{+_HEADERS}->{meta} or return ();

    return () unless $key && $meta->{$key};

    return @{$meta->{$key}};
}

sub check_duration {
    my $self = shift;

    return $self->{+_DURATION} if $self->{+_DURATION};

    $self->_scan unless $self->{+_SCANNED};
    my $duration = $self->{+_HEADERS}->{duration};
    return $duration if $duration;

    my $timeout = $self->check_feature(timeout => 1);

    # 'long' for anything with no timeout
    return 'long' unless $timeout;

    return 'medium';
}

sub check_category {
    my $self = shift;

    return $self->{+_CATEGORY} if $self->{+_CATEGORY};

    $self->_scan unless $self->{+_SCANNED};
    my $category = $self->{+_HEADERS}->{category};

    return $category if $category;

    my $isolate = $self->check_feature(isolation => 0);

    # 'isolation' queue if isolation requested
    return 'isolation' if $isolate;

    return 'general';
}

sub event_timeout     { $_[0]->headers->{timeout}->{event} }
sub post_exit_timeout { $_[0]->headers->{timeout}->{postexit} }

sub conflicts_list {
    return $_[0]->headers->{conflicts} || [];    # Assure conflicts is always an array ref.
}

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

sub is_executable {
    my $self = shift;
    my ($file) = @_;
    $file //= $self->{+FILE};
    return -x $file;
}

sub scan {
    my $self = shift;
    $self->_scan();
    return;
}

sub _scan {
    my $self = shift;

    return if $self->{+_SCANNED}++;
    return if $self->{+IS_BINARY};

    my $fh = open_file($self->{+FILE});
    my $comment = $self->{+COMMENT} // '#';

    my %headers;
    for (my $ln = 1; my $line = <$fh>; $ln++) {
        chomp($line);
        next if $line =~ m/^\s*$/;

        if ($ln == 1 && $line =~ m/^#!/) {
            my $shbang = $self->_parse_shbang($line);
            if ($shbang) {
                $self->{+_SHBANG} = $shbang;

                if ($shbang->{non_perl}) {
                    $self->{+NON_PERL} = 1;
                }

                next;
            }
        }

        # Uhg, breaking encapsulation between yath and the harness
        if ($line =~ m/^\s*#\s*THIS IS A GENERATED YATH RUNNER TEST/) {
            $headers{features}->{run} = 0;
            next;
        }

        next if $line =~ m/^\s*#/ && $line !~ m/^\s*#\s*HARNESS-.+/;    # Ignore commented lines which aren't HARNESS-?
        next if $line =~ m/^\s*(use|require|BEGIN|package)\b/;          # Only supports single line BEGINs
        last unless $line =~ m/^\s*\Q$comment\E\s*HARNESS-(.+)$/;

        my ($dir, $rest) = split /[-\s]+/, $1, 2;
        $dir = lc($dir);
        my @args;
        if ($dir eq 'meta') {
            @args = split /\s+/, $rest, 2;                              # Check for white space delimited
            @args = split(/[-]+/, $rest, 2) if scalar @args == 1;       # Check for dash delimited
            $args[1] =~ s/\s+(?:#.*)?$//;                               # Strip trailing white space and comment if present
        }
        elsif ($rest) {
            $rest =~ s/\s+(?:#.*)?$//;                                  # Strip trailing white space and comment if present
            @args = split /[-\s]+/, $rest;
        }

        if ($dir eq 'no') {
            my $feature = lc(join '_' => @args);
            if ($feature eq 'retry') {
                $headers{retry} = 0
            } else {
                $headers{features}->{$feature} = 0;
            }
        }
        elsif ($dir eq 'smoke') {
            $headers{features}->{smoke} = 1;
        }
        elsif ($dir eq 'retry') {
            $headers{retry} = 1 unless @args || defined $headers{retry};
            for my $arg (@args) {
                if ($arg =~ m/^\d+$/) {
                    $headers{retry} = int $arg;
                }
                elsif ($arg =~ m/^iso/i) {
                    $headers{retry} //= 1;
                    $headers{retry_isolated} = 1;
                }
                else {
                    warn "Unknown 'HARNESS-RETRY' argument '$arg' at $self->{+FILE} line $ln.\n";
                }
            }
        }
        elsif ($dir eq 'yes' || $dir eq 'use') {
            my $feature = lc(join '_' => @args);
            $headers{features}->{$feature} = 1;
        }
        elsif ($dir eq 'stage') {
            my ($name) = @args;
            $headers{stage} = $name;
        }
        elsif ($dir eq 'meta') {
            my ($key, $val) = @args;
            $key = lc($key);
            push @{$headers{meta}->{$key}} => $val;
        }
        elsif ($dir eq 'duration' || $dir eq 'dur') {
            my ($name) = @args;
            $name = lc($name);
            $headers{duration} = $name;
        }
        elsif ($dir eq 'category' || $dir eq 'cat') {
            my ($name) = @args;
            $name = lc($name);
            if ($name =~ m/^(long|medium|short)$/i) {
                $headers{duration} = $name;
            }
            else {
                $headers{category} = $name;
            }
        }
        elsif ($dir eq 'conflicts') {
            my @conflicts_array;

            foreach my $arg (@args) {
                push @conflicts_array, lc($arg);
            }

            # Allow multiple lines with # HARNESS-CONFLICTS FOO
            $headers{conflicts} ||= [];
            push @{$headers{conflicts}}, @conflicts_array;

            # Make sure no more than 1 conflict is ever present.
            @{$headers{conflicts}} = uniq @{$headers{conflicts}};
        }
        elsif ($dir eq 'timeout') {
            my ($type, $num, $extra) = @args;
            $type = lc($type);
            $num = lc($num);

            ($type, $num) = ('postexit', $extra) if $type eq 'post' && $num eq 'exit';

            warn "'" . uc($type) . "' is not a valid timeout type, use 'EVENT' or 'POSTEXIT' at $self->{+FILE} line $ln.\n"
                unless $type =~ m/^(event|postexit)$/;

            $headers{timeout}->{$type} = $num;
        }
        elsif ($dir eq 'job' && $rest =~ m/slots(?:\s+(\d+)(?:\s+(\d+))?)?$/i) {
            $headers{min_slots} //= $1 // 1;
            $headers{max_slots} //= $2 ? $2 : -1;
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
        my @switches;
        @switches         = grep { m/\S/ } split /\s+/, $1 if defined $1;
        $shbang{switches} = \@switches;
        $shbang{line}     = $line;
    }
    elsif ($line =~ m/^#!/ && $line !~ m/perl/i) {
        $shbang{line}     = $line;
        $shbang{non_perl} = 1;
    }

    return \%shbang;
}

sub test_settings {
    my $self = shift;

    return $self->{+TEST_SETTINGS} if $self->{+TEST_SETTINGS};

    die "The '$self->{+FILE}' test specifies that it should not be run by Test2::Harness.\n"
        unless $self->check_feature(run => 1);

    $self->scan();

    my %features;
    my $switches = $self->switches // [];
    for my $switch (@{$switches}) {
        next if $switch =~ m/\s*-w\s*/;

        # Cannot use fork/preload with switches other than -w
        $features{fork} = 0;
        $features{preload} = 0;
    }

    # No forking/preloading if non-perl
    if ($self->non_perl || $self->is_binary) {
        $features{fork} = 0;
        $features{preload} = 0;
    }

    return $self->{+TEST_SETTINGS} = Test2::Harness::TestSettings->new(
        use_fork    => ($features{fork}    // $self->check_feature(fork    => 1)),
        use_preload => ($features{preload} // $self->check_feature(preload => 1)),
        use_stream  => ($features{stream}  // $self->check_feature(stream  => 1)),
        use_timeout => ($features{timeout} // $self->check_feature(timeout => 1)),

        ch_dir            => $self->ch_dir,
        event_timeout     => $self->event_timeout,
        post_exit_timeout => $self->post_exit_timeout,
        retry_isolated    => $self->retry_isolated,
        retry             => $self->retry,
        switches          => $switches,
    );
}

my %RANK = (
    smoke      => 1,
    immiscible => 10,
    long       => 20,
    medium     => 50,
    short      => 80,
    isolation  => 100,
);

sub rank {
    my $self = shift;

    return $RANK{smoke} if $self->check_feature('smoke');

    my $rank = $RANK{$self->check_category};
    $rank ||= $RANK{$self->check_duration};
    $rank ||= 1;

    return $rank;
}

sub TO_JSON {
    my $self = shift;
    return { %$self };
}

sub process_info {
    my $self = shift;

    my $out = $self->TO_JSON;

    delete $out->{+TEST_SETTINGS};

    delete $out->{$_} for grep { m/^_/ } keys %$out;

    return $out;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::TestFile - FIXME

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

