package Plugin;
use strict;
use warnings;

use parent 'App::Yath::Plugin';

sub changed_files {
    return () unless $ENV{TEST_CASE};
    return (['Ax.pm'])                      if $ENV{TEST_CASE} eq 'Ax';
    return (['Bx.pm'])                      if $ENV{TEST_CASE} eq 'Bx';
    return (['Cx.pm'])                      if $ENV{TEST_CASE} eq 'Cx';
    return (['Bx.pm', 'b'])                 if $ENV{TEST_CASE} eq 'Bxb';
    return (['Cx.pm', 'c'])                 if $ENV{TEST_CASE} eq 'Cxc';
    return (['Ax.pm', '*'])                 if $ENV{TEST_CASE} eq 'Ax*';
    return (['Ax.pm', 'a'])                 if $ENV{TEST_CASE} eq 'Axa';
    return (['Ax.pm', 'aa'])                if $ENV{TEST_CASE} eq 'Axaa';
    return (['Ax.pm', 'aa', 'a'])           if $ENV{TEST_CASE} eq 'Axaaa';
    return (['Ax.pm', 'a'], ['Cx.pm', 'c']) if $ENV{TEST_CASE} eq 'AxCx';
    return ();
}

1;
