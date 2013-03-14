#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Future::Utils;

use strict;
use warnings;

our $VERSION = '0.10';

use Exporter 'import';

our @EXPORT_OK = qw(
   repeat
   repeat_until_success
);

use Carp;

=head1 NAME

C<Future::Utils> - utility functions for working with C<Future> objects

=head1 SYNOPSIS

 use Future::Utils qw( repeat );

 my $eventual_f = repeat {
    my $trial_f = ...
    return $trial_f;
 } while => sub { my $f = shift; return want_more($f) };

 my $eventual_f = repeat {
    ...
    return $trail_f;
 } until => sub { my $f = shift; return acceptable($f) };

 my $eventual_f = repeat {
    my $item = shift;
    ...
    return $trial_f;
 } foreach => \@items;

 my $eventual_f = repeat_until_success {
    ...
    return $trial_f;
 };

 my $eventual_f = repeat_until_success {
    my $item = shift;
    ...
    return $trial_f;
 } foreach => \@items;

=cut

=head1 REPEATING A BLOCK OF CODE

The C<repeat> function provides a way to repeatedly call a block of code that
returns a L<Future> (called here a "trial future") until some ending condition
is satisfied. The C<repeat> function itself returns a C<Future> to represent
running the repeating loop until that end condition (called here the "eventual
future"). The first time the code block is called, it is passed no arguments,
and each subsequent invocation is passed the previous trial future.

The result of the eventual future is the result of the last trial future.

If the eventual future is cancelled, the latest trial future will be
cancelled.

The eventual future is obtained by calling the C<new> clone constructor on the
first trial future returned by calling the code block the first time, allowing
it to correctly respect subclassing.

=head2 $future = repeat { CODE } while => CODE

Repeatedly calls the C<CODE> block while the C<while> condition returns a true
value. Each time the trial future completes, the C<while> condition is passed
the trial future.

 $trial_f = $code->( $previous_trial_f )
 $again = $while->( $trial_f )

=head2 $future = repeat { CODE } until => CODE

Repeatedly calls the C<CODE> block until the C<until> condition returns a true
value. Each time the trial future completes, the C<until> condition is passed
the trial future.

 $trial_f = $code->( $previous_trial_f )
 $accept = $while->( $trial_f )

=head2 $future = repeat { CODE } foreach => ARRAY

Calls the C<CODE> block once for each value obtained from the array, passing
in the value as the first argument (before the previous trial future). The
result of the eventual future will be the result from the final trial. The
referenced array may be modified by this operation.

 $trial_f = $code->( $item, $previous_trial_f )

=head2 $future = repeat { CODE } foreach => ARRAY, while => CODE

=head2 $future = repeat { CODE } foreach => ARRAY, until => CODE

Combines the effects of C<foreach> with C<while> or C<until>. Calls the
C<CODE> block once for each value obtained from the array, until the array is
exhausted or the given ending condition is satisfied.

=cut

sub _repeat_while
{
   my ( $code, $future, $running, $while ) = @_;
   $$running->on_ready( sub {
      my $self = shift;
      my $again = $while->( $self );
      if( $again ) {
         $$running = $code->( $self );
         _repeat_while( $code, $future, $running, $while );
      }
      else {
         # Propagate result
         $$running->on_done( $future );
         $$running->on_fail( $future );
      }
   } );
}

sub _repeat_until
{
   my ( $code, $future, $running, $while ) = @_;
   $$running->on_ready( sub {
      my $self = shift;
      my $accept = $while->( $self );
      if( !$accept ) {
         $$running = $code->( $self );
         _repeat_until( $code, $future, $running, $while );
      }
      else {
         # Propagate result
         $$running->on_done( $future );
         $$running->on_fail( $future );
      }
   } );
}

sub repeat(&@)
{
   my $code = shift;
   my %args = @_;

   # This makes it easier to account for other conditions
   defined($args{while}) + defined($args{until}) == 1 or defined($args{foreach})
      or croak "Expected one of 'while', 'until' or 'foreach'";

   if( $args{foreach} ) {
      my $array = delete $args{foreach};

      my $orig_code = $code;
      $code = sub { unshift @_, shift @$array; goto &$orig_code };

      if( my $orig_while = delete $args{while} ) {
         $args{while} = sub {
            $orig_while->( $_[0] ) and scalar @$array;
         };
      }
      elsif( my $orig_until = delete $args{until} ) {
         $args{while} = sub {
            !$orig_until->( $_[0] ) and scalar @$array;
         };
      }
      else {
         $args{while} = sub { scalar @$array };
      }
   }

   my $running = $code->();
   my $future = $running->new;

   $args{while} and _repeat_while( $code, $future, \$running, $args{while} );
   $args{until} and _repeat_until( $code, $future, \$running, $args{until} );

   $future->on_cancel( sub { $running->cancel } );

   return $future;
}

=head2 $future = repeat_until_success { CODE } ...

A shortcut to calling C<repeat> with an ending condition that simply tests for
a successful result from a future. May be combined with C<foreach>.

=cut

sub repeat_until_success(&@)
{
   my $code = shift;
   my %args = @_;

   defined($args{while}) or defined($args{until})
      and croak "Cannot pass 'while' or 'until' to repeat_until_success";

   repeat \&$code, while => sub { shift->failure }, %args;
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
