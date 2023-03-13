package Test2::Harness::UI::UUID;
use strict;
use warnings;

use overload(
    fallback => 1,
    '""' => sub { $_[0]->magic_stringify },
    bool => sub { 1 },
);

use Data::UUID;
use Scalar::Util qw/blessed reftype/;
use Test2::Harness::Util qw/looks_like_uuid/;
use Test2::Harness::Util::UUID qw/UG/;

require Test2::Harness::Util::UUID;
require bytes;

use Importer Importer => 'import';
our @EXPORT_OK = qw/uuid_inflate uuid_deflate gen_uuid uuid_mass_inflate uuid_mass_deflate looks_like_uuid_36_or_16/;

sub gen_uuid {
    my $binary = UG()->create();
    my $forsql = _reorder_bin($binary);
    my $string = UG()->to_string($binary);

    return bless(
        {
            binary => $forsql,
            string => lc($string),
        },
        __PACKAGE__
    );
}

sub new {
    my $class = shift;
    my ($val) = @_;
    $val //= lc(Test2::Harness::Util::UUID::gen_uuid());
    return uuid_inflate($val);
}

sub _reorder_bin {
    my $bin = shift;

    return join '' => (
        scalar(reverse(substr($bin, 6, 2))),
        scalar(reverse(substr($bin, 4, 2))),
        scalar(reverse(substr($bin, 0, 4))),
        substr($bin, 8, 8),
    );
}

sub _unorder_bin {
    my ($bin) = @_;

    return join '' => (
        scalar(reverse(substr($bin, 4, 4))),
        scalar(reverse(substr($bin, 2, 2))),
        scalar(reverse(substr($bin, 0, 2))),
        substr($bin, 8, 8),
    );
}

sub uuid_inflate {
    my ($val) = @_;
    return undef unless $val;
    return $val if blessed($val) && $val->isa(__PACKAGE__);

    my $size = bytes::length($val);

    my $out;
    if ($size == 16) {
        my $unbin = UG()->to_string(_unorder_bin($val));

        $out = {
            string => lc($unbin),
            binary => $val,
        };
    }
    elsif ($size == 36) {
        $val = $val;

        my $bin = UG()->from_string($val);

        $out = {
            string => lc($val),
            binary => _reorder_bin($bin),
        };
    }

    return undef unless $out;

    return bless($out, __PACKAGE__);
}

sub magic_stringify {
    my $self = shift;
    return $self->{string} unless $Test2::Harness::UI::Schema::LOADED && $Test2::Harness::UI::Schema::LOADED =~ m/mysql/i;

    my $i = 0;
    while (my @call = caller($i++)) {
        return $self->{binary} if $call[0] =~ m/DBIx::Class::Storage::DBI/;
        return $self->{string} if $i > 2;
    }

    $self->{string};
}

sub uuid_deflate {
    my ($val) = @_;
    return undef unless $val;
    $val = uuid_inflate($val) unless blessed($val) && $val->isa(__PACKAGE__);
    return undef unless $val;
    return $val->{binary} if $Test2::Harness::UI::Schema::LOADED && $Test2::Harness::UI::Schema::LOADED =~ m/mysql/i;
    return $val->{string};
}

*deflate = \&uuid_deflate;
*inflate = \&uuid_inflate;

sub binary { $_[0]->{binary} }
sub string { $_[0]->{string} }
sub TO_JSON { $_[0]->{string} }

sub uuid_mass_inflate { _uuid_mass_flate($_[0], \&uuid_inflate, \&uuid_mass_inflate) }
sub uuid_mass_deflate { _uuid_mass_flate($_[0], \&uuid_deflate, \&uuid_mass_deflate) }

sub _uuid_mass_flate {
    my ($val_do_not_use, $flate, $mass_flate) = @_;
    return $_[0] unless $_[0];

    if (blessed($_[0])) {
        return $_[0] = $flate->($_[0]) if $_[0]->isa(__PACKAGE__);
        return $_[0];
    }

    return $_[0] = $flate->($_[0]) if looks_like_uuid_36_or_16($_[0]);

    my $type = reftype($_[0]) or return;

    if ($type eq 'HASH') {
        my @list = grep {
            my $ok = 1;
            $ok &&= $_ eq 'owner' || (m/_(id|key)$/ && $_ ne 'trace_id');
            $ok &&= looks_like_uuid_36_or_16($_[0]->{$_});

            my $rt = reftype($_[0]->{$_}) // '';
            $ok ||= $rt eq 'HASH' || $rt eq 'ARRAY';

            $ok;
        } keys %{$_[0]};

        $_[0]->{$_} = _uuid_mass_flate($_[0]->{$_}, $flate, $mass_flate) for @list;
    }
    elsif($type eq 'ARRAY') {
        $_ = _uuid_mass_flate($_, $flate, $mass_flate) for grep {
            my $ok = looks_like_uuid_36_or_16($_);

            my $dt = reftype($_) // '';
            $ok ||= 1 if $dt eq 'HASH' || $dt eq 'ARRAY';

            $ok;
        } @{$_[0]};
    }

    return $_[0];
}

sub looks_like_uuid_36_or_16 {
    my ($val) = @_;
    return 0 unless $val;
    my $len = length($val);

    if ($len == 16) {
        return 1 if $val !~ m/^[[:ascii:]]+$/s;
        return 0;
    }
    elsif ($len == 36) {
        return unless $val =~ m/-/;
        return looks_like_uuid($val);
    }

    return 0;
}

1;
