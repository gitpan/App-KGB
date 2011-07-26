package App::KGB::Client;
use utf8;
require v5.10.0;

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

use strict;
use warnings;

=head1 NAME

App::KGB::Client - relay commits to KGB servers

=head1 SYNOPSIS

    use App::KGB::Client;
    my $client = App::KGB::Client( <parameters> );
    $client->run;

=head1 DESCRIPTION

B<App::KGB::Client> is the backend behind L<kgb-client(1)>. It handles
the repository-independent parts of sending the notifications to the KGB server,
L<kgb-bot(1)>. Details about extracting change from commits, branches and
modules is done by sub-classes specific to the version control system in use.

=head1 CONFIGURATION

The following parameters are accepted in the constructor:

=over

=item B<repo_id> I<repository name>

Short repository identifier. Will be used for identifying the repository to the
KGB daemon, which will also use this for IRC notifications. B<Mandatory>.

=item B<uri> I<URI>

URI of the KGB server. Something like C<http://some.server:port>. B<Mandatory>
either as a top-level parameter or as a sub-parameter of B<servers> array.

=item B<proxy> I<URI>

URI of the SOAP proxy. If not given, it is the value of the B<uri> option, with
C<?session=KGB> added.

=item B<password> I<password>

Password for authentication to the KGB server. B<Mandatory> either as a
top-level parameter or as a sub-parameter of B<servers> array.

=item B<timeout> I<seconds>

Timeout for server communication. Default is 15 seconds, as we want instant IRC
and commit response.

=item B<servers>

An array of servers, each an instance of L<App::KGB::Client::ServerRef> class.

When several servers are configured, the list is shuffled and then the servers
are tried one after another until a successful request is done, or the list is
exhausted, in which case an exception is thrown.

=item B<br_mod_re>

A list of regular expressions (simple strings, not L<qr> objects) that serve
for detection of branch and module of commits. Each item from the list is tried
in turn, until an item is found that matches all the paths that were modified
by the commit. Regular expressions must have two captures: the first one giving
the branch name, and the second one giving the module name.

All the paths that were modified by the commit must resolve to the same branch
and module in order for the branch and module to be transmitted to the KGB
server.

    Example: ([^/]+)/([^/]+)/
             # branch/module

=item B<br_mod_re_swap> I<1>

If you can only provide the module name in the first capture and the branch
name in the second, use this option to signal the fact to B<kgb-client>.

=item ignore_branch

When most of the development is in one branch, transmitting it to the KGB
server and seeing it on ORC all the time can be annoing. Therefore, if you
define B<ignore_branch>, and a given commit is in a branch with that name, the
branch name is not transmitted to the server. Module name is still transmitted.

=item module

Forces explicit module name, overriding the branch and module detection. Useful
in Git-hosted sub-projects that want to share single configuration file, but
still want module indication in notifications.

=item verbose

Print diagnostic information.

=back

=cut

require v5.10.0;
use Carp qw(confess);
use Digest::SHA qw(sha1_hex);
use SOAP::Lite;
use Getopt::Long;
use List::Util ();
use base 'Class::Accessor::Fast';
__PACKAGE__->mk_accessors(
    qw( repo_id servers br_mod_re br_mod_re_swap module ignore_branch
        verbose _last_server )
);

=head1 CONSTRUCTOR

=head2 new ( { I<initial values> } )

Standard constructor with initial values in a hashref.

    my $c = App::KGB::Client->new(
        {   repo_id => 'my-repo',
            servers => \@servers,
            ...
        }
    );

See L<|FIELDS> above.

=cut

sub new {
    my $self = shift->SUPER::new(@_);
    defined( $self->repo_id )
        or confess "'repo_id' is mandatory";
    $self->br_mod_re( [ $self->br_mod_re ] )
        if $self->br_mod_re and not ref( $self->br_mod_re );
    $self->servers( [] ) unless defined( $self->servers );

    ref( $self->servers ) and ref( $self->servers ) eq 'ARRAY'
        or confess "'servers' must be an arrayref";

    @{ $self->servers } or confess "No 'servers' specified";

    return $self;
}

=head1 METHODS

=over

=item detect_branch_and_module ( $changes )

Given a set of changes (an arrayref of L<App::KGB::Change> objects), runs all
the regular expressions as listed in B<br_mod_re> and if a regular expression
that matches all the changed paths and returns the branch and module.

In case the module detected is the same as B<ignore_module>, C<undef> is
returned for module.

    ( $branch, $module ) = $client->detect_branch_and_module($changes);

=cut

sub detect_branch_and_module {
    my ( $self, $changes ) = @_;
    return () unless $self->br_mod_re;

    require Safe;
    my $safe = Safe->new;
    $safe->permit_only(
        qw(padany lineseq match const leaveeval
            rv2sv pushmark list warn)
    );

    my ( $branch, $module, $matched_re );

    # for a successful branch/module extraction, we require that all the
    # changes share the same branch/module
    for my $c (@$changes) {
        my ( $change_branch, $change_module );

        for my $re ( @{ $self->br_mod_re } ) {
            $re =~ s{,}{\\,}g;    # escape commas
            my $matching = "m,$re,; "
                . ( $self->br_mod_re_swap ? '($2,$1)' : '($1,$2)' );

            $_ = $c->path;
            ( $change_branch, $change_module ) = $safe->reval($matching);
            die "Error while evaluating `$re': $@" if $@;

            if ( defined($change_branch) and defined($change_module) ) {
                $matched_re = $re;
                last;
            }
        }

        # some change cannot be tied to a branch and a module?
        if ( !defined( $change_branch // $change_module ) ) {
            $branch = $module = $matched_re = undef;
            last;
        }

        if ( defined($branch) ) {

            # this change is for a different branch/module?
            if ( $branch ne $change_branch or $module ne $change_module ) {
                $branch = $module = $matched_re = undef;
                last;
            }
        }
        else {

            # first change, store branch and module
            $branch = $change_branch;
            $module = $change_module;
        }
    }

    # remove the part that have matched as it contains information about the
    # branch and module that we provide otherwise
    if ($matched_re) {

        #warn "Branch: ".($branch||"NONE");
        #warn "Module: ".($module||"NONE");
        $safe->permit(qw(subst));
        for my $c (@$changes) {

            #warn "FROM ".$c->{path};
            $_ = $c->path;
            $safe->reval("s,.*$matched_re,,");
            die "Eror while evaluating s/.*$matched_re//: $@" if $@;
            $c->path($_);

            #warn "  TO $_";
        }
    }

    if ( $self->verbose and $branch ) {
        print "Detected branch '$branch' and module '"
            . ( $module // 'NONE' ) . "'\n";
    }

    return ( $branch, $module );
}

=item process_commit ($commit)

Processes a single commit, trying to send the changes summary to each of the
servers, defined inn B<servers>, until some server is successfuly notified.

=cut

use constant rev_prefix => '';

sub process_commit {
    my ( $self, $commit ) = @_;

    my $module = $self->module // $commit->module;
    my $branch = $commit->branch;

    if ( not defined($module) or not defined($branch) ) {
        my ( $det_branch, $det_module )
            = $self->detect_branch_and_module( $commit->changes );

        $branch //= $det_branch;
        $module //= $det_module;
    }

    $branch = undef
        if $branch and $branch eq ( $self->ignore_branch // '' );

    my @servers = List::Util::shuffle( @{ $self->servers } );

    if ( $self->_last_server ) {
        # just put the last server first in the list
        @servers = sort {
            return -1 if $a->uri eq $self->_last_server->uri;
            return +1 if $b->uri eq $self->_last_server->uri;
            return 0;
        } @servers;
    }

    # try all servers in turn until someone succeeds
    my $failure;
    for my $srv (@servers) {
        $failure = eval {
            $srv->send_changes( $self->repo_id, $self->rev_prefix, $commit,
                $branch, $module );
            $self->_last_server($srv);
            0;
        } // 1;

        warn $@ if $@;

        last unless $failure;
    }

    die "Unable to complete notification. All servers failed\n"
        if $failure;
}

=item process

The main processing method. Calls B<describe_commit> and while it returns true
values, gives them to B<process_commit>.

=cut

sub process {
    my $self = shift;

    while ( my $commit = $self->describe_commit ) {
        $self->process_commit($commit);
    }
}

1;

__END__

=back

=head1 PROVIDING REPOSITORY-SPECIFIC FUNCTIONALITY

L<App::KGB::Client> is a generic class providing repository-agnostic
functionality. All repository-specific methods are to be provided by classes,
inheriting from L<App::KGB::Client>. See L<App::KGB::Client::Subversion> and
L<App::KGB::Client::Git>.

Repository classes must provide the following method:

=over

=item B<dsescribe_commit>

This method returns an L<App::KGB::Commit> object that
represents a single commit of the repository.

B<describe_commit> is called several times, until it returns C<undef>. The idea
is that a single L<App::KGB::Client> run can be used to process several commits
(for example if the repository is L<Git>). If this is the case each call to
B<describe_commit> shall return information about the next commit in the
series. For L<Subversion>, this module is expected to return only one commit,
subsequent calls shall return C<undef>.

=back

=head1 SEE ALSO

=over

=item L<App::KGB::Client::Subversion>

=item L<App::KGB::Client::Git>

=back

=cut

