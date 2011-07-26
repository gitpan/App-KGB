use strict;
use warnings;

use autodie qw(:all);
use Test::More tests => 78;

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

my $port = 7645;
my $password = 'v,sjflir';

my $tmp_cleanup = not $ENV{TEST_KEEP_TMP};
my $dir = tempdir( 'kgb-XXXXXXX', CLEANUP => $tmp_cleanup, DIR => File::Spec->tmpdir );
diag "Temp directory $dir will pe kept" unless $tmp_cleanup;

sub write_tmp {
    my( $fn, $content ) = @_;

    open my $fh, '>', "$dir/$fn";
    print $fh $content;
    close $fh;
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

if ( $ENV{TEST_KGB_BOT_RUNNING} ) {
    diag "will try to send notifications to locally running bot";
    write_tmp 'there.git/hooks/post-receive', <<"EOF";
#!/bin/sh
tee -a "$dir/reflog" | PERL5LIB=$R/lib $R/script/kgb-client --repository git --git-reflog - --repo-id test --uri http://localhost:9999/ --pass "truely secret"
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
                    {   uri      => "http://127.0.0.1:$port/",
                        password => $password,
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

ok( defined($commit), 'commit creating master present' );
is( $commit->branch, 'master' );
is( $commit->id, $commits{master}->[0] );
is( $commit->log, "branch created" );
is( $commit->author, 'ser' );
is( scalar @{ $commit->changes }, 0 );

$commit = $c->describe_commit;

ok( defined($commit), 'commit 1 present' );

is( $commit->branch, 'master' );
is( $commit->id, shift @{ $commits{master} } );
is( $commit->log, "initial import" );
is( $commit->author, 'ser' );
is( scalar @{ $commit->changes }, 1 );
is( $commit->changes->[0]->as_string, '(A)a' );



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

$commit = $c->describe_commit;
ok( defined($commit), 'commit 3 present' );
is( $commit->branch, 'master' );
is( $commit->id, shift @{ $commits{master} } );
is( $commit->log, "a removed" );
is( $commit->author, 'ser' );
is( scalar @{ $commit->changes }, 1 );
is( $commit->changes->[0]->as_string, '(D)a' );

$commit = $c->describe_commit;
ok( defined($commit), 'other brench creating commit present' );
is( $commit->branch, 'other' );
is( $commit->id, $other_branch_point );
is( $commit->log, "branch created" );
is( $commit->author, 'ser' );
is( scalar @{ $commit->changes }, 0 );

$commit = $c->describe_commit;
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
is( $commit->id, $tagged );
is( $commit->branch, 'tags' );
is( $commit->log, "tag '1.0-beta' created" );
is( $commit->author, undef );
is( $commit->changes, undef );


##### annotated tag
w 'README', 'You read this!? Good boy/girl.';
$git->command( 'add', '.' );
do_commit( "add README for release\n\nas everybody knows, releases have to have READMEs" );
$git->command( 'tag', '-a', '-m', 'Release 1.0', '1.0-release' );
push_ok();

$commit = $c->describe_commit;
ok( defined($commit), 'commit 6 present' );
is( $commit->id, shift @{ $commits{other} } );
is( $commit->branch, 'other' );
is( $commit->log, "add README for release\n\nas everybody knows, releases have to have READMEs" );
is( $commit->author, 'ser' );
is( scalar @{ $commit->changes }, 1 );
is( $commit->changes->[0]->as_string, '(A)README' );

$tagged = $commit->id;

$commit = $c->describe_commit;
ok( defined($commit), 'annotated tag here' );
is( $commit->branch, 'tags' );
is( $commit->author, 'ser' );
is( scalar( @{ $commit->changes } ), 1 );
is( $commit->changes->[0]->as_string, '(A)1.0-release' );
is( $commit->log, "Release 1.0\ntagged commit: $tagged" );


# a hollow branch

$git->command('branch', 'hollow');
push_ok();

$commit = $c->describe_commit;
ok( defined($commit), 'hollow branch described' );
is( $commit->id, $tagged );
is( $commit->branch, 'hollow' );
is( $commit->author, 'ser' );
is( scalar( @{ $commit->changes } ), 0 );
is( $commit->log, "branch created" );


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


##### No more commits after the last
$commit = $c->describe_commit;
is( $commit, undef );
$commit = $c->describe_commit;
is( $commit, undef );
