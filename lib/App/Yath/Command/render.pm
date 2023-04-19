package App::Yath::Command::render;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util qw/mod2file/;
use Test2::Harness::Util::JSON qw/decode_json encode_pretty_json/;

use App::Yath::Options;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw{
    +renderers
};

include_options(
    'App::Yath::Options::Debug',
    'App::Yath::Options::Display',
);

option_group {prefix => 'display', category => "Display Options"} => sub {
    option json => (
        type           => 'b',
        default        => 0,
        description    => "Render JSON",
    );

    option json_only => (
        type           => 'b',
        default        => 0,
        description    => "Render JSON only",
    );
};

sub internal_only   { 0 }
sub summary         { "Render log files or STDIN" }
sub name            { 'render' }

sub renderers {
    my $self = shift;

    return $self->{+RENDERERS} if $self->{+RENDERERS};

    my $settings = $self->{+SETTINGS};

    return $self->{+RENDERERS} = []
        if $settings->display->json_only;

    my @renderers;

    for my $class (@{$settings->display->renderers->{'@'}}) {
        require(mod2file($class));
        my $args     = $settings->display->renderers->{$class};
        my $renderer = $class->new(@$args, settings => $settings, command_class => ref($self));
        push @renderers => $renderer;
    }

    return $self->{+RENDERERS} = \@renderers;
}

sub run {
    my $self = shift;
    my @files = @{$self->args // []};
    shift @files while @files && $files[0] eq '--';

    my $settings = $self->settings;

    if (@files) {
        for my $file (@files) {
            require Test2::Harness::Util::File::Stream;
            my $stream = Test2::Harness::Util::File::Stream->new(name => $file);
            my @buffer;
            $self->render(sub {
                return shift(@buffer) if @buffer;
                push @buffer => $stream->poll(max => 1);
                return shift(@buffer) if @buffer;
                return ();
            });
        }
    }
    else {
        $self->render(sub { <STDIN> });
    }

    return 0;
}

sub render {
    my $self = shift;
    my ($read) = @_;

    my $dset = $self->settings->display;

    my $renderers = $self->renderers;

    while (my $json = $read->()) {
        my $event = decode_json($json);
        next unless $event;

        if ($dset->json || $dset->json_only) {
            print STDOUT encode_pretty_json($event);
        }

        next if $dset->json_only;
        $_->render_event($event) for @$renderers;
    }
}

1;

__END__

=head1 POD IS AUTO-GENERATED

