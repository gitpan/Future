#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;

BEGIN {
   $ENV{PERL_FUTURE_DEBUG} = 1;
}

use Future;

my $LINE;
my $LOSTLINE;

sub warnings(&)
{
   my $code = shift;
   my $warnings = "";
   local $SIG{__WARN__} = sub { $warnings .= shift };
   $code->();
   $LOSTLINE = __LINE__; return $warnings;
}

is( warnings {
      my $f = Future->new;
      $f->done;
   }, "", 'Completed Future does not give warning' );

is( warnings {
      my $f = Future->new;
      $f->cancel;
   }, "", 'Cancelled Future does not give warning' );

like( warnings {
      $LINE = __LINE__; my $f = Future->new;
      undef $f;
   },
   qr/^Future=\S+ was constructed at \Q$0\E line $LINE and was lost near \Q$0\E line $LOSTLINE before it was ready\.$/,
   'Lost Future raises a warning' );
