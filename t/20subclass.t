#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Identity;

# subclass->...
{
   my $f = t::Future::Subclass->new;

   isa_ok( $f->then( sub {} ),
           "t::Future::Subclass",
           '$f->then' );

   isa_ok( $f->else( sub {} ),
           "t::Future::Subclass",
           '$f->and_then' );

   isa_ok( $f->then_with_f( sub {} ),
           "t::Future::Subclass",
           '$f->then_with_f' );

   isa_ok( $f->else_with_f( sub {} ),
           "t::Future::Subclass",
           '$f->else_with_f' );

   isa_ok( $f->followed_by( sub {} ),
           "t::Future::Subclass",
           '$f->followed_by' );

   isa_ok( $f->and_then( sub {} ),
           "t::Future::Subclass",
           '$f->and_then' );

   isa_ok( $f->or_else( sub {} ),
           "t::Future::Subclass",
           '$f->or_else' );

   isa_ok( $f->transform(),
           "t::Future::Subclass",
           '$f->transform' );
}

# immediate->followed_by( sub { subclass } )
{
   my $f = t::Future::Subclass->new;

   isa_ok( Future->done->followed_by( sub { $f } ),
           "t::Future::Subclass",
           'imm->followed_by $f' );
}

# dependents
{
   my $f = t::Future::Subclass->new;

   isa_ok( Future->wait_all( $f ),
           "t::Future::Subclass",
           'Future->wait_all( $f )' );

   isa_ok( Future->wait_any( $f ),
           "t::Future::Subclass",
           'Future->wait_any( $f )' );

   isa_ok( Future->needs_all( $f ),
           "t::Future::Subclass",
           'Future->needs_all( $f )' );

   isa_ok( Future->needs_any( $f ),
           "t::Future::Subclass",
           'Future->needs_any( $f )' );

   my $imm = Future->done;

   isa_ok( Future->wait_all( $imm, $f ),
           "t::Future::Subclass",
           'Future->wait_all( $imm, $f )' );

   # Pick the more derived subclass even if all are pending

   isa_ok( Future->wait_all( Future->new, $f ),
           "t::Future::Subclass",
           'Future->wait_all( Future->new, $f' );
}

my $f_await;
{
   my $f = t::Future::Subclass->new;

   my $count = 0;
   $f_await = sub {
      $count++;
      identical( $_[0], $f, '->await is called on $f' );
      $_[0]->done( "Result here" ) if $count == 2;
   };

   is_deeply( [ $f->get ],
              [ "Result here" ],
              'Result from ->get' );

   is( $count, 2, '$f->await called twice' );
}

done_testing;

package t::Future::Subclass;
use base qw( Future );

sub await
{
   $f_await->( @_ );
}
