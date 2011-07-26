# vim: ts=4:sw=4:et:ai:sts=4
#
# KGB - an IRC bot helping collaboration
# Copyright © 2008 Martín Ferrari
# Copyright © 2009 Damyan Ivanov
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, write to the Free Software Foundation, Inc., 51
# Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
package App::KGB::Change;

use strict;
use warnings;

=head1 NAME

App::KGB::Change - a single file change

=head1 SYNOPSIS

    my $c = App::KGB::Change->new(
        { action => "M", prop_change => 1, path => "/there" } );

    print $c;

    my $c = App::KGB::Change->new("(M+)/there");

=head1 DESCRIPTION

B<App::KGB::Change> encapsulates a single path change from a given change set
(or commit).

B<App::KGB::Change> overloads the "" operator in order to provide a default
string representation of changes.

=head1 FIELDS

=over

=item B<action> (B<mandatory>)

The action performed on the item. Possible values are:

=over

=item B<M>

The path was modified.

=item B<A>

The path was added.

=item B<D>

The path was deleted.

=item B<R>

The path was replaced.

=back

=item path (B<mandatory>)

The path that was changed.

=item prop_change

Boolean. Indicated that some properties of the path, not the content were
changed.

=back

=cut

use base 'Class::Accessor::Fast';
__PACKAGE__->mk_accessors(qw( action prop_change path ));

use Carp qw(confess);

=head1 CONSTRUCTOR

=head2 new ( { I<initial values> } )

More-or-less standard constructor.

It can take a hashref with keys all the field names (See L<|FIELDS>).

Or, it can take a single string, which is de-composed into components.

See L<|SYNOPSIS> for examples.

=cut

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new();

    my $h = shift;
    if ( ref($h) ) {
        defined( $self->action( delete $h->{action} ) )
            or confess "'action' is required";
        defined( $self->path( delete $h->{path} ) )
            or confess "'path' is required";
        $self->prop_change( delete $h->{prop_change} );
    }
    else {
        my ( $a, $pc, $p ) = $h =~ /^(?:\(([MADR])?(\+)?\))?(.+)$/
            or confess "'$h' is not recognized as a change string";
        $self->action( $a //= 'M' );
        $self->prop_change( defined $pc );
        $self->path($p);
    }

    return $self;
}

=head1 METHODS

=over

=item as_string()

Return a string representation of the change. Used by the ""  overload. The resulting string is suitable for feeding the L<|new> constructor if needed.

=cut

use overload '""' => \&as_string;

sub as_string {
    my $c  = shift;
    my $a  = $c->action;
    my $pc = $c->prop_change ? '+' : '';
    my $p  = $c->path;

    my $text = '';

    # ignore flags for modifications (unlless there is also a property change)
    $text = "($a$pc)" if $a ne 'M' or $pc;
    $p =~ s,^/,,;    # strip leading slash from paths
    $text .= $p;
    return $text;
}

=back

=cut

1;
