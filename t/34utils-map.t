#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use Future;
use Future::Utils qw( fmap fmap1 );

# fmap no concurrency
{
   my @subf;
   my $future = fmap {
      return $subf[$_[0]] = Future->new
   } foreach => [ 0 .. 2 ];

   my @results;
   $future->on_done( sub { @results = @_ });

   $subf[0]->done( "A", "B" );
   $subf[1]->done( "C", "D", );
   $subf[2]->done( "E" );

   ok( $future->is_ready, '$future now ready after subs done for fmap' );
   is_deeply( [ $future->get ], [qw( A B C D E )], '$future->get for fmap' );
   is_deeply( \@results,        [qw( A B C D E )], '@results for fmap' );
}

# fmap concurrent
{
   my @subf;
   my $future = fmap {
      return $subf[$_[0]] = Future->new
   } foreach => [ 0 .. 2 ],
     concurrent => 3;

   # complete out of order
   $subf[0]->done( "A", "B" );
   $subf[2]->done( "E" );
   $subf[1]->done( "C", "D" );

   is_deeply( [ $future->get ], [qw( A B C D E )], '$future->get for fmap out of order' );
}

# fmap1 no concurrency
{
   my @subf;
   my $future = fmap1 {
      return $subf[$_[0]] = Future->new
   } foreach => [ 0 .. 2 ];

   my @results;
   $future->on_done( sub { @results = @_ });

   $subf[0]->done( "A" );
   $subf[1]->done( "B" );
   $subf[2]->done( "C" );

   ok( $future->is_ready, '$future now ready after subs done for fmap1' );
   is_deeply( [ $future->get ], [qw( A B C )], '$future->get for fmap1' );
   is_deeply( \@results,        [qw( A B C )], '@results for fmap1' );
}

done_testing;
