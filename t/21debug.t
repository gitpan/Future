#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

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

my $THENLINE;
my $SEQLINE;
like( warnings {
      $LINE = __LINE__; my $f1 = Future->new;
      $THENLINE = __LINE__; my $fseq = $f1->then( sub { } ); undef $fseq;
      $SEQLINE = __LINE__; $f1->done;
   },
   qr/^Future=\S+ was constructed at \Q$0\E line $THENLINE and was lost near \Q$0\E line $SEQLINE before it was ready\.
Future=\S+ \(constructed at \Q$0\E line $LINE\) lost a sequence Future at \Q$0\E line $SEQLINE\.$/,
   'Lost sequence Future raises warning' );

done_testing;
