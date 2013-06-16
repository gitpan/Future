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

   my $f2;
   my $fseq = $f1->and_then( sub { 
      identical( $_[0], $f1, 'and_then block passed $f1' );
      return $f2 = Future->new;
   } );

   ok( defined $fseq, '$fseq defined' );
   isa_ok( $fseq, "Future", '$fseq' );

   # Two refs; one in lexical $fseq, one via $f1
   is_refcount( $fseq, 2, '$fseq has refcount 2 initially' );

   ok( !$f2, '$f2 not yet defined before $f1 done' );

   $f1->done;

   ok( defined $f2, '$f2 now defined after $f1 done' );

   undef $f1;
   is_refcount( $fseq, 2, '$fseq has refcount 2 after $f1 done and dropped' );

   ok( !$fseq->is_ready, '$fseq not yet done before $f2 done' );

   $f2->done( results => "here" );

   ok( $fseq->is_ready, '$fseq is done after $f2 done' );
   is_deeply( [ $fseq->get ], [ results => "here" ], '$fseq->get returns results' );

   undef $f2;
   is_oneref( $fseq, '$fseq has refcount 1 before EOF' );
}

# Failure
{
   my $f1 = Future->new;

   my $fseq = $f1->and_then(
      sub { die "and_then of failed Future should not be invoked" }
   );

   $f1->fail( "A failure\n");

   is( scalar $fseq->failure, "A failure\n", '$fseq fails when $f1 fails' );
}

{
   my $f1 = Future->new;

   my $f2;
   my $fseq = $f1->and_then(
      sub { return $f2 = Future->new }
   );

   $f1->done;
   $f2->fail( "Another failure\n" );

   is( scalar $fseq->failure, "Another failure\n", '$fseq fails when $f2 fails' );
}

# code dies
{
   my $f1 = Future->new;

   my $fseq = $f1->and_then( sub {
      die "It fails\n";
   } );

   ok( !defined exception { $f1->done }, 'exception not propagated from code call' );

   ok( $fseq->is_ready, '$fseq is ready after code exception' );
   is( scalar $fseq->failure, "It fails\n", '$fseq->failure after code exception' );
}

# Cancellation
{
   my $f1 = Future->new;

   my $fseq = $f1->and_then(
      sub { die "and_then of cancelled Future should not be invoked" }
   );

   $fseq->cancel;

   ok( $f1->is_cancelled, '$f1 cancelled by $fseq cancel' );
}

{
   my $f1 = Future->new;

   my $f2;
   my $fseq = $f1->and_then(
      sub { return $f2 = Future->new }
   );

   $f1->done;
   $fseq->cancel;

   ok( $f2->is_cancelled, '$f2 cancelled by $fseq cancel' );
}

# immediately done
{
   my $f1 = Future->new->done;

   my $called = 0;
   my $fseq = $f1->and_then(
      sub { $called++; return $_[0] }
   );

   is( $called, 1, 'and_then block invoked immediately for already-done' );
}

# immediately done
{
   my $f1 = Future->new->done("Result");

   my $f2;
   my $fseq = $f1->and_then(
      sub { return $f2 = Future->new }
   );

   ok( defined $f2, '$f2 defined for already-done' );

   $f2->done("Final");
   ok( $fseq->is_ready, '$fseq already ready for already-done' );
   is( scalar $fseq->get, "Final", '$fseq->get for already-done' );
}

{
   my $f1 = Future->new->fail("Failure\n");

   my $called = 0;
   my $fseq = $f1->and_then(
      sub { $called++; return $_[0] }
   );

   is( $called, 0, 'and_then block not invoked for already-failed' );
   ok( $fseq->is_ready, '$fseq already ready for already-failed' );
}

# Void context raises a warning
{
   warnings_are {
      Future->new->done->and_then(
         sub { Future->new }
      );
   } "Calling ->and_then in void context",
      'Warning in void context';
}

# Non-Future return raises exception
{
   my $f1 = Future->new;

   my $file = __FILE__;
   my $line = __LINE__+1;
   my $fseq = $f1->and_then( sub {} );

   like( exception { $f1->done },
       qr/^Expected code to return a Future in and_then at \Q$file\E line $line\.?/,
       'Exception from non-Future return' );
}

done_testing;