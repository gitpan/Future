package IO::Async::Future; # it's OK I own this one ;)
use base qw( Future );

sub new
{
   my $proto = shift;
   my $self = $proto->SUPER::new;

   if( ref $proto ) {
      $self->{loop} = $proto->{loop};
   }
   else {
      $self->{loop} = shift;
   }

   return $self;
}

sub await
{
   my $self = shift;
   $self->{loop}->loop_once;
}

sub IO::Async::Loop::delay_future
{
   my $self = shift;
   my ( $delay ) = @_;
   my $f = IO::Async::Future->new( $self );

   my $id = $self->watch_time(
      after => $delay, code => $f->done_cb,
   );
   $f->on_cancel( sub {
      $self->unwatch_time( $id );
   } );

   return $f;
}

package main;
use IO::Async::Loop;

my $loop = IO::Async::Loop->new;

my $timer = $loop->delay_future( 3 );
print "Awaiting 3 seconds...\n";

$timer->get;
print "Done\n";
