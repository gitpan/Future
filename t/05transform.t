#!/usr/bin/perl

use strict;

use Test::More;

use Future;

# Result transformation
{
   my $f1 = Future->new;

   my $future = $f1->transform(
      done => sub { result => @_ },
   );

   $f1->done( 1, 2, 3 );

   is_deeply( [ $future->get ], [ result => 1, 2, 3 ], '->transform result' );
}

# Failure transformation
{
   my $f1 = Future->new;

   my $future = $f1->transform(
      fail => sub { "failure\n" => @_ },
   );

   $f1->fail( "something failed\n" );

   is_deeply( [ $future->failure ], [ "failure\n" => "something failed\n" ], '->transform failure' );
}

# Cancellation
{
   my $f1 = Future->new;

   my $cancelled;
   $f1->on_cancel( sub { $cancelled++ } );

   my $future = $f1->transform;

   $future->cancel;
   is( $cancelled, 1, '->transform cancel' );
}

done_testing;