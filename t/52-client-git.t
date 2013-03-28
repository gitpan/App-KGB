use strict;
use warnings;

use autodie qw(:all);
use Test::More;

BEGIN {
    eval { require Git; 1 }
        or plan skip_all => "Git.pm required for testing Git client";
}

plan 'no_plan';

use App::KGB::Change;
use App::KGB::Client::Git;
use App::KGB::Client::ServerRef;
use Git;
use File::Temp qw(tempdir);
use File::Spec;

use utf8;
my $builder = Test::More->builder;
binmode $builder->output,         ":utf8";
binmode $builder->failure_output, ":utf8";
binmode $builder->todo_output,    ":utf8";

my $tmp_cleanup = not $ENV{TEST_KEEP_TMP};
my $dir = tempdir( 'kgb-XXXXXXX', CLEANUP => $tmp_cleanup, DIR => File::Spec->tmpdir );
diag "Temp directory $dir will pe kept" unless $tmp_cleanup;

sub write_tmp {
    my( $fn, $content ) = @_;

    open my $fh, '>', "$dir/$fn";
    print $fh $content;
    close $fh;
}

if ( $ENV{TEST_KGB_BOT_DUMP} ) {
    diag "$ENV{TEST_KGB_BOT_DUMP} will be checked for IRC dump";
    truncate( $ENV{TEST_KGB_BOT_DUMP}, 0 ) if -e $ENV{TEST_KGB_BOT_DUMP};
    require Test::Differences;
    Test::Differences->import;
}

my $dump_fh;

sub is_irc_output {
    return unless my $dump = $ENV{TEST_KGB_BOT_DUMP};
    my $wanted = shift;

    use IO::File;
    $dump_fh ||= IO::File->new("< $dump")
        or die "Unable to open $dump: $!";
    $dump_fh->binmode(':utf8');
    local $/ = undef;
    $dump_fh->seek( $dump_fh->tell, 0 );
    eq_or_diff( "" . <$dump_fh>, $wanted );
}

my $remote = "$dir/there.git";
my $local = "$dir/here";

sub w {
    my ( $fn, $content ) = @_;

    write_tmp( "here/$fn", "$content\n" );
}

sub a {
    my ( $fn, $content ) = @_;

    open my $fh, '>>', "$local/$fn";
    print $fh $content, "\n";
    close $fh;
}

mkdir $remote;
$ENV{GIT_DIR} = $remote;
system 'git', 'init', '--bare';

use Cwd;
my $R = getcwd;

if ( $ENV{TEST_KGB_BOT_RUNNING} or $ENV{TEST_KGB_BOT_DUMP} ) {
    diag "will try to send notifications to locally running bot";
    write_tmp 'there.git/hooks/post-receive', <<"EOF";
#!/bin/sh
tee -a "$dir/reflog" | PERL5LIB=$R/lib $R/script/kgb-client --repository git --git-reflog - --conf $R/eg/test-client.conf --status-dir $dir >> $dir/hook.log 2>&1
EOF
}
else {
    write_tmp 'there.git/hooks/post-receive', <<"EOF";
#!/bin/sh
cat >> "$dir/reflog"
EOF
}

chmod 0755, "$dir/there.git/hooks/post-receive";

mkdir $local;
$ENV{GIT_DIR} = "$local/.git";
mkdir "$local/.git";
system 'git', 'init';

my $git = 'Git'->repository($local);
ok( $git, 'local repository allocated' );
isa_ok( $git, 'Git' );

$git->command( 'config', 'user.name', 'Test U. Ser' );
$git->command( 'config', 'user.email', 'ser@example.neverland' );

write_tmp 'reflog', '';

my $c = new_ok(
    'App::KGB::Client::Git' => [
        {   repo_id => 'test',
            servers => [
                App::KGB::Client::ServerRef->new(
                    {   uri      => "http://127.0.0.1:1234/",
                        password => "hidden",               # not used by this client instance
                    }
                ),
            ],

            #br_mod_re      => \@br_mod_re,
            #br_mod_re_swap => $br_mod_re_swap,
            #ignore_branch  => $ignore_branch,
            git_dir => $remote,
            reflog  => "$dir/reflog",
        }
    ]
);

sub push_ok {
    write_tmp 'reflog', '';
    my $ignore = $git->command( [qw( push origin --all )], { STDERR => 0 } );
    $ignore = $git->command( [qw( push origin --tags )], { STDERR => 0 } );

    $c->_parse_reflog;
    $c->_detect_commits;
}

my %commits;
sub do_commit {
    $git->command_oneline( 'commit', '-m', shift ) =~ /\[(\w+).*\s+(\w+)\]/;
    push @{ $commits{$1} }, $2;
    diag "commit $2 in branch $1" unless $tmp_cleanup;
}



###### first commit
w( 'a', 'some content' );
$git->command( 'add', '.' );
do_commit('initial import');
$git->command( 'remote', 'add', 'origin', "file://$remote" );
push_ok;


# now "$dir/reflog" shall have some refs
#diag "Looking for the reflog in '$dir/reflog'";
ok -s "$dir/reflog", "post-receive hook logs";

my $commit = $c->describe_commit;

ok( defined($commit), 'commit 1 present' );

is( $commit->branch, 'master' );
is( $commit->id, shift @{ $commits{master} } );
is( $commit->log, "initial import" );
is( $commit->author, 'ser' );
is( scalar @{ $commit->changes }, 1 );
is( $commit->changes->[0]->as_string, '(A)a' );

is_irc_output( "#test ser master ".$commit->id." a * initial import\n" );


##### modify and add
a 'a', 'some other content';
w 'b', 'some other content';

$git->command( 'add', '.' );
do_commit('some changes');
push_ok();

$commit = $c->describe_commit;
ok( defined($commit), 'commit 2 present' );

is( $commit->branch, 'master' );
is( $commit->id, shift @{ $commits{master} } );
is( $commit->log, "some changes" );
is( $commit->author, 'ser' );
is( scalar @{ $commit->changes }, 2 );
is( $commit->changes->[0]->as_string, 'a' );
is( $commit->changes->[1]->as_string, '(A)b' );

is_irc_output("#test ser master ".$commit->id." a b * some changes\n");

##### remove, banch, modyfy, add, tag; batch send
$git->command( 'rm', 'a' );
do_commit('a removed');

$git->command( 'checkout', '-q', '-b', 'other', 'master' );
w 'c', 'a new file was born';
w 'b', 'new content';
$git->command( 'add', '.' );
do_commit('a change in the other branch');
$git->command( 'tag', '1.0-beta' );
push_ok();

my $other_branch_point = $commits{master}[0];

my $c1 = $commit = $c->describe_commit;
ok( defined($commit), 'commit 3 present' );
is( $commit->branch, 'master', 'commit 3 branch is "master"' );
is( $commit->id, shift @{ $commits{master} } );
is( $commit->log, "a removed" );
is( $commit->author, 'ser' );
is( scalar @{ $commit->changes }, 1 );
is( $commit->changes->[0]->as_string, '(D)a' );

my $c2 = $commit = $c->describe_commit;
ok( defined($commit), 'commit 4 present' );
is( $commit->branch, 'other' );
is( $commit->id, shift @{ $commits{other} } );
is( $commit->log, "a change in the other branch" );
is( $commit->author, 'ser' );
is( scalar @{ $commit->changes }, 2 );
is( $commit->changes->[0]->as_string, 'b' );
is( $commit->changes->[1]->as_string, '(A)c' );

my $tagged = $commit->id;

$commit = $c->describe_commit;
ok( defined($commit), 'commit 5 present' );
is( $commit->id, $tagged, "commit 5 id" );
is( $commit->branch, 'tags', "commit 5 branch" );
is( $commit->log, "tag '1.0-beta' created", "commit 5 log" );
is( $commit->author, undef, "commit 5 author" );
is( $commit->changes->[0]->as_string, '(A)1.0-beta', "commit 5 changes" );

is_irc_output("#test ser master ".$c1->id." a * a removed
#test ser other ".$c2->id." b c * a change in the other branch
#test tags ".$c2->id." 1.0-beta * tag '1.0-beta' created\n");

##### annotated tag
mkdir( File::Spec->catdir($local, 'debian') );

w( File::Spec->catfile( 'debian', 'README' ),
    'You read this!? Good boy/girl.' );
$git->command( 'add', 'debian' );
do_commit( "add README for release\n\nas everybody knows, releases have to have READMEs\nHello, hi!" );
$git->command( 'tag', '-a', '-m', 'Release 1.0', '1.0-release' );
push_ok();

$c1 = $commit = $c->describe_commit;
ok( defined($commit), 'commit 6 present' );
is( $commit->id, shift @{ $commits{other} } );
is( $commit->branch, 'other' );
is( $commit->log, "add README for release\n\nas everybody knows, releases have to have READMEs\nHello, hi!" );
is( $commit->author, 'ser' );
is( scalar @{ $commit->changes }, 1 );
is( $commit->changes->[0]->as_string, '(A)debian/README' );

$tagged = $commit->id;

$c2 = $commit = $c->describe_commit;
ok( defined($commit), 'annotated tag here' );
is( $commit->branch, 'tags' );
is( $commit->author, 'ser' );
is( scalar( @{ $commit->changes } ), 1 );
is( $commit->changes->[0]->as_string, '(A)1.0-release' );
is( $commit->log,
    "Release 1.0 (tagged commit: $tagged)",
    'annotated tag log'
);

is_irc_output("#test ser other ".$c1->id." debian/README * add README for release
#test ser tags ".$c2->id." 1.0-release * Release 1.0 (tagged commit: ".$c1->id.")
");

# a hollow branch

$git->command('branch', 'hollow');
push_ok();

# hollow branches are not detected for now

$commit = $c->describe_commit;
ok( defined($commit), 'hollow branch described' );
is( $commit->id, $tagged, "hollow commit is $tagged" );
is( $commit->branch, 'hollow', "hollow commit branch is 'hollow'" );
is( scalar( @{ $commit->changes } ), 0, "no changes in hollow commit" );
is( $commit->log, "branch created", "hollow commit log is 'branch created'" );

$commit = $c->describe_commit;
ok( !defined($commit), 'hollow branch has no commits' );

#is_irc_output("#test ser hollow ".$commit->id." * branch created\n");

# some UTF-8
w 'README', 'You dont read this!? Bad!';
$git->command( 'add', '.' );
do_commit( "update readme with an über cléver cómmít with cyrillics: привет" );
push_ok();

$commit = $c->describe_commit;
ok( defined($commit), 'UTF-8 commit exists' );
is( $commit->branch, 'other' );
is( $commit->author, 'ser' );
is( scalar( @{ $commit->changes } ), 1 );
is( $commit->log, "update readme with an über cléver cómmít with cyrillics: привет" );

is_irc_output("#test ser other ".$commit->id." README * update readme with an über cléver cómmít with cyrillics: привет\n");

# parent-less branch
    write_tmp 'reflog', '';
$git->command( [ 'checkout', '--orphan', 'allnew' ], { STDERR => 0 } );
$git->command( 'rm', '-rf', '.' );
$git->command( 'commit', '--allow-empty', '-m', 'created empty branch allnew' );
$git->command( [ 'push', '-u', 'origin', 'allnew' ], { STDERR => 0 } );
    $c->_parse_reflog;
    $c->_detect_commits;

$commit = $c->describe_commit;
ok( defined($commit), 'empty branch creation commit exists' );
is( $commit->branch, 'allnew', 'empty branch name' );
is( $commit->log, "created empty branch allnew", 'empty branch log' );

is_irc_output("#test ser allnew ".$commit->id." * created empty branch allnew\n");

##### No more commits after the last
$commit = $c->describe_commit;
is( $commit, undef );

# now the same on the master branch
$git->command( [ 'checkout', '-q', 'master' ], { STDERR => 0 } );
$git->command( 'merge', 'allnew' );
push_ok();
$c2 = $commit = $c->describe_commit;
ok( defined($commit), 'empty branch merge commit exists' );
is( $commit->branch, 'master' );
is( $commit->log, "Merge branch 'allnew'" );

is_irc_output("#test ser master ".$c2->id." * Merge branch 'allnew'\n");

$git->command( checkout => '-q', 'other' );
mkdir( File::Spec->catdir( $local, 'debian', 'patches' ) );

w( File::Spec->catfile( 'debian', 'patches', 'series' ), 'some.patch' );
w( File::Spec->catfile( 'debian', 'patches', 'some.patch' ), 'This is a patch' );

$git->command( add => 'debian' );
$git->command( commit => -m => 'A change in two files' );
push_ok();

$commit = $c->describe_commit;

is_irc_output( "#test ser other "
        . $commit->id
        . " debian/patches/ series some.patch * A change in two files\n" );

##### No more commits after the last
$commit = $c->describe_commit;
is( $commit, undef );
$commit = $c->describe_commit;
is( $commit, undef );
