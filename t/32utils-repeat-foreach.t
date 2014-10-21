#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use Future;
use Future::Utils qw( repeat repeat_until_success );

# foreach without otherwise
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

# foreach otherwise
{
   my $last_trial_f;
   my $future = repeat {
      Future->new->done( "ignore me $_[0]" );
   } foreach => [qw( one two three )],
     otherwise => sub {
        $last_trial_f = shift;
        return Future->new->fail( "Nothing succeeded\n" );
     };

   is( scalar $future->failure, "Nothing succeeded\n", '$future returns otherwise failure' );
   is( scalar $last_trial_f->get, "ignore me three", '$last_trial_f->get' );

   $future = repeat {
      Future->new->done( "ignore me" );
   } foreach => [],
     otherwise => sub { Future->new->fail( "Nothing to do\n" ) };

   is( scalar $future->failure, "Nothing to do\n", '$future returns otherwise failure for empty list' );
}

# foreach while
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

# foreach until
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

# foreach while + otherwise
{
   my $future = repeat {
      Future->new->done( $_[0] );
   } foreach => [ 1, 2, 3 ],
     while => sub { $_[0]->get < 2 },
     otherwise => sub { Future->new->fail( "Failed to find 2" ) };

   is( scalar $future->get, 2, '$future->get returns successful result from while + otherwise' );
}

# repeat_until_success foreach
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

# main code dies
{
   my $future = repeat {
      die "It failed\n";
   } foreach => [ 1, 2, 3 ];

   is( $future->failure, "It failed\n", 'repeat foreach failure after code exception' );
}

# otherwise code dies
{
   my $future = repeat {
      Future->new->done;
   } foreach => [],
     otherwise => sub { die "It failed finally\n" };

   is( $future->failure, "It failed finally\n", 'repeat foreach failure after otherwise exception' );
}

done_testing;
