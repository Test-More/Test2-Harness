package App::Yath::Util;
use strict;
use warnings;

our $VERSION = '1.000180';

use File::Spec;
use Sys::Hostname qw/hostname/;

use Test2::Harness::Util qw/clean_path/;
use Test2::Harness::Util::File::JSON;

use Cwd qw/realpath/;
use Importer Importer => 'import';
use Config qw/%Config/;
use Carp qw/croak/;

our @EXPORT_OK = qw{
    find_pfile
    find_in_updir
    is_generated_test_pl
    fit_to_width
    isolate_stdout
    find_yath
};

my @CONFIG_SCRIPT_KEYS = qw{
    bin binexp initialinstalllocation installbin installscript
    installsitebin installsitescript installusrbinperl installvendorbin
    scriptdir scriptdirexp sitebin sitebinexp sitescript sitescriptexp
    vendorbin vendorbinexp
};

sub find_yath {
    return $App::Yath::Script::SCRIPT if defined $App::Yath::Script::SCRIPT;

    my @searched;

    my $script = _find_yath(\@searched);
    return $App::Yath::Script::SCRIPT = $script if $script;

    die _find_yath_error(\@searched);
}

sub _find_yath {
    my ($searched) = @_;

    for my $candidate (_yath_scripts()) {
        my ($script, $need_exec) = @$candidate;

        push @$searched => $script;
        next unless -f $script && -r _;
        next if $need_exec && !-x _;

        return clean_path($script);
    }

    return undef;
}

# Callers run the script as an argument to perl, so it only needs to be
# readable. PATH is the exception: a yath without the exec bit is not the
# command someone typing 'yath' would get.
sub _yath_scripts {
    my @scripts;

    # Set by the yath script itself, so it names the script running this
    # process tree. Under a yath run this is also how a checkout's own script
    # gets here: App::Yath::Script re-execs into an executable './scripts/yath'
    # when the current directory has one, and that script sets this to itself.
    push @scripts => [$ENV{YATH_SCRIPT}, 0] if $ENV{YATH_SCRIPT};

    push @scripts => map { [File::Spec->catfile($_, 'yath'), 0] } _yath_script_dirs();
    push @scripts => map { [File::Spec->catfile($_, 'yath'), 1] } File::Spec->path();

    my %seen;
    return grep { !$seen{$_->[0]}++ } @scripts;
}

sub _yath_script_dirs {
    my @dirs;

    # An uninstalled dist is never in a Config path, so it comes first.
    push @dirs => _yath_dirs_from_inc(qr{^(.*)[/\\]blib[/\\](?:lib|arch)$}, 'blib', 'script');

    push @dirs => grep { $_ } @Config{@CONFIG_SCRIPT_KEYS};

    # A guess at the layout, so it comes after anything authoritative.
    push @dirs => _yath_dirs_from_inc(qr{^(.*)[/\\]lib[/\\]perl5(?:[/\\][^/\\]+)*$}, 'bin');

    my %seen;
    return grep { $_ && !$seen{$_}++ } @dirs;
}

# The script may live next to the libs it belongs to without ever being
# installed. CPAN smokers do this: they add each prerequisite's uninstalled
# '<build>/blib/lib' to PERL5LIB, leaving the script in '<build>/blib/script'.
# local::lib and 'cpanm -l' trees pair '<base>/lib/perl5' with '<base>/bin'.
sub _yath_dirs_from_inc {
    my ($pattern, @subdirs) = @_;

    my @dirs;
    for my $inc (@INC) {
        next if ref $inc;
        next unless $inc =~ $pattern;

        push @dirs => File::Spec->catdir($1, @subdirs);
    }

    return @dirs;
}

# Failing to find the script is nearly always an environment we have not
# taught find_yath about yet. Dump everything needed to teach it.
sub _find_yath_error {
    my ($searched) = @_;

    my $msg = "Could not find the yath script.\n";

    $msg .= "Searched:\n";
    $msg .= "  $_\n" for @$searched;

    my @mods = grep { -f File::Spec->catfile($_, 'App', 'Yath', 'Script.pm') } grep { !ref $_ } @INC;
    $msg .= "App::Yath::Script loaded from: " . ($INC{'App/Yath/Script.pm'} // '(not loaded)') . "\n";
    $msg .= "App::Yath::Script found in: " .    (@mods ? join(', ' => @mods) : '(nowhere in @INC)') . "\n";

    # Some candidates are relative to the current directory, so it is needed to
    # make sense of them.
    $msg .= "Cwd: " . clean_path('.') . "\n";
    $msg .= "PATH: " .     ($ENV{PATH}     // '(not set)') . "\n";
    $msg .= "PERL5LIB: " . ($ENV{PERL5LIB} // '(not set)') . "\n";

    $msg .= "\@INC:\n";
    $msg .= "  $_\n" for grep { !ref $_ } @INC;

    $msg .= "Please report this at https://github.com/Test-More/Test2-Harness/issues along with the output above.\n";

    return $msg;
}

sub isolate_stdout {
    # Make $fh point at STDOUT, it is our primary output
    open(my $fh, '>&', STDOUT) or die "Could not clone STDOUT: $!";
    select $fh;
    $| = 1;

    # re-open STDOUT redirected to STDERR
    open(STDOUT, '>&', STDERR) or die "Could not redirect STDOUT to STDERR: $!";
    select STDOUT;
    $| = 1;

    # Yes, we want to keep STDERR selected
    select STDERR;
    $| = 1;

    return $fh;
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


sub find_in_updir {
    my $path = shift;
    return clean_path($path) if -f $path;

    my %seen;
    while(1) {
        $path = File::Spec->catdir('..', $path);
        my $check = eval { realpath(File::Spec->rel2abs($path)) };
        last unless $check;
        last if $seen{$check}++;
        return $check if -f $check;
    }

    return;
}

sub _find_pfile {
    my ($settings, %params) = @_;

    croak "Settings is a required argument" unless $settings;

    # First do the entire search without vivify
    if ($params{vivify}) {
        my $found = find_pfile($settings, %params, vivify => 0);
        return $found if $found;
    }

    my $yath = $settings->harness;

    if (my $pfile = $yath->persist_file) {
        return $pfile if -f $pfile || $params{vivify};

        return; # Specified, but not found and no vivify
    }

    my $basename = "yath-persist.json";
    my $user     = $ENV{USER};
    my $hostname = hostname();
    my $project  = $yath->project;

    my @names = ($basename);
    @names = (@names, map { "$project-$_" } @names) if $project;
    @names = (@names, map { "$hostname-$_" } @names) if $hostname;
    @names = (@names, map { "$user-$_" } @names) if $user;
    @names = reverse map { ".$_" } @names;

    my $set_dir = $yath->persist_dir // $ENV{YATH_PERSISTENCE_DIR};
    my $dir = $set_dir // $ENV{TMPDIR} // $ENV{TEMPDIR} // File::Spec->tmpdir;

    # If a dir was specified, or if the current dir is not writable then we must use $dir/$name
    if ($project || $set_dir || !-w '.') {
        for my $name (@names) {
            my $pfile = clean_path(File::Spec->catfile($dir, $name));
            return $pfile if -f $pfile;
        }

        return clean_path(File::Spec->catfile($dir, $names[0])) if $params{vivify};
        return; # Not found
    }

    # Fall back to using the current dir (which must be writable)
    for my $name (@names) {
        my $pfile = find_in_updir($name);
        return $pfile if $pfile && -f $pfile;
    }

    # Creating it here!
    return clean_path(File::Spec->catfile('.', $names[0])) if $params{vivify};

    # Nope, nothing.
    return;
}

sub fit_to_width {
    my ($width, $join, $text) = @_;

    my @parts = ref($text) ? @$text : split /\s+/, $text;

    my @out;

    my $line = "";
    for my $part (@parts) {
        my $new = $line ? "$line$join$part" : $part;

        if ($line && length($new) > $width) {
            push @out => $line;
            $line = $part;
        }
        else {
            $line = $new;
        }
    }
    push @out => $line if $line;

    return join "\n" => @out;
}

my $SEEN_ERROR = 0;
sub find_pfile {
    my ($settings, %params) = @_;
    my $pfile = _find_pfile($settings, %params) or return;

    return $pfile unless -e $pfile;
    return $pfile if $params{no_checks};
    return $pfile if $SEEN_ERROR;

    my $data = Test2::Harness::Util::File::JSON->new(name => $pfile)->read();

    $data->{version}  //= '';
    $data->{hostname} //= '';
    $data->{user}     //= '';
    $data->{pid}      //= '';
    $data->{dir}      //= '';

    my $hostname = hostname();
    my $user = $ENV{USER};

    my @bad;

    push @bad => "** Version mismatch, persistent runner is version $data->{version}, current is version $VERSION. **"
        if $data->{version} ne $VERSION;

    push @bad => "** Hostname mismatch, persistent runner hostname is '$data->{hostname}', current hostname is '$hostname'. **"
        if $data->{hostname} ne $hostname;

    push @bad => "** User mismatch, persistent runner user is '$data->{user}', current user is '$user'. **"
        if $data->{user} ne $user;

    push @bad => "** Workdir missing, persistent runner is supposed to be at '$data->{dir}', but it does not exist. **"
        unless -d $data->{dir};

    push @bad => "** PID not running, persistent runner is supposed to be running with PID '$data->{pid}', but it is not. **"
        unless kill(0, $data->{pid});

    return $pfile unless @bad;

    my $break = ('=' x 120) . "\n";
    my $msg = join "\n" => $break, @bad, <<"    EOT", $break;

Errors like this usually indicate that the persistent runner has gone away.
Maybe the system was shut down improperly, or maybe the process was killed too
quickly to clean up after itself.

Here is the information indicated by the persistence file:
  Runner PID:  $data->{pid}
  Runner Vers: $data->{version}
  Runner user: $data->{user}
  Runner host: $data->{hostname}
  Working dir: $data->{dir}

If the persistent runner is truly gone you should delete the following file to
continue:

$pfile
    EOT

    $SEEN_ERROR = 1;
    die $msg unless $params{no_fatal};
    warn $msg unless $params{no_warn};
    return $pfile;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Util - General utilities for yath that do not fit anywhere else.

=head1 DESCRIPTION

This package exports several tools used throughout yath that did not fit into
any other package.

=head1 SYNOPSIS

    use App::Yath::Util qw{
        find_pfile
        find_in_updir
        is_generated_test_pl
        fit_to_width
        isolate_stdout
        find_yath
    };

=head1 EXPORTS

Note that nothing is exported by default, you must request each function to
import.

=over 4

=item $path_to_pfile = find_pfile($settings, %params)

The first argument must be an instance of L<Test2::Harness::Settings>.

Currently the only supported param is C<vivify>, when set to true the pfile
will be created if one does not already exist.

The pfile is a file that tells yath that a persistent runner is active, and how
to communicate with it.

=item $path_to_file = find_in_updir($file_name)

Look for C<$file_name> in the current directory or any parent directory.

=item $bool = is_generated_test_pl($path_to_test_file)

Check if the specified test file was generated by the C<yath init> command.

=item fit_to_width($width, $join, $text)

This will split the C<$text> on space, and then recombine it using C<$join>
inserting newlines as necessary in an attempt to fit the text into C<$width>
horizontal characters. If any words are larger than C<$width> they will not be
split and text-wrapping may occur if used for terminal display.

=item $stdout = isolate_stdout()

This will close STDOUT and reopen it to point at STDERR. The result of this is
that any print statement that does not specify a filehandle will print to
STDERR instead of STDOUT, in addition any print directly to STDOUT will instead
go to STDERR. A filehandle to the real STDOUT is returned for you to use when
you actually want to write to STDOUT.

This is used by some yath processes that need to print structured data to
STDOUT without letting any third part modules they may load write to the real
STDOUT.

=item $path_to_script = find_yath()

This will attempt to find the C<yath> command line script. When possible this
will return the path that was used to launch yath. If
C<$App::Yath::Script::SCRIPT> is not set the following are searched, in order:

=over 8

=item The C<YATH_SCRIPT> environment variable

The yath script sets this, so it identifies the script that launched the
current process tree. Under a yath run this also covers a checkout's own
script: L<App::Yath::Script> re-execs into an executable C<./scripts/yath> of
its own accord when the current directory has one, and the script it re-execs
into sets this variable to itself.

=item C<< <base>/blib/script >> for any C<< <base>/blib/lib >> or C<< <base>/blib/arch >> in C<@INC>

This finds the script when the L<App::Yath::Script> distribution is being used
uninstalled from its build directory, as CPAN smokers do.

=item The paths specified in the L<Config> module

=item C<< <base>/bin >> for any C<< <base>/lib/perl5 >> in C<@INC>

Anything after C<lib/perl5> is ignored, so
C<< <base>/lib/perl5/5.36.0/x86_64-linux >> also gives C<< <base>/bin >>. This
finds the script in a L<local::lib> or C<cpanm -l> tree.

=item The C<PATH> environment variable

=back

Every candidate but the C<PATH> ones only needs to be readable, because the
script is run as an argument to perl rather than executed. A candidate found
via C<PATH> must also be executable.

This will throw an exception if the script cannot be found. The exception lists
every path that was checked, along with the current directory, C<@INC>, C<PATH>,
and C<PERL5LIB>, so the missing case can be reported.

Note: The result is cached so that subsequent calls will return the same path
even if something installs a new yath script in another location that would
otherwise be found first. This guarantees that a single process will not switch
scripts.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
