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

sub strip_irc_colors {
    my $in = shift;

    $in =~ s/\x03\d\d//g;
    $in =~ s/[\x00-\x1f]+//g;

    return $in;
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

my $hook_log;

system( 'git', 'config', 'kgb.squash-message-template',
    '${{author-name}}${ ({author-login})}${ {branch}}${ {commit}}${ {project}/}${{module}}${ {log}}'
);

if ( $ENV{TEST_KGB_BOT_RUNNING} or $ENV{TEST_KGB_BOT_DUMP} ) {
    diag "will try to send notifications to locally running bot";
    $hook_log = "$dir/hook.log";
    write_tmp 'there.git/hooks/post-receive', <<"EOF";
#!/bin/sh
tee -a "$dir/reflog" | PERL5LIB=$R/lib $R/script/kgb-client --repository git --git-reflog - --conf $R/eg/test-client.conf --status-dir $dir >> $hook_log 2>&1
EOF
}
else {
    write_tmp 'there.git/hooks/post-receive', <<"EOF";
#!/bin/sh
cat >> "$dir/reflog"
EOF
}

chmod 0755, "$dir/there.git/hooks/post-receive";

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

    $c->_parse_reflog;
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

w( 'new', 'content' );
$git->command( 'add', 'new' );
$git->command( 'commit', '-m', 'created new content' );
w( 'new', 'more content' );
$git->command( 'commit', '-a', '-m', 'updated new content' );
a( 'new', 'even more content' );
$git->command( 'commit', '-a', '-m', 'another update' );

push_ok;

$commit = $c->describe_commit;
ok( defined($commit), 'squashed commit exists' ) or BAIL_OUT 'will fail anyway';
ok( !ref($commit), 'squashed commit is a plain string' ) or BAIL_OUT 'will fail anyway';
like( strip_irc_colors($commit), qr/\($ENV{USER}\) master [0-9a-f]{7} test\/there 3 commits pushed,  1 file changed, 2\(\+\)$/ );

### multiple commits in a new branch
$git->command( 'checkout', '-q', '-b', 'feature', 'master' );
a( 'new', 'additional content' );
do_commit( 'additional content in a new branch' );
a( 'new', 'even more additional content' );
do_commit( 'second commit in the new branch' );
push_ok;

$commit = $c->describe_commit;
ok( defined($commit), 'squashed new branch commit exists' ) or BAIL_OUT "premature end of commits";
ok( !ref($commit), 'squashed commit is a plain string' )
    or BAIL_OUT "will fail with $commit anyway";
like( strip_irc_colors($commit), qr/\($ENV{USER}\) feature [0-9a-f]{7} test\/there New branch with 2 commits pushed,  1 file changed, 2\(\+\) since master\/[0-9a-f]{7}/ );

##### No more commits after the last
$commit = $c->describe_commit;
is( $commit, undef );

