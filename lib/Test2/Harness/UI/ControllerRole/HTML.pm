package Test2::Harness::UI::ControllerRole::HTML;
use strict;
use warnings;

use Text::Xslate(qw/mark_raw/);
use Test2::Harness::UI::Util qw/share_dir/;

sub new;
use Test2::Harness::UI::Util::HashBase qw/messages errors/;

use Importer Importer => 'import';

our @EXPORT = qw/wrap_content base_uri add_msg add_error messages errors MESSAGES ERRORS add_message/;

sub base_uri {
    my $self = shift;
    my $req = $self->request;

    return $req->base->as_string;
}

sub wrap_content {
    my $self = shift;
    my ($content) = @_;

    my $template = share_dir('templates/main.tx');

    my $tx = Text::Xslate->new();
    return $tx->render(
        $template, {
            base_uri => $self->base_uri,
            content  => mark_raw($content),
            errors   => $self->{+ERRORS} || [],
            messages => $self->{+MESSAGES} || [],
            title    => $self->title,
            user     => $self->request->user,
        }
    );
}

*add_message = \&add_msg;
sub add_msg {
    my $self = shift;

    push @{$self->{+MESSAGES}} => @_;

    return;
}

sub add_error {
    my $self = shift;

    push @{$self->{+ERRORS}} => @_;

    return;
}


1;
