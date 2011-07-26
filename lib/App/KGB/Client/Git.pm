# vim: ts=4:sw=4:et:ai:sts=4
#
# KGB - an IRC bot helping collaboration
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

package App::KGB::Client::Git;

use strict;
use warnings;

use base 'App::KGB::Client';
use Git;
use Carp qw(confess);
__PACKAGE__->mk_accessors(
    qw( changesets old_rev new_rev refname git_dir _git _commits reflog ));

use App::KGB::Change;
use App::KGB::Commit;
use IPC::Run;

=head1 NAME

App::KGB::Client::Git - Git supprot for KGB client

=head1 SYNOPSYS

my $c = App::KGB::Client::Git->new({
    ...
    git_dir => '/some/where',   # defaults to $ENV{GIT_DIR}
    old_rev     => 'a7c42f58',
    new_rev     => '8b37ed8a',
});

=head1 DESCRIPTION

App::KGB::Client::Git provides KGB client with knowledge about Git
repositories. Its L<|describe_commit> method returns a series of
L<App::KGB::Commit> objects, each corresponding to the next commit of the
received series.

=head1 CONSTRUCTION

=head2 App::KGB::Client::Git->new( { parameters... } )

Input data can be given in any of the following ways:

=over

=item as parameters to the constructor

    # a single commit
    my $c = App::KGB::Client::Git->new({
        old_rev => '9ae45bc',
        new_rev => 'a04d3ef',
        refname => 'master',
    });

=item as a list of revisions/refnames

    # several commits
    my $c = App::KGB::Client::Git->new({
        changesets  => [
            [ '4b3d756', '62a7c8f', 'master' ],
            [ '7a2fedc', '0d68c3a', 'my'     ],
            ...
        ],
    });

All the other ways to supply the changes data is converted internally to this
one.

=item in a file whose name is in the B<reflog> parameter

A file name of C<-> means standard input, which is the normal way for Git
post-receive hooks to get the data.

The file must contain three words separated by spaces on each line. The first
one is taken to be the old revision, the second is the new revision and the
third is the refname.

=item on the command line

Useful when testing the KGB client from the command line. If neither
B<old_rev>, B<new_rev>, B<refname> nor B<changesets> is given to the
constructor, and if @ARGV has exactly three elements, they are taken to be old
revision, new revision and refname respectively. Only one commit can be
represented on the command line.

=back

In all of the above methods, the location of the F<.git> directory can be given
in the B<git_dir> parameter, or it will be taken from the environment variable
B<GIT_DIR>.

=cut

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);

    $self->git_dir( $ENV{GIT_DIR} )
        unless defined( $self->git_dir );

    defined( $self->git_dir )
        or confess
        "'git_dir' is mandatory; either supply it or define GIT_DIR in the environment";


    $self->_git( Git->repository( Repository => $self->git_dir ) );

    if ( defined( $self->old_rev // $self->new_rev // $self->refname ) ) {

        # single commit
        defined( $self->old_rev )
            and defined( $self->new_rev )
            and defined( $self->refname )
            or confess
            "either all of old_rev, new_rev and refname shall be present or neither";

        defined $self->changesets
            and confess
            "You can't supply both old_rev, new_rev and ref_name and changesets";

        defined $self->reflog
            and confess
            "You can't supply both old_rev, new_rev and ref_name and reflog";

        $self->changesets(
            [ [ $self->old_rev, $self->new_rev, $self->refname ] ] );
    }
    elsif ( defined( $self->changesets ) ) {

        # ready changesets
        ref( $self->changesets ) and ref( $self->changesets ) eq 'ARRAY'
            or confess "'changesets' must be an arrayref";

        for( @{ $self->changesets } ) {
            defined($_) and ref($_) and ref($_) eq 'ARRAY'
                or confess "Each changeset must be an arrayref";

            @$_ == 3 or confess "Each changeset must contain three elements";
        }

        defined $self->reflog
            and confess "You can't supply both chaangesets reflog";
    }
    elsif ($self->reflog) {
        $self->_parse_reflog;
    }
    elsif ( @ARGV == 3 ) {

        # a single changeset on the command line
        $self->changesets( [ [@ARGV] ] );
    }
    else {
        confess "No reflog sources given";
    }

    return $self;
}

sub _parse_reflog {
    my $self = shift;

    # read changeset data from a file
    $self->changesets( [] );
    my $fh;
    open( $fh, $self->reflog )
        or die "open(" . $self->reflog . "): $!";
        # in order for '-' to open STDIN, we must use two-argument form of
        # open(). see 'perldoc -f open'
    while (<$fh>) {
        chomp;
        my @cs = split( /\s+/, $_ );
        @cs == 3
            or confess
            "Invalid data on row $.. Must contain three space-separated words";
        push @{ $self->changesets }, \@cs;
    }
    close $fh;
}

=head1 METHODS

=over

=item describe_commit

Returns an instance of L<App::KGB::Change> class for each commit. Returns
B<undef> when all commits were processed.

=cut

sub describe_commit {
    my $self = shift;

    $self->_detect_commits unless defined( $self->_commits );

    return shift @{ $self->_commits };
}

sub _detect_commits {
    my $self = shift;

    $self->_commits([]);

    while ( my $next = shift @{ $self->changesets } ) {
        my ( $old_rev, $new_rev, $refname ) = @$next;

        $self->_process_commit( $old_rev, $new_rev, $refname );
    }
}

sub _exists {
    my ( $self, $obj ) = @_;

    # we resort to runing 'git cat-file' ourselves as the Git wrapper doesn't
    # provide an easy way to do so without polluting STDERR in case the object
    # doesn't exist
    #
    # Sad but true
    my ( $in, $out, $err );
    # this will exit with status 128 if the object does not exist
    IPC::Run::run [ 'git', "--git-dir=" . $self->git_dir, 'cat-file', '-e',
        $obj ], \$in, \$out, \$err;

    # success means the object exists
    if ( $? == 0 ) {
        #warn "$obj exists";
        return 1;
    }

    my $res = $? >> 8;

    # exit code of 128 means the object doesn't exist
    if ( $res == 128 ) {
        #warn "$obj doesn't exist";
        return 0
    };

    die
        "Command 'git cat-file -e $obj' exited with code $res and said '$err'";
}

sub _describe_ref {
    my( $self, $new ) = @_;

    # raw commit looks like this:
    #commit cc746cf3f6b8937c059cf6311a8903dba9936749
    #tree 76bcae9bdbcfab304c8265d2c2cc245048c9f0f3
    #parent 7e99c8b051169e43189c822c8db77bcad5956734
    #author Damyan Ivanov <dmn@debian.org> 1257538837 +0200
    #committer Damyan Ivanov <dmn@debian.org> 1257538837 +0200
    #
    #    update README.debian with regard to repackaging
    #
    #:100644 100644 603d70d... b81e344... M  debian/README.debian
    #:100644 100644 f1511af... 573335e... M  debian/changelog

    my ( $fh, $ctx )
        = $self->_git->command_output_pipe( 'show', '--pretty=raw',
        '--no-abbrev', '--raw', $new );
    my @log;
    my @changes;
    my @parents;
    my $author;
    while (<$fh>) {
        $author = $1, next if /^author .+ <([^>]+)@[^>]+>/;
        push( @parents, substr( $1, 0, 7 ) ), next if /^parent\s+(\S+)/;
        push( @log, $1 ), next if /^    (.*)/;
        if (s/^::?//) {     # a merge commit
            chomp;
            my @old_modes;
            while ( s/^(\d{6,6})\s+// ) {
                push @old_modes, $1;
            }
            my $new_mode = pop @old_modes;

            my @old_shas;
            while (s/^([0-9a-f]{40,40})\s+//) {
                push @old_shas, $1;
            }
            my $new_sha = pop @old_shas;

            my $flag = '';
            s/^(\S+)\s+// and $flag = $1;

            my $file = $_;

            # maybe deleted?
            if ( $new_sha =~ /^0+$/ or $flag =~ /D/ ) {
                push @changes, App::KGB::Change->new("(D)$file");
            }
            # maybe created?
            elsif ( not @parents or grep {/^0+$/} @old_shas or $flag =~ /A/ ) {
                push @changes, App::KGB::Change->new("(A)$file");
            }
            else {
                my $mode_change
                    = ( grep { $_ ne $new_mode } @old_modes ) ? '+' : '';
                push @changes, App::KGB::Change->new("(M$mode_change)$file");
            }
        }

    }

    $self->_git->command_close_pipe( $fh, $ctx );

    return {
        id     => substr( $new, 0, 7 ),
        author => $author,
        log     => join( "\n", @log ),
        changes => \@changes,
        parents => \@parents,
    };
}

sub _describe_annotated_tag {
    my( $self, $ref ) = @_;

    my ( $fh, $ctx )
        = $self->_git->command_output_pipe( 'show', '--stat', '--format=raw', $ref );
    my @log;
    my $author;
    my $tag;
    my $signed;
    my $commit;

    # annotated tags are listed as
    #  tag <tag name>
    #  Tagger: Some One <sone@swhere.nev>
    #
    #  Tag message
    #
    #  commit <ref>
    #  Author: .....
    #  .... <tag description>
    my $in_header = 1;
    while (<$fh>) {
        chomp;

        $commit = substr( $1, 0, 7 ), last if /^commit (.+)/;
        if (/^-----BEGIN PGP SIGNATURE/) {
            $signed = 1;
            do {
                defined($_ = <$fh>) or last;
            } until (/^-----END PGP SIGNATURE/);

            next;
        }

        if ($in_header) {
            $tag = $1, next if /^tag (.+)/;

            $author = $1, next if /^Tagger: .+ <([^>]+)@[^>]+>/;

            $in_header = 0 if /^$/;
        }
        else {
            push( @log, $_ );
        }
    }

    $self->_git->command_close_pipe( $fh, $ctx );

    pop @log if $log[$#log] eq '';
    push @log, "tagged commit: $commit" if $commit;

    return App::KGB::Commit->new(
        {   id     => substr( $ref, 0, 7 ),
            author => $author,
            log    => join( "\n", @log ),
            branch  => $signed ? 'signed tags' : 'tags',
            changes => [ App::KGB::Change->new("(A)$tag") ],
        }
    );
}

# there is a subtle problem when two branches with common commits are received
# together
# since we only traverse commits that follow from a branch HEAD, excluding any
# commits that are also reachable from other branches, common commits are
# excluded from all traversals
# to reproduce:
#   $ git co master
#   make a change and commit         [1]
#   $ git co -b other
#   make another change and commit   [2]
#   $ git push --all
#  now [1] is excluded from master traversal because it is also included in
#  'other'. and it is excluded from 'other' traversal because it is reachable
#  from 'master'
# we work around the problem by excluding otherwise reachable commits only
# when $old_rev is all zeroes, which happens only when the branch update is
# actually a branch creation
sub _describe_branch_changes {
    my ( $self, $branch, $old_rev, $new_rev ) = @_;

    my $is_new_branch = $old_rev =~ /^0+$/;

    warn "describing changes in $branch" if 0;
    # the idea here is to get all revs that are in $branch HEAD, and not
    # reachable by other branches' heads
    my $branch_head = $self->_git->command_oneline( 'rev-parse', $branch );

    warn "head is $branch_head" if 0;

    my @not_other = grep { $_ ne "^$branch_head" }
        $self->_git->command( 'rev-parse', '--not', '--all' ) if $is_new_branch;

    warn "\@not_other = ".join(' ', @not_other) if 0;

    if ( $is_new_branch and not @not_other and $branch ne 'master' ) {
        # this is a fully-merged branch, a hollow one
        # all the changes are already send
        # or, this is the initial import of a branch without parents
        # we set in stone that only 'master' is allowed to be the initial
        # import
        return ();
    }

    my $ref_spec = $is_new_branch ? $new_rev : "$old_rev..$new_rev";

    warn "ref spec: $ref_spec" if 0;

    my @revs = $self->_git->command( 'rev-list', '--reverse', @not_other, $ref_spec );

    warn "revisions to describe: ".join(' ', @revs) if 0;

    my @commits;
    for my $ref (@revs) {
        my $cmt = App::KGB::Commit->new( $self->_describe_ref($ref) );
        $cmt->branch($branch);
        push @commits, $cmt;
    }

    return @commits;
}

sub _process_commit {
    my ( $self, $old_rev, $new_rev, $refname ) = @_;

    $_ = $self->_git->command_oneline( 'rev-parse', $_ )
        for ( $old_rev, $new_rev );

    # see what kind of commit is this
    my $ref_update_type;
    if ( $old_rev =~ /^0+$/ ) {

        # 0000000 -> 1234567
        $ref_update_type = 'create';
    }
    elsif ( $new_rev =~ /^0+$/ ) {

        # 7654321 -> 0000000
        $ref_update_type = 'delete';
    }
    else {

        # 2345678 -> 3456789
        $ref_update_type = 'update';
    }

    my ( $rev, $rev_type );
    if ( $ref_update_type eq 'delete' ) {
        $rev      = $old_rev;
        $rev_type = $self->_git->command_oneline( 'cat-file', '-t', $old_rev );
    }
    else {    # create or update
        $rev      = $new_rev;
        $rev_type = $self->_git->command_oneline( 'cat-file', '-t', $new_rev );
    }

    my ( $refname_type, $short_refname, $branch, $tag, $remote );

    # revision type and location tell us if this is
    #  - working branch
    #  - tracking branch
    #  - unannoted tag
    #  - annotated tag
    if ( $refname =~ m{refs/tags/.+} and $rev_type eq 'commit' ) {

        # un-annotated tag
        $refname_type = "tag";
        ( $tag = $refname ) =~ s,refs/tags/,,;
    }
    elsif ( $refname =~ m{refs/tags/.+} and $rev_type eq 'tag' ) {

        # annotated tag
        $refname_type = "annotated tag";
        ( $tag = $refname ) =~ s,refs/tags/,,;
    }
    elsif ( $refname =~ m{refs/heads/.+} and $rev_type eq 'commit' ) {

        # branch
        $refname_type = "branch";
        ( $branch = $refname ) =~ s,refs/heads/,,;
    }
    elsif ( $refname =~ m{refs/remotes/.+} and $rev_type eq 'commit' ) {

        # tracking branch
        $refname_type = "tracking branch";
        ( $remote = $refname ) =~ s,refs/remotes/,,;
        warn <<"EOF";
*** Push-update of tracking branch, $refname
*** no notification sent.
EOF
        return undef;
    }
    else {

        # Anything else (is there anything else?)
        die "*** Unknown type of update to $refname ($rev_type)";
    }

    if ( $ref_update_type eq 'create' ) {
        if ( $refname_type eq 'tag' ) {
            push @{ $self->_commits },
                App::KGB::Commit->new(
                {   id     => substr( $new_rev, 0, 7 ),
                    #author => $cmt->author,
                    log => "tag '$tag' created",
                    branch => 'tags',
                }
                );
        }
        elsif ( $refname_type eq 'annotated tag' ) {
            push @{ $self->_commits }, $self->_describe_annotated_tag($new_rev);
        }
        else {
            my @commits = $self->_describe_branch_changes( $branch, $old_rev,
                $new_rev );

            if (@commits) {

                # mimic a commit that creates the branch
                my $c = $self->_describe_ref( $commits[0]{id} );
                unshift @commits, App::KGB::Commit->new(
                    {   branch  => $branch,
                        changes => [],
                        log     => 'branch created',
                        id      => $c->{parents}[0]
                            || $c->{id},   # the initial commit has no parents
                        author => $c->{author},
                    }
                );

                push @{ $self->_commits }, @commits;
            }
            else {

                # If there were no genuine branch commits, this means the new
                # branch is just a copy of an old one and there is nothing
                # changed.
                # Still, we want to notify about the fact that the branch was
                # created
                my $c = $self->_describe_ref($new_rev);
                push @{ $self->_commits },
                    App::KGB::Commit->new(
                    {   id      => $c->{id},
                        branch  => $branch,
                        changes => [],
                        log     => 'branch created',
                        author  => $c->{author},
                    }
                    );
            }
        }
    }
    elsif ( $ref_update_type eq 'delete' ) {
        push @{ $self->_commits }, App::KGB::Commit->new(
            {   id     => substr( $old_rev, 0, 7 ),
                author => 'TODO: deletor',
                log    => ( $branch ? 'branch' : 'tag' ) . ' deleted',
                branch => $branch || 'tags',
                changes => [
                    App::KGB::Change->new(
                        { action => 'D', path => ( $branch ? '.' : $tag ) }
                    )
                    ],
            }
        );
    }
    else {    # update
        push @{ $self->_commits },
            $self->_describe_branch_changes( $branch, $old_rev, $new_rev );
    }
}

=back

=head1 COPYRIGHT & LICENSE

Copyright (c) 2009 Damyan Ivanov

Based on the shell post-recieve hook by Andy Parkins

This file is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc., 51
Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

=cut

1;
