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

my $commit;

###### first commit
w( 'old', 'content' );
$git->command( 'add', '.' );
do_commit('import old content');
$git->command( 'remote', 'add', 'origin', "file://$remote" );
push_ok;

$commit = $c->describe_commit;
ok( defined($commit), 'initial import commit' );
is( $c->describe_commit, undef, 'no more commits' );

#### branch, two changes, merge. then the changes should be reported only once
my $b1 = 'a-new';
$git->command( [ 'checkout', '-b', $b1, 'master' ],
    { STDERR => 0 } );
w( 'new', 'content' );
$git->command( 'add', 'new' );
$git->command( 'commit', '-m', 'created new content' );
w( 'new', 'more content' );
$git->command( 'commit', '-a', '-m', 'updated new content' );
$git->command( 'checkout', '-q', 'master' );
$git->command( 'merge', '--no-ff', '-m', "merge '$b1' into master", $b1 );

# same with a branch name sorting after 'master'
my $b2 = 'new-content';
$git->command( [ 'checkout', '-b', $b2, 'master' ],
    { STDERR => 0 } );
w( 'new', 'content' );
$git->command( 'add', 'new' );
$git->command( 'commit', '-m', 'created new content' );
w( 'new', 'more content' );
$git->command( 'commit', '-a', '-m', 'updated new content' );
$git->command( 'checkout', '-q', 'master' );
$git->command( 'merge', '--no-ff', '-m', "merge '$b2' into master", $b2 );
push_ok();

$commit = $c->describe_commit;
ok( defined($commit), 'merge commit exists' );
is( $commit->branch, 'master' );
is( $commit->log,    "merge '$b1' into master" );

$commit = $c->describe_commit;
ok( defined($commit), 'merge commit exists' );
is( $commit->branch, 'master' );
is( $commit->log,    "merge '$b2' into master" );

$commit = $c->describe_commit;
ok( defined($commit), "first $b1 commit exists" );
is( $commit->branch, $b1 );
is( $commit->log,    "created new content" );

$commit = $c->describe_commit;
ok( defined($commit), "second $b1 commit exists" );
is( $commit->branch, $b1 );
is( $commit->log,    "updated new content" );

$commit = $c->describe_commit;
ok( defined($commit), "first $b2 commit exists" );
is( $commit->branch, $b2 );
is( $commit->log,    "created new content" );

$commit = $c->describe_commit;
ok( defined($commit), "second $b2 commit exists" );
is( $commit->branch, $b2 );
is( $commit->log,    "updated new content" );

##### No more commits after the last
$commit = $c->describe_commit;
is( $commit, undef );
