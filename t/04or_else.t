#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Identity;
use Test::Refcount;

use Future;

# Success
{
   my $f1 = Future->new;

   my $fseq = $f1->or_else(
      sub { die "or_else of failed Future should not be invoked" }
   );

   ok( defined $fseq, '$fseq defined' );
   isa_ok( $fseq, "Future", '$fseq' );

   # Two refs; one in lexical $fseq, one via $f1
   is_refcount( $fseq, 2, '$fseq has refcount 2 initially' );

   $f1->done( results => "here" );

   is_deeply( [ $fseq->get ], [ results => "here" ], '$fseq succeeds when $f1 succeeds' );

   undef $f1;
   is_oneref( $fseq, '$fseq has refcount 1 before EOF' );
}

# First failure
{
   my $f1 = Future->new;

   my $f2;
   my $fseq = $f1->or_else( sub { 
      identical( $_[0], $f1, 'or_else block passed $f1' );
      return $f2 = Future->new;
   } );

   ok( !$f2, '$f2 not yet defined before $f1 done' );

   $f1->fail( "Broken\n" );

   ok( defined $f2, '$f2 now defined after $f1 fails' );

   undef $f1;
   is_refcount( $fseq, 2, '$fseq has refcount 2 after $f1 done and dropped' );

   ok( !$fseq->is_ready, '$fseq not yet done before $f2 done' );

   $f2->done( results => "here" );

   ok( $fseq->is_ready, '$fseq is done after $f2 done' );
   is_deeply( [ $fseq->get ], [ results => "here" ], '$fseq->get returns results' );

   undef $f2;
   is_oneref( $fseq, '$fseq has refcount 1 before EOF' );
}

{
   my $f1 = Future->new;

   my $f2;
   my $fseq = $f1->or_else(
      sub { return $f2 = Future->new }
   );

   $f1->fail( "First failure\n" );
   $f2->fail( "Another failure\n" );

   is( scalar $fseq->failure, "Another failure\n", '$fseq fails when $f2 fails' );
}

# Cancellation
{
   my $f1 = Future->new;

   my $fseq = $f1->or_else(
      sub { die "or_else of cancelled Future should not be invoked" }
   );

   $fseq->cancel;

   ok( $f1->is_cancelled, '$f1 cancelled by $fseq cancel' );
}

{
   my $f1 = Future->new;

   my $f2;
   my $fseq = $f1->or_else(
      sub { return $f2 = Future->new }
   );

   $f1->fail( "First failure\n" );
   $fseq->cancel;

   ok( $f2->is_cancelled, '$f2 cancelled by $fseq cancel' );
}

# immediately done
{
   my $f1 = Future->new->done;

   my $called = 0;
   my $fseq = $f1->or_else(
      sub { $called++; return $_[0] }
   );

   is( $called, 0, 'or_else block not invoked for already-done' );
   ok( $fseq->is_ready, '$fseq already ready for already-done' );
}

# immediately done
{
   my $f1 = Future->new->fail("Failure\n");

   my $called = 0;
   my $fseq = $f1->or_else(
      sub { $called++; return $_[0] }
   );

   is( $called, 1, 'or_else block invoked immediately for already-failed' );
}

done_testing;
