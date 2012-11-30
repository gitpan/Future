package Future::POE;
use base qw( Future );
use POE;

sub await
{
   POE::Kernel::run_one_timeslice;
}

sub new_delay
{
   my $self = shift->new;
   my ( $delay ) = @_;

   POE::Session->create(
      inline_states => {
         _start => sub { $_[KERNEL]->delay( done => $delay ) },
         done   => $self->done_cb,
      },
   );

   return $self;
}

package main;

# Quiet the warning that ->run hasn't been called, by calling it now
POE::Kernel->run();

my $timer = Future::POE->new_delay( 3 );
print "Awaiting 3 seconds...\n";

$timer->get;
print "Done\n";
