#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Refcount;

use Future;

# All done
{
   my $f1 = Future->new;
   my $f2 = Future->new;

   my $future = Future->needs_all( $f1, $f2 );
   is_oneref( $future, '$future has refcount 1 initially' );

   # Two refs; one lexical here, one in $future
   is_refcount( $f1, 2, '$f1 has refcount 2 after adding to ->needs_all' );
   is_refcount( $f2, 2, '$f2 has refcount 2 after adding to ->needs_all' );

   my $ready;
   $future->on_ready( sub { $ready++ } );

   ok( !$future->is_ready, '$future not yet ready' );

   $f1->done( one => 1 );
   $f2->done( two => 2 );

   is( $ready, 1, '$future is now ready' );

   ok( $future->is_ready, '$future now ready after f2 ready' );
   is_deeply( [ $future->get ], [ one => 1, two => 2 ], '$future->get after f2 ready' );

   is_refcount( $future, 1, '$future has refcount 1 at end of test' );
   undef $future;

   is_refcount( $f1, 1, '$f1 has refcount 1 at end of test' );
   is_refcount( $f2, 1, '$f2 has refcount 1 at end of test' );
}

# One fails
{
   my $f1 = Future->new;
   my $f2 = Future->new;
   my $c2;
   $f2->on_cancel( sub { $c2++ } );

   my $future = Future->needs_all( $f1, $f2 );

   my $ready;
   $future->on_ready( sub { $ready++ } );

   ok( !$future->is_ready, '$future not yet ready' );

   my $file = __FILE__;
   my $line = __LINE__+1;
   $f1->fail( "It fails" );

   is( $ready, 1, '$future is now ready' );

   ok( $future->is_ready, '$future now ready after f1 fails' );
   is( $future->failure, "It fails at $file line $line\n", '$future->failure yields exception' );
   is( exception { $future->get }, "It fails at $file line $line\n", '$future->get throws exception' );

   is( $c2, 1, 'Unfinished child future cancelled on failure' );

   is_deeply( [ $future->pending_futures ],
              [],
              '$future->pending_futures after $f1 failure' );

   is_deeply( [ $future->ready_futures ],
              [ $f1, $f2 ],
              '$future->ready_futures after $f1 failure' );

   is_deeply( [ $future->done_futures ],
              [],
              '$future->done_futures after $f1 failure' );

   is_deeply( [ $future->failed_futures ],
              [ $f1 ],
              '$future->failed_futures after $f1 failure' );

   is_deeply( [ $future->cancelled_futures ],
              [ $f2 ],
              '$future->cancelled_futures after $f1 failure' );
}

# immediately done
{
   my $f1 = Future->new->done;

   my $future = Future->needs_all( $f1 );

   ok( $future->is_ready, '$future of already-done sub already ready' );
}

# immediately fails
{
   my $f1 = Future->new->fail( "Failure\n" );

   my $future = Future->needs_all( $f1 );

   ok( $future->is_ready, '$future of already-failed sub already ready' );
}

# cancel propagation
{
   my $f1 = Future->new;
   my $c1;
   $f1->on_cancel( sub { $c1++ } );

   my $f2 = Future->new;
   my $c2;
   $f2->on_cancel( sub { $c2++ } );

   my $future = Future->needs_all( $f1, $f2 );

   $f2->done;

   $future->cancel;

   is( $c1, 1,     '$future->cancel marks subs cancelled' );
   is( $c2, undef, '$future->cancel ignores ready subs' );
}

done_testing;
