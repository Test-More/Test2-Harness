package Test2::Harness::UI::Controller::Upload;
use strict;
use warnings;

our $VERSION = '0.000028';

use Text::Xslate();

use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Harness::Util qw/open_file/;

use Test2::Harness::UI::Import();
use Test2::Harness::UI::Queries();

use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Upload A Test Log' }

sub handle {
    my $self = shift;

    my $req = $self->request;

    my $res = resp(200);

    my $run_id = $self->process_form($res) if $req->parameters->{action};

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);
    my $user = $req->user;

    if ($req->parameters->{json}) {
        $res->as_json($run_id ? (run_id => $run_id) : ());
        return $res;
    }

    $res->add_css('upload.css');
    $res->add_js('upload.js');

    my $content = $tx->render(
        'upload.tx',
        {
            base_uri => $req->base->as_string,
            single_user => $self->{+CONFIG}->single_user,
            user     => $user,
            projects => Test2::Harness::UI::Queries->new(config => $self->{+CONFIG})->projects,
        }
    );

    $res->raw_body($content);
    return $res;
}

sub process_form {
    my $self = shift;
    my ($res) = @_;

    my $req = $self->{+REQUEST};

    die error(405) unless $req->method eq 'POST';

    unless( 'upload log' eq lc($req->parameters->{action})) {
        return $res->add_error('Invalid Action');
    }

    my $user = $req->user || $self->api_user($req->parameters->{api_key});

    die error(401) unless $user;

    my $file = $req->uploads->{log_file}->filename;
    my $tmp  = $req->uploads->{log_file}->tempname;

    my $project_name = $req->parameters->{project} || return $res->add_error('project is required');
    my $project = $self->schema->resultset('Project')->find_or_create({name => $project_name});

    my $mode  = $req->parameters->{mode}        || 'qvfd';

    return $res->add_error("Unsupported file type, must be .jsonl.bz2, or .jsonl.gz")
        unless $file =~ m/\.jsonl\.(bz2|gz)$/i;
    my $ext = lc($1);

    my ($run_id);
    my $ok = eval {
        my $fh = open_file($tmp, '<', ext => $ext);
        my $header = <$fh>;
        close($fh);

        $run_id = decode_json($header)->{facet_data}->{harness_run}->{run_id};
    };
    return $res->add_error("Error decoding json: $@") unless $ok;

    open(my $fh, '<:raw', $tmp) or die "Could not open uploaded file '$tmp': $!";

    my $run = $self->schema->resultset('Run')->create({
        $run_id ? (run_id => $run_id) : (),
        user_id    => ref($user) ? $user->user_id : 1,
        project_id => $project->project_id,
        mode       => $mode,
        status     => 'pending',

        log_file => {
            name => $file,
            data => do { local $/; <$fh> },
        },
    });

    $res->add_message("Upload Success, added import to queue");
    return $run->run_id;
}

sub api_user {
    my $self = shift;
    my ($key_val) = @_;

    return unless $key_val;

    my $schema = $self->schema;
    my $key = $schema->resultset('ApiKey')->find({value => $key_val})
        or return undef;

    return undef unless $key->status eq 'active';

    return $key->user;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::Upload

=head1 DESCRIPTION

=head1 SYNOPSIS

TODO

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
