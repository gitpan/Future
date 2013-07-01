#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Identity;
use Test::Refcount;
use Test::Warn;

use Future;

{
   my $f1 = Future->new;

   my $called = 0;
   my $fseq = $f1->followed_by( sub {
      $called++;
      identical( $_[0], $f1, 'followed_by block passed $f1' );
      return $_[0];
   } );

   ok( defined $fseq, '$fseq defined' );
   isa_ok( $fseq, "Future", '$fseq' );

   # Two refs; one in lexical $fseq, one via $f1
   is_refcount( $fseq, 2, '$fseq has refcount 2 initially' );
   # Two refs; one in lexical $f1, one in $fseq's cancellation closure
   is_refcount( $f1, 2, '$f1 has refcount 2 initially' );

   is( $called, 0, '$called before $f1 done' );

   $f1->done( results => "here" );

   is( $called, 1, '$called after $f1 done' );

   ok( $fseq->is_ready, '$fseq is done after $f1 done' );
   is_deeply( [ $fseq->get ], [ results => "here" ], '$fseq->get returns results' );

   is_oneref( $fseq, '$fseq has refcount 1 before EOF' );
   is_oneref( $f1, '$f1 has refcount 1 before EOF' );
}

{
   my $f1 = Future->new;

   my $called = 0;
   my $fseq = $f1->followed_by( sub {
      $called++;
      identical( $_[0], $f1, 'followed_by block passed $f1' );
      return $_[0];
   } );

   ok( defined $fseq, '$fseq defined' );
   isa_ok( $fseq, "Future", '$fseq' );

   # Two refs; one in lexical $fseq, one via $f1
   is_refcount( $fseq, 2, '$fseq has refcount 2 initially' );

   is( $called, 0, '$called before $f1 done' );

   $f1->fail( "failure\n" );

   is( $called, 1, '$called after $f1 failed' );

   ok( $fseq->is_ready, '$fseq is ready after $f1 failed' );
   is_deeply( [ $fseq->failure ], [ "failure\n" ], '$fseq->get returns failure' );

   is_oneref( $fseq, '$fseq has refcount 1 before EOF' );
}

# code dies
{
   my $f1 = Future->new;

   my $fseq = $f1->followed_by( sub {
      die "It fails\n";
   } );

   ok( !defined exception { $f1->done }, 'exception not propagated from code call' );

   ok( $fseq->is_ready, '$fseq is ready after code exception' );
   is( scalar $fseq->failure, "It fails\n", '$fseq->failure after code exception' );
}

# Cancellation
{
   my $f1 = Future->new;

   my $fseq = $f1->followed_by(
      sub { die "followed_by of cancelled Future should not be invoked" }
   );

   $fseq->cancel;

   ok( $f1->is_cancelled, '$f1 cancelled by $fseq cancel' );
}

# immediately done
{
   my $f1 = Future->new->done;

   my $called = 0;
   my $fseq = $f1->followed_by(
      sub { $called++; return $_[0] }
   );

   is( $called, 1, 'followed_by block invoked immediately for already-done' );
}

# immediately done
{
   my $f1 = Future->new->fail("Failure\n");

   my $called = 0;
   my $fseq = $f1->followed_by(
      sub { $called++; return $_[0] }
   );

   is( $called, 1, 'followed_by block invoked immediately for already-failed' );
}

# Void context raises a warning
{
   warnings_are {
      Future->new->done->followed_by(
         sub { Future->new }
      );
   } "Calling ->followed_by in void context",
      'Warning in void context';
}

# Non-Future return raises exception
{
   my $f1 = Future->new;

   my $file = __FILE__;
   my $line = __LINE__+1;
   my $fseq = $f1->followed_by( sub {} );

   like( exception { $f1->done },
       qr/^Expected code to return a Future in followed_by at \Q$file\E line $line\.?/,
       'Exception from non-Future return' );
}

done_testing;
