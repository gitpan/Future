#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use Future;
use Future::Utils qw( repeat repeat_until_success );

{
   my $trial_f;
   my $arg;
   my $future = repeat {
      $arg = shift;
      return $trial_f = Future->new;
   } foreach => [qw( one two three )];

   is( $arg, "one", '$arg one for first iteration' );
   $trial_f->done;

   ok( !$future->is_ready, '$future not ready' );

   is( $arg, "two", '$arg two for second iteration' );
   $trial_f->fail( "failure" );

   ok( !$future->is_ready, '$future not ready' );

   is( $arg, "three", '$arg three for third iteration' );
   $trial_f->done( "result" );

   ok( $future->is_ready, '$future now ready' );
   is( scalar $future->get, "result", '$future->get' );
}

{
   my $future = repeat {
      my $arg = shift;
      if( $arg eq "bad" ) {
         return Future->new->fail( "bad" );
      }
      else {
         return Future->new->done( $arg );
      }
   } foreach => [qw( bad good not-attempted )],
     while => sub { shift->failure };

   is( scalar $future->get, "good", '$future->get returns correct result for foreach+while' );
}

{
   my $future = repeat {
      my $arg = shift;
      if( $arg eq "bad" ) {
         return Future->new->fail( "bad" );
      }
      else {
         return Future->new->done( $arg );
      }
   } foreach => [qw( bad good not-attempted )],
     until => sub { !shift->failure };

   is( scalar $future->get, "good", '$future->get returns correct result for foreach+until' );
}

{
   my $future = repeat_until_success {
      my $arg = shift;
      if( $arg eq "bad" ) {
         return Future->new->fail( "bad" );
      }
      else {
         return Future->new->done( $arg );
      }
   } foreach => [qw( bad good not-attempted )];

   is( scalar $future->get, "good", '$future->get returns correct result for repeat_until_success' );
}

done_testing;
