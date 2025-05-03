package App::Yath::Renderer::DB;
use strict;
use warnings;

our $VERSION = '2.000005';

# This module does not directly use these, but the process it spawns does. Load
# them here anyway so that any errors can be reported before we fork.
use Getopt::Yath::Settings;
use App::Yath::Schema::RunProcessor;
use Consumer::NonBlock;
use App::Yath::Schema::Util;

use Atomic::Pipe;
use YAML::Tiny;

use Time::HiRes qw/time/;

use Test2::Harness::Util qw/clean_path find_in_updir/;
use Test2::Harness::IPC::Util qw/start_process/;
use Test2::Harness::Util::JSON qw/encode_json_file encode_json decode_json_file/;
use Test2::Util::UUID qw/gen_uuid/;

use parent 'App::Yath::Renderer';
use Test2::Harness::Util::HashBase qw{
    <pid
    <writer
    <stopped
};

use Getopt::Yath;

include_options(
    'App::Yath::Options::Yath',
    'App::Yath::Options::DB',
    'App::Yath::Options::Publish',
    'App::Yath::Options::WebClient' => [qw/url/],
);

option_post_process 1000 => sub {
    my ($options, $state) = @_;
    my $settings = $state->{settings};

    return if $settings->yath->project;

    my $project;

    if (my $meta_json = find_in_updir('META.json')) {
        my $json = decode_json_file($meta_json);
        $project = $json->{name};
    }
    elsif (my $meta_yml = find_in_updir('META.yml')) {
        my $yml = YAML::Tiny->read($meta_yml) or die "Could not read '$meta_yml'";
        $project = $yml->[0]->{name};
    }
    elsif (my $dist_ini = find_in_updir('dist.ini')) {
        open(my $fh, '<', $dist_ini) or die "Could not open '$dist_ini': $!";
        while (my $line = <$fh>) {
            next unless $line =~ m/^name\s*=\s*(.*)$/;
            $project = $1;
            last;
        }
    }
    else {
        for my $sc ('.git', '.svn','.cvs') {
            my $path = find_in_updir($sc) or next;

            $path = clean_path($path);
            $path =~ m{([^-/]+)(-\d.*)?/\Q$sc\E$} or next;

            $project = $1;
            last if $project;
        }
    }

    $settings->yath->project($project) if $project;
};


sub init {
    my $self = shift;

    $self->SUPER::init();

    die "Could not determine project, please specify with the --project option.\n"
        unless $self->{+SETTINGS}->yath->project;

}

sub start {
    my $self = shift;

    App::Yath::Schema::Util::schema_config_from_settings($self->{+SETTINGS});

    # Do not use the yath workdir for these things, it will get cleaned up too soon.
    my ($dir) = grep { $_ && -d $_ } '/dev/shm', $ENV{SYSTEM_TMPDIR}, '/tmp', $ENV{TMP_DIR}, $ENV{TMPDIR};
    local $ENV{TMPDIR} = $dir;
    local $ENV{TMP_DIR} = $dir;
    local $ENV{TEMP_DIR} = $dir;

    my ($r, $w) = Consumer::NonBlock->pair(batch_size => 1000, $dir ? (base_dir => $dir) : ());

    $self->{+WRITER} = $w;

    my %seen;
    $self->{+PID} = start_process(
        [
            $^X,                                                       # perl
            (map { ("-I$_") } grep { -d $_ && !$seen{$_}++ } @INC),    # Use the dev libs specified
            "-mApp::Yath::Schema::RunProcessor",                       # Load processor
            "-mGetopt::Yath::Settings",                                # Load settings lib
            '-e' => <<"            EOT",                               # Run it.
exit(
    App::Yath::Schema::RunProcessor->process_csnb(
        Getopt::Yath::Settings->FROM_JSON_FILE(\$ARGV[0], unlink => 1),
    )
);
            EOT
            encode_json_file($self->{+SETTINGS}),                # Pass settings in as arg
        ],
        sub {
            $r->set_env_var;
            $w->weaken;
            $w->close;
        }
    );

    $r->weaken();
    $r->close();

    return;
}

sub render_event {
    my $self = shift;
    my ($e) = @_;

    return if $self->{+STOPPED};

    $self->{+WRITER}->write_line(encode_json($e));

    return;
}

sub signal {
    my $self = shift;
    my ($sig) = @_;

    return if $self->{+STOPPED};

    $self->_stop("SIG$SIG");
    $self->_close();

    kill($sig, $self->{+PID});

    $self->_wait();

    return $sig;
}

sub _stop {
    my $self = shift;
    my ($why) = @_;

    push @{$self->{+STOPPED} //= []} => $why;
}

sub _close {
    my $self = shift;

    my $p = delete $self->{+WRITER} or return;
    $p->close;
}

sub _wait {
    my $self = shift;

    my $pid = delete $self->{+PID} or return;
    waitpid($pid, 0);
}

sub finish {
    my $self = shift;

    $self->_stop('finish');
    $self->_close();
    $self->_wait();

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Renderer::DB - FIXME

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

