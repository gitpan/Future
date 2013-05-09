#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk

package Future::Utils;

use strict;
use warnings;

our $VERSION = '0.13';

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

If some specific subclass or instance of C<Future> is required as the return
value, it can be passed as the C<return> argument. Otherwise, for backward
compatibility, the return C<Future> will be constructed by cloning the first
trial C<Future>. Because this design has been found to be poor, this will be
removed in a later version. If the trial C<Future> is of some other subclass,
a warning will be printed about this impending change of behaviour.

=head2 $future = repeat { CODE } while => CODE

Repeatedly calls the C<CODE> block while the C<while> condition returns a true
value. Each time the trial future completes, the C<while> condition is passed
the trial future.

 $trial_f = $code->( $previous_trial_f )
 $again = $while->( $trial_f )

If the C<$code> block dies entirely and throws an exception, this will be
caught and considered as an immediately-failed C<Future> with the exception as
the future's failure. The exception will not be propagated to the caller.

=head2 $future = repeat { CODE } until => CODE

Repeatedly calls the C<CODE> block until the C<until> condition returns a true
value. Each time the trial future completes, the C<until> condition is passed
the trial future.

 $trial_f = $code->( $previous_trial_f )
 $accept = $until->( $trial_f )

=head2 $future = repeat { CODE } foreach => ARRAY, otherwise => CODE

Calls the C<CODE> block once for each value obtained from the array, passing
in the value as the first argument (before the previous trial future). When
there are no more items left in the array, the C<otherwise> code is invoked
once and passed the last trial future, if there was one, otherwise C<undef> if
the list was originally empty. The result of the eventual future will be the
result of the future returned from C<otherwise>.

The referenced array may be modified by this operation.

 $trial_f = $code->( $item, $previous_trial_f )
 $final_f = $otherwise->( $last_trial_f )

The C<otherwise> code is optional; if not supplied then the result of the
eventual future will simply be that of the last trial.

=head2 $future = repeat { CODE } foreach => ARRAY, while => CODE, ...

=head2 $future = repeat { CODE } foreach => ARRAY, until => CODE, ...

Combines the effects of C<foreach> with C<while> or C<until>. Calls the
C<CODE> block once for each value obtained from the array, until the array is
exhausted or the given ending condition is satisfied.

If a C<while> or C<until> condition is combined with C<otherwise>, the
C<otherwise> code will only be run if the array was entirely exhausted. If the
operation is terminated early due to the C<while> or C<until> condition being
satisfied, the eventual result will simply be that of the last trial that was
executed.

=head2 $future = repeat { CODE } generate => CODE, otherwise => CODE

Calls the C<CODE> block once for each value obtained from the generator code,
passing in the value as the first argument (before the previous trial future).
When the generator returns an empty list, the C<otherwise> code is invoked and
passed the last trial future, if there was one, otherwise C<undef> if the
generator never returned a value. The result of the eventual future will be
the result of the future returned from C<otherwise>.

 $trial_f = $code->( $item, $previous_trial_f )
 $final_f = $otherwise->( $last_trial_f )

 ( $item ) = $generate->()

The generator is called in list context but should return only one item per
call. Subsequent values will be ignored. When it has no more items to return
it should return an empty list.

=cut

sub _repeat
{
   my ( $code, $future, $running, $cond, $sense ) = @_;
   $$running->on_ready( sub {
      my $self = shift;
      my $again = !!$cond->( $self ) ^ $sense;
      if( $again ) {
         $$running = eval { $code->( $self ) } || Future->new->fail( $@ );
         _repeat( $code, $future, $running, $cond, $sense );
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
   defined($args{while}) + defined($args{until}) == 1 
      or defined($args{foreach})
      or defined($args{generate})
      or croak "Expected one of 'while', 'until', 'foreach' or 'generate'";

   if( $args{foreach} ) {
      $args{generate} and croak "Cannot use both 'foreach' and 'generate'";

      my $array = delete $args{foreach};
      $args{generate} = sub {
         @$array ? shift @$array : ();
      };
   }

   if( $args{generate} ) {
      my $generator = delete $args{generate};
      my $otherwise = delete $args{otherwise};

      # TODO: This is slightly messy as this lexical is captured by both
      #   blocks of code. Can we do better somehow?
      my $done;

      my $orig_code = $code;
      $code = sub {
         my ( $last_trial_f ) = @_;
         my $again = my ( $value ) = $generator->( $last_trial_f );

         if( $again ) {
            unshift @_, $value; goto &$orig_code;
         }

         $done++;
         if( $otherwise ) {
            goto &$otherwise;
         }
         else {
            return $last_trial_f;
         }
      };

      if( my $orig_while = delete $args{while} ) {
         $args{while} = sub {
            $orig_while->( $_[0] ) and !$done;
         };
      }
      elsif( my $orig_until = delete $args{until} ) {
         $args{while} = sub {
            !$orig_until->( $_[0] ) and !$done;
         };
      }
      else {
         $args{while} = sub { !$done };
      }
   }

   my $future;
   my $running;
   if( $args{return} ) {
      $future = $args{return};
      $running = $code->();
   }
   else {
      $running = eval { $code->() } || Future->new->fail( $@ );
      $future = $running->new;
      if( ref $future ne "Future" ) {
         carp "Using a subclassed Trial Future for cloning is deprecated; use the 'return' argument instead"
      }
   }

   $args{while} and _repeat( $code, $future, \$running, $args{while}, 0 );
   $args{until} and _repeat( $code, $future, \$running, $args{until}, 1 );

   $future->on_cancel( sub { $running->cancel } );

   return $future;
}

=head2 $future = repeat_until_success { CODE } ...

A shortcut to calling C<repeat> with an ending condition that simply tests for
a successful result from a future. May be combined with C<foreach> or
C<generate>.

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
