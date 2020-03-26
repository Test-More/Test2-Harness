package Test2::Harness::UI::Controller::User;
use strict;
use warnings;

our $VERSION = '0.000028';

use Text::Xslate();
use Test2::Harness::UI::Util qw/share_dir/;
use Test2::Harness::UI::Response qw/resp error/;

use Email::Sender::Simple qw(sendmail);
use Email::Simple;
use Email::Simple::Creator;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase qw/-title/;

sub handle {
    my $self = shift;

    my $req = $self->{+REQUEST};

    my $res = resp(200);
    $res->add_css('user.css');
    $self->process_form($res) if keys %{$req->parameters};

    my $user = $req->user;

    unless($user) {
        $res->raw_body($self->login());
        return $res;
    }

    $self->{+TITLE} = 'User Settings';

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);
    my $sort_val = {active => 1, disabled => 2, revoked => 3};
    my $content = $tx->render(
        'user.tx',
        {
            base_uri => $req->base->as_string,
            user     => $user,
            keys     => [sort { $sort_val->{$a->status} <=> $sort_val->{$b->status} } $user->api_keys->all],
            emails   => [sort { $b->is_primary <=> $a->is_primary || $a->domain cmp $b->domain || $a->local cmp $b->local } $user->emails],
            perms    => [sort { $a->project->name cmp $b->project->name } $user->permissions],
        }
    );

    $res->raw_body($content);
    return $res;
}

my %KEY_ACTION_MAP = (enable => 'active', disable => 'disabled', revoke => 'revoked');
sub process_form {
    my $self = shift;
    my ($res) = @_;

    my $req    = $self->{+REQUEST};
    my $schema = $self->schema;

    my $p = $req->parameters;

    my $action = lc($p->{action} || '');

    # This one we allow non-post, all others need post.
    if ('logout' eq $action) {
        $req->session_host->update({'user_id' => undef});
        return $res->add_msg("You have been logged out.");
    }
    elsif ($action eq 'verify') {
        my $evcode_id = $p->{verification_code}
            or return $res->add_error("Invalid verification code");

        my $code = $schema->resultset('EmailVerificationCode')->find({evcode_id => $evcode_id})
            or return $res->add_error("Invalid verification code");

        my $email = $code->email;
        $email->update({verified => 1});

        $code->delete();

        return $res->add_msg("Email address verified");
    }

    die error(405) unless $req->method eq 'POST';

    if ('login' eq $action) {
        my $username = $p->{username} or return $res->add_error("username is required");
        my $password = $p->{password} or return $res->add_error("password is required");

        my $user = $schema->resultset('User')->find({username => $username});

        return $res->add_error("Invalid username or password")
            unless $user && $user->verify_password($password);

        $req->session_host->update({'user_id' => $user->user_id});
        return $res->add_msg("You have been logged in.");
    }

    if ('add email' eq $action) {
        my $user = $req->user or return $res->add_error("You must be logged in");

        my $addr = $p->{new_email} // '';
        return $res->add_error("Invalid Email")
            unless $addr =~ m/^(.+)@(.+\..+)$/;

        my ($local, $domain) = ($1, $2);

        if ($schema->resultset('Email')->find({local => $local, domain => $domain})) {
            return $res->add_error("This email is already in use.");
        }

        my $email = eval { $schema->resultset('Email')->create({user_id => $user->user_id, local => $local, domain => $domain}) };
        $res->add_error("Unable to add email: $@") unless $email;

        $self->send_verification_code($email);

        return $res->add_msg("Email '$local\@$domain' added, please check your email for the verification code");
    }

    if ('generate key' eq $action) {
        my $key_name = $p->{key_name} or return $res->add_error("a key name is required");
        my $user = $req->user or return $res->add_error("You must be logged in");

        my $key = $user->gen_api_key($key_name);

        return $res->add_msg("Key '$key_name' generated: " . $key->value);
    }


    if ('change password' eq $action) {
        my $user = $req->user or return $res->add_error("You must be logged in");
        my $old_password = $p->{old_password} or return $res->add_error("current password is required");
        my $new_password_1 = $p->{new_password_1} or return $res->add_error("new password is required");
        my $new_password_2 = $p->{new_password_2} or return $res->add_error("new password (again) is required");

        return $res->add_error("New password fields do not match")
            unless $new_password_1 eq $new_password_2;

        return $res->add_error("Incorrect password") unless $user->verify_password($old_password);

        $user->set_password($new_password_1);

        return $res->add_msg("Password Changed.");
    }

    if ($p->{api_key_id} && $KEY_ACTION_MAP{$action}) {
        my $key_id = $p->{api_key_id};
        my $user = $req->user or return $res->add_error("You must be logged in");

        my $key = $schema->resultset('ApiKey')->find({api_key_id => $key_id, user_id => $user->user_id});
        return $res->add_error("Invalid key") unless $key;

        $key->update({status => $KEY_ACTION_MAP{$action}});
        return $res->add_msg("Key status changed.");
    }

    if ($p->{email_id}) {
        my $user = $req->user or return $res->add_error("You must be logged in");
        my $email = $schema->resultset('Email')->find({email_id => $p->{email_id}, user_id => $user->user_id});
        return $res->add_error("Invalid Email") unless $email;

        if ($action eq 'make primary') {
            my $pri = $schema->resultset('PrimaryEmail')->update_or_create({user_id => $user->user_id, email_id => $p->{email_id}});
            return $res->add_error("Could not make email primary: $@") unless $pri;
            return $res->add_msg("Set primary email address.");
        }
        elsif ($action eq 'delete') {
            $email->delete();
            return $res->add_msg("Email address deleted");
        }
        elsif ($action eq 'send verification code') {
            my $code = $self->send_verification_code($email);
            return $res->add_msg("Verification code sent");
        }
    }

    return $res->add_error("Invalid form submission");
}

sub login {
    my $self = shift;

    $self->{+TITLE} = 'Login';

    my $tx = Text::Xslate->new(path => [share_dir('templates')]);
    return $tx->render(
        'login.tx',
        {
            base_uri => $self->{+REQUEST}->base->as_string,
        }
    );
}

sub send_verification_code {
    my $self = shift;
    my ($email) = @_;

    my $schema = $self->schema;

    my $code = $schema->resultset('EmailVerificationCode')->find_or_create({email_id => $email->email_id});
    my $text = $code->evcode_id;

    my $config = $self->{+CONFIG};

    my $msg = Email::Simple->create(
        header => [
            To      => $email->address,
            From    => $config->email,
            Subject => "Email verification code",
        ],
        body => "Verification code: $text\n",
    );

    sendmail($msg);

    return $code;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Controller::User

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
