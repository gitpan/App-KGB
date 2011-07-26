# vim: ts=4:sw=4:et:ai:sts=4
#
# KGB - an IRC bot helping collaboration
# Copyright © 2008 Martín Ferrari
# Copyright © 2009,2010 Damyan Ivanov
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
package App::KGB::Client::ServerRef;

use strict;
use warnings;
use Encode;

=head1 NAME

App::KGB::Client::ServerRef - server instance in KGB client

=head1 SYNOPSIS

    use App::KGB::Client::ServerRef;
    my $s = App::KGB::Client::ServerRef->new(
        {   uri      => "http://some.server:port/",
            password => 's3cr1t',
            timeout  => 5
        }
    );

    $s->send_changes( $repo_id, $commit, $branch, $module );

=head1 DESCRIPTION

B<App::KGB::Client::ServerRef> is used in L<App::KGB::Client> to refer to
remote KGB server instances. It encapsulates sending change sets to the remote
server, maintaining the SOAP protocol encapsulation and authentication to the
remote KGB server.

=head1 CONSTRUCTOR

=over

=item new

The usual constructor. Accepts a hashref of initialiers.

=back

=head1 FIELDS

=over

=item B<uri> (B<mandatory>)

The URI of the remote KGB server. Something like C<http://some.host:port/>.

=item B<proxy>

This is the SOAP proxy used to communicate with the server. If omitted,
defaults to the value of B<uri> field, with C<?session=KGB> appended.

=item B<password> (B<mandatory>)

Password, to be used for authentication to the remote KGB server.

=item B<timeout>

Specifies the timeout for the SOAP transaction in seconds. Defaults to 15
seconds.

=item B<verbose>

Be verbose about communicating with KGB server.

=back

=head1 METHODS

=over

=item B<send_changes> (I<message parameters>)

Transmits the change set and all data about it along with the necessary
authentication hash. If error occures, an exception is thrown.

Message parameters are passed as arguments in the following order:

=over

=item Repository id.

=item Revision prefix (printed plain in front of the bold Commit ID)

=item Commit (an instance of L<App::KGB::Commit>)

=item Branch

=item Module

=back

=back

=cut

require v5.10.0;
use base 'Class::Accessor::Fast';

__PACKAGE__->mk_accessors( qw( uri proxy password timeout verbose ) );

use utf8;
use Carp qw(confess);
use Digest::SHA qw(sha1_hex);
use SOAP::Lite;

sub new {
    my $self = shift->SUPER::new( @_ );

    defined( $self->uri )
        or confess "'uri' is mandatory";
    defined( $self->proxy )
        or $self->proxy( $self->uri . '?session=KGB' );
    defined( $self->password )
        or confess "'password' is mandatory";

    return $self;
}

sub send_changes {
    my ( $self, $repo_id, $rev_prefix, $commit, $branch, $module ) = @_;

    my $s = SOAP::Lite->new( uri => $self->uri, proxy => $self->proxy );
    $s->transport->proxy->timeout( $self->timeout // 15 );

    # Detect utf8 strings and set the utf8 flag, or try to convert from latin1
    my $commit_id = $commit->id;
    my $commit_author = $commit->author;
    my $commit_log = $commit->log;
    my @commit_changes = @{ $commit->changes };
    my $password = $self->password;

    foreach ( $repo_id, $commit_id, @commit_changes, $commit_log,
        $commit_author, $branch, $module, $password ) {
        next unless ( defined );
        next if ( utf8::is_utf8($_) );
        my $t = $_;
        if ( utf8::decode($t) ) {
            # valid utf8 char seq
            utf8::decode($_);
        } else {
            # try with legacy encoding
            utf8::upgrade($_);
        }
    }
    # v1 protocol (well, we use '2', but the auth hash is the same as in v1)
    my $message = join("", $repo_id, $commit_id,
        map( "$_", @commit_changes ), $commit_log, $commit_author,
        $branch // (), $module // (), $password );
    utf8::encode($message);
    my $checksum = sha1_hex($message);

    if ( $self->verbose ) {
        print "About to contact ", $self->proxy, "\n";
        print "Changes:\n";
        print "  $_\n" for @commit_changes;
    }

    # SOAP::Transport::HTTP tries to convert all characters to byte sequences,
    # but fails. See around line 204
    my $res = $s->commit(
        [   2,
            (   map {
                    SOAP::Data->type(
                        string => Encode::encode( 'UTF-8', $_ ) )
                    } ( $repo_id, $checksum, $rev_prefix, $commit_id )
            ),
            [ map { SOAP::Data->type( string => "$_" ) } @commit_changes ],
            (   map {
                    SOAP::Data->type(
                        string => Encode::encode( 'UTF-8', $_ ) )
                    } ( $commit_log, $commit_author, $branch, $module )
            ),
        ]
    );

    if ( $res->fault ) {
        die 'SOAP FAULT while talking to '
            . $self->uri . "\n"
            . 'FAULT MESSAGE: ', $res->fault->{faultstring}, "\n"
            . (
            $res->fault->{detail}
            ? 'FAULT DETAILS: ' . $res->fault->{detail}
            : ''
            );
    }

    #print $res->result(), "\n";
}

1;
