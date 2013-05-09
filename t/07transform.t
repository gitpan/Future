#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warn;

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

# code dies
{
   my $f1 = Future->new;

   my $future = $f1->transform(
      done => sub { die "It fails\n" },
   );

   $f1->done;

   is_deeply( [ $future->failure ], [ "It fails\n" ], '->transform catches exceptions' );
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

# Void context raises a warning
{
   warnings_are {
      Future->new->done->transform(
         done => sub { }
      );
   } "Calling ->transform in void context";
}

done_testing;
