package App::Yath2::TestFile;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec ();
use List::Util qw/any uniq/;

use Test2::Harness2::Util::Directives ();
use Test2::Harness2::Run::Job;

use Object::HashBase qw{
    <absolute
    <relative
    <is_binary
    <non_perl
    <switches
    <category
    <duration
    <stage
    <min_slots
    <max_slots
    <conflicts
    <retry
    <retry_isolated
    <event_timeout
    <post_exit_timeout
    <features
    <meta
    <preload_preferences
    <comment
    +_scanned
    +_shbang
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::TestFile - Producer that scans a test file into a harness job.

=head1 DESCRIPTION

This is the producer side of the test-file story. It investigates a single test
file -- reading its shebang and C<HARNESS2:> directives, detecting binary /
non-perl files -- and turns the result into a final
L<Test2::Harness2::Run::Job>. All the filesystem inspection and directive
parsing lives here, in the C<App::Yath2> namespace; the harness side only ever
sees the finished job (or its serialized form).

Scanning is lazy and idempotent: C<scan> runs once, on demand, and caches.

=head1 SYNOPSIS

    use App::Yath2::TestFile;

    my $tf = App::Yath2::TestFile->new(file => 't/foo.t');
    $tf->scan;

    my $job = $tf->build_job(
        run_uuid => $run_uuid,
        run_ord  => 1,
        job_uuid => $job_uuid,
        job_ord  => 1,
    );

=head1 ATTRIBUTES

Construct with C<file> (or C<absolute>); everything else is populated by
C<scan>. The attributes mirror the scan-derived fields on
L<Test2::Harness2::Run::Job>: C<absolute>, C<relative>, C<is_binary>,
C<non_perl>, C<switches>, C<category>, C<duration>, C<stage>, C<min_slots>,
C<max_slots>, C<conflicts>, C<retry>, C<retry_isolated>, C<event_timeout>,
C<post_exit_timeout>, C<features>, C<meta>, C<preload_preferences>, C<comment>.

=cut

sub init ($self) {
    my $file = delete $self->{file};
    $file //= $self->{+ABSOLUTE} // $self->{+RELATIVE};

    croak "'file' (or 'absolute') is a required attribute"
        unless defined $file && length $file;

    $self->{+ABSOLUTE} //= File::Spec->rel2abs($file);
    $self->{+RELATIVE} //= File::Spec->abs2rel($self->{+ABSOLUTE});

    croak "Invalid test file '$self->{+ABSOLUTE}'" unless -f $self->{+ABSOLUTE};

    # Share the stat cache from the -f check above. A non-empty binary file is
    # a non-perl test that must be executable to run at all.
    if (-B _ && !-z _) {
        $self->{+IS_BINARY} = 1;
        $self->{+NON_PERL}  = 1;
        die "Cannot run binary test file '$self->{+ABSOLUTE}': file is not executable.\n"
            unless -x $self->{+ABSOLUTE};
    }

    $self->{+COMMENT}             //= '#';
    $self->{+SWITCHES}            //= [];
    $self->{+CONFLICTS}           //= [];
    $self->{+FEATURES}            //= {};
    $self->{+META}                //= {};
    $self->{+PRELOAD_PREFERENCES} //= ['<default>'];

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $tf->scan

Read the shebang and C<HARNESS2:> directives from the file and populate the
scan-derived attributes. Idempotent; cached after the first call.

=item $job = $tf->build_job(run_uuid => ..., run_ord => ..., job_uuid => ..., job_ord => ...)

Scan (if needed) and return a L<Test2::Harness2::Run::Job> carrying the
scan-derived state plus the supplied run / job identity. The caller owns the
identity; this object owns the scanned data.

=back

=cut

sub scan ($self) {
    return if $self->{+_SCANNED}++;
    return unless -e $self->{+ABSOLUTE};
    return if $self->{+IS_BINARY};

    my $comment = $self->{+COMMENT} // '#';

    my $parser = Test2::Harness2::Util::Directives->new(comments => [$comment]);
    my $directives_seen;

    open(my $fh, '<', $self->{+ABSOLUTE})
        or croak "open '$self->{+ABSOLUTE}': $!";

    for (my $ln = 1; my $line = <$fh>; $ln++) {
        chomp($line);

        if ($ln == 1 && $line =~ m/^#!/) {
            my $shbang = $self->_parse_shbang($line);
            if ($shbang && %$shbang) {
                $self->{+_SHBANG}  = $shbang;
                $self->{+SWITCHES} = $shbang->{switches} if $shbang->{switches};
                $self->{+NON_PERL} = 1                   if $shbang->{non_perl};
                next;
            }
        }

        next if $line =~ m/^\s*$/;

        if ($line =~ m/^\s*#\s*THIS IS A GENERATED YATH RUNNER TEST/) {
            $self->{+FEATURES}{run} = 0;
            next;
        }

        if ($line =~ m/^\s*\Q$comment\E\s*HARNESS2:/) {
            my $ok = eval { $parser->parse_line($line); 1 };
            unless ($ok) {
                my $err = $@;
                warn "Bad HARNESS2 directive at $self->{+ABSOLUTE} line $ln: $err";
                last;
            }
            $directives_seen = 1;
            next;
        }

        next if $line =~ m/^\s*\Q$comment\E/;
        next if $line =~ m/^\s*(?:use|require|BEGIN|package)\b/;
        last;
    }

    close($fh);

    return unless $directives_seen;

    my $dirs;
    my $ok = eval { $dirs = $parser->finish; 1 };
    unless ($ok) {
        warn "HARNESS2 parser failure in $self->{+ABSOLUTE}: $@";
        return;
    }

    $self->_apply_directives($dirs);

    return;
}

sub build_job ($self, %ids) {
    $self->scan;

    return Test2::Harness2::Run::Job->new(
        %ids,
        absolute            => $self->{+ABSOLUTE},
        relative            => $self->{+RELATIVE},
        is_binary           => $self->{+IS_BINARY} ? 1 : 0,
        non_perl            => $self->{+NON_PERL}  ? 1 : 0,
        switches            => [@{$self->{+SWITCHES}}],
        conflicts           => [@{$self->{+CONFLICTS}}],
        features            => {%{$self->{+FEATURES}}},
        meta                => {%{$self->{+META}}},
        preload_preferences => [@{$self->{+PRELOAD_PREFERENCES}}],
        comment             => $self->{+COMMENT},
        (defined $self->{+CATEGORY}          ? (category          => $self->{+CATEGORY})          : ()),
        (defined $self->{+DURATION}          ? (duration          => $self->{+DURATION})          : ()),
        (defined $self->{+STAGE}             ? (stage             => $self->{+STAGE})             : ()),
        (defined $self->{+MIN_SLOTS}         ? (min_slots         => $self->{+MIN_SLOTS})         : ()),
        (defined $self->{+MAX_SLOTS}         ? (max_slots         => $self->{+MAX_SLOTS})         : ()),
        (defined $self->{+RETRY}             ? (retry             => $self->{+RETRY})             : ()),
        (defined $self->{+RETRY_ISOLATED}    ? (retry_isolated    => $self->{+RETRY_ISOLATED})    : ()),
        (defined $self->{+EVENT_TIMEOUT}     ? (event_timeout     => $self->{+EVENT_TIMEOUT})     : ()),
        (defined $self->{+POST_EXIT_TIMEOUT} ? (post_exit_timeout => $self->{+POST_EXIT_TIMEOUT}) : ()),
    );
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $self->_apply_directives($dirs)

Map the L<Test2::Harness2::Util::Directives> parser output into the scan-derived
slots (slots, duration, category, stage, conflicts, preload, feature, timeout,
retry, meta).

=item $hashref = $self->_parse_shbang($line)

Parse a shebang line into C<{switches => [...], non_perl => 0|1, line => ...}>.

=item $arrayref = $self->_xlate_preload_list($values)

Translate the directive parser's preload values into the internal preference
tokens.

=back

=cut

sub _apply_directives ($self, $dirs) {
    if (my $list = $dirs->{slots}) {
        my ($min, $max) = @$list;
        $self->{+MIN_SLOTS} = $min if defined $min;
        $self->{+MAX_SLOTS} = defined($max) ? $max : $min;
    }

    if (my $list = $dirs->{duration}) {
        $self->{+DURATION} = lc($list->[0]) if defined $list->[0];
    }

    if (my $list = $dirs->{category}) {
        my $val = lc($list->[0] // '');
        if ($val =~ m/^(?:long|medium|short)$/) {
            $self->{+DURATION} = $val;
        }
        elsif (length $val) {
            $self->{+CATEGORY} = $val;
        }
    }

    if (my $list = $dirs->{stage}) {
        $self->{+STAGE} = $list->[0] if defined $list->[0];
    }

    if (my $list = $dirs->{conflicts}) {
        my @prev = @{$self->{+CONFLICTS} || []};
        push @prev, map { lc $_ } @$list;
        $self->{+CONFLICTS} = [uniq @prev];
    }

    if (my $list = $dirs->{preload}) {
        $self->{+PRELOAD_PREFERENCES} = $self->_xlate_preload_list($list);
    }

    # feature / timeout / retry / meta all use dotted keys, so the parser hands
    # back a subtree (hashref). Guard the shape so a mis-typed flat directive
    # (e.g. "feature foo" instead of "feature.foo") warns rather than crashing
    # the whole run.
    if (my $feat = $dirs->{feature}) {
        if (ref($feat) eq 'HASH') {
            for my $name (keys %$feat) {
                my $v   = $feat->{$name}->[-1];
                my $key = $name;
                $key =~ tr/-/_/;
                $self->{+FEATURES}{$key} = $v ? 1 : 0;
            }
        }
        else {
            warn "Ignoring malformed 'feature' directive in $self->{+ABSOLUTE} (expected 'feature.<name>')\n";
        }
    }

    if (my $tt = $dirs->{timeout}) {
        if (ref($tt) eq 'HASH') {
            if (my $list = $tt->{event}) {
                $self->{+EVENT_TIMEOUT} = $list->[-1];
            }
            if (my $list = $tt->{postexit}) {
                $self->{+POST_EXIT_TIMEOUT} = $list->[-1];
            }
        }
        else {
            warn "Ignoring malformed 'timeout' directive in $self->{+ABSOLUTE} (expected 'timeout.event' / 'timeout.postexit')\n";
        }
    }

    if (my $rt = $dirs->{retry}) {
        if (ref($rt) eq 'HASH') {
            if (defined(my $count = ($rt->{count} // [])->[-1])) {
                $self->{+RETRY} = int $count;
            }
            if (defined(my $iso = ($rt->{isolated} // [])->[-1])) {
                $self->{+RETRY} ||= 1 if $iso;
                $self->{+RETRY_ISOLATED} = $iso ? 1 : 0;
            }
        }
        elsif (defined(my $count = $rt->[-1])) {
            # Bare "retry N" -> retry count.
            $self->{+RETRY} = int $count;
        }
    }

    if (my $meta = $dirs->{meta}) {
        if (ref($meta) eq 'HASH') {
            for my $k (keys %$meta) {
                push @{$self->{+META}{lc $k}}, @{$meta->{$k}};
            }
        }
        else {
            warn "Ignoring malformed 'meta' directive in $self->{+ABSOLUTE} (expected 'meta.<key>')\n";
        }
    }

    return;
}

sub _parse_shbang ($self, $line) {
    return {} if !defined $line;

    my %shbang;

    # NOTE: dashes are intentionally included with the switches.
    my $shbang_re = qr{
        ^
          \#!.*perl.*?        # the perl path
          (?: \s (-.+) )?     # the switches, maybe
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

sub _xlate_preload_list ($self, $arr) {
    my @out;
    for my $v (@$arr) {
        if (defined($v) && !ref($v) && $v eq 'default') {
            push @out, '<default>';
        }
        elsif (defined($v) && !ref($v) && $v eq '0') {
            push @out, '<no>';
        }
        else {
            push @out, $v;
        }
    }
    pop @out
        if @out >= 2 && $out[-1] eq '<no>' && $out[-2] eq '<default>';
    return \@out;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
