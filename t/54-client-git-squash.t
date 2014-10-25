use strict;
use warnings;

use autodie qw(:all);
use Test::More;
use Test::Differences;
unified_diff();

BEGIN {
    eval { require Git; 1 }
        or plan skip_all => "Git.pm required for testing Git client";
}

use lib 't';
use TestBot;

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

my $test_bot = TestBot->start;

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

my $hook_log = "$dir/hook.log";
my $hook = "$dir/there.git/hooks/post-receive";

system( 'git', 'config', 'kgb.squash-message-template',
    '${{author-name}}${ ({author-login})}${ {branch}}${ {commit}}${ {project}/}${{module}}${ {log}}'
);

# the real test client
{
    my $ccf = $test_bot->client_config_file;
    open my $fh, '>', $hook;
    print $fh <<EOF;
#!/bin/sh

tee -a "$dir/reflog" | PERL5LIB=$R/lib $R/script/kgb-client --conf $ccf >> $hook_log 2>&1
EOF
    close $fh;
    chmod 0755, $hook;
}

if ( $ENV{TEST_KGB_BOT_RUNNING} ) {
    diag "will try to send notifications to locally running bot";
    open( my $fh, '>>', $hook );
    print $fh <<"EOF";

cat "$dir/reflog" | PERL5LIB=$R/lib $R/script/kgb-client --conf $R/eg/test-client.conf --status-dir $dir
EOF
    close $fh;
}

system("GIT_DIR=$dir/there.git git config --add kgb.squash-threshold 1");

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
    unlink $hook_log if $hook_log and -s $hook_log;

    my $ignore = $git->command( [qw( push origin --all )], { STDERR => 0 } );
    $ignore = $git->command( [qw( push origin --tags )], { STDERR => 0 } );

    $c->_reset;
    $c->_detect_commits;

    diag `cat $hook_log` if $hook_log and -s $hook_log;
}

my %commits;
sub do_commit {
    $git->command_oneline( 'commit', '-a', '-m', shift ) =~ /\[(\w+).*\s+(\w+)\]/;
    push @{ $commits{$1} }, $2;
    diag "commit $2 in branch $1" unless $tmp_cleanup;
}

my $commit;

###### first commit
w( 'old', 'content' );
$git->command( 'add', '.' );
do_commit('import old content');
$git->command( 'remote', 'add', 'origin', "file://$remote" );

push_ok;

$commit = $c->describe_commit;
ok( defined($commit), 'first commit exists' );
is( $commit->branch, 'master' );
is( $commit->log,    "import old content" );
is( $commit->id,     shift @{ $commits{master} } );

TestBot->expect( '#test 03Test U. Ser (03ser) 05master '
        . $commit->id
        . ' 12test/06there 03old import old content * 14http://scm.host.org/there/master/?commit='
        . $commit->id
        . '' );

w( 'new', 'content' );
$git->command( 'add', 'new' );
$git->command( 'commit', '-m', 'created new content' );
w( 'new', 'more content' );
$git->command( 'commit', '-a', '-m', 'updated new content' );
a( 'new', 'even more content' );
do_commit('another update' );

push_ok;

$commit = $c->describe_commit;
ok( defined($commit), 'squashed commit exists' ) or BAIL_OUT 'will fail anyway';
ok( !ref($commit), 'squashed commit is a plain string' ) or BAIL_OUT 'will fail anyway';

my $commit_id = shift @{ $commits{master} };

TestBot->expect( "#test 03${TestBot::USER_NAME} "
        . "(03${TestBot::USER}) 05master $commit_id "
        . "12test/06there 3 commits pushed, "
        . " 101 file changed, 032(+)" );

### multiple commits in a new branch
$git->command( 'checkout', '-q', '-b', 'feature', 'master' );
a( 'new', 'additional content' );
do_commit( 'additional content in a new branch' );
a( 'new', 'even more additional content' );
do_commit( 'second commit in the new branch' );
push_ok;

my $last_commit_id = $commit_id;
$commit_id = pop @{ $commits{feature} };
$commit = $c->describe_commit;
ok( defined($commit), 'squashed new branch commit exists' ) or BAIL_OUT "premature end of commits";
ok( !ref($commit), 'squashed commit is a plain string' )
    or BAIL_OUT "will fail with $commit anyway";

TestBot->expect( "#test 03${TestBot::USER_NAME} (03${TestBot::USER}) "
        . "05feature "
        . $commit_id
        . " 12test/06there New branch with 2 commits pushed, "
        . " 101 file changed, 032(+) since master/"
        . $last_commit_id );

##### No more commits after the last
$commit = $c->describe_commit;
is( $commit, undef );

my $output = $test_bot->get_output;

undef($test_bot);   # make sure all output us there

eq_or_diff( $output, TestBot->expected_output );

done_testing();
