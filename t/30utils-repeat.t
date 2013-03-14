#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Identity;

use Future;
use Future::Utils qw( repeat repeat_until_success );

{
   my $trial_f;
   my $previous_trial;
   my $arg;
   my $again;
   my $future = repeat {
      $previous_trial = shift;
      return $trial_f = Future->new
   } while => sub { $arg = shift; $again };

   ok( defined $future, '$future defined for repeat while' );

   ok( defined $trial_f, 'An initial future is running' );

   my $first_f = $trial_f;

   $again = 1;
   $trial_f->done( "one" );

   ok( defined $arg, '$arg defined for while test' );
   is( scalar $arg->get, "one", '$arg->get for first' );

   identical( $previous_trial, $first_f, 'code block is passed previous trial' );

   $again = 0;
   $trial_f->done( "two" );

   ok( $future->is_ready, '$future is now ready after second attempt ->done' );
   is( scalar $future->get, "two", '$future->get' );
}

{
   my @running; my $i = 0;
   my $future = repeat {
      return $running[$i++] = Future->new
   } while => sub { 1 };

   ok( defined $future, '$future defined for repeat while' );

   ok( defined $running[0], 'An initial future is running' );

   $running[0]->done;

   $future->cancel;

   ok( $running[1]->is_cancelled, 'running future cancelled after eventual is cancelled' );
   ok( !$running[0]->is_cancelled, 'previously running future not cancelled' );
}

{
   my $trial_f;
   my $arg;
   my $accept;
   my $future = repeat {
      return $trial_f = Future->new
   } until => sub { $arg = shift; $accept };

   ok( defined $future, '$future defined for repeat until' );

   ok( defined $trial_f, 'An initial future is running' );

   $accept = 0;
   $trial_f->done( "three" );

   ok( defined $arg, '$arg defined for while test' );
   is( scalar $arg->get, "three", '$arg->get for first' );

   $accept = 1;
   $trial_f->done( "four" );

   ok( $future->is_ready, '$future is now ready after second attempt ->done' );
   is( scalar $future->get, "four", '$future->get' );
}

{
   my $attempt = 0;
   my $future = repeat_until_success {
      if( ++$attempt < 3 ) {
         return Future->new->fail( "Too low" );
      }
      else {
         return Future->new->done( $attempt );
      }
   };

   ok( $future->is_ready, '$future is now ready for repeat_until_success' );
   is( scalar $future->get, 3, '$future->get' );
}

done_testing;
