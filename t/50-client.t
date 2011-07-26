use strict;
use warnings;

use autodie qw(:all);
use File::Spec::Functions qw( catdir catfile );
use Test::More tests => 30;

use utf8;
my $builder = Test::More->builder;
binmode $builder->output,         ":utf8";
binmode $builder->failure_output, ":utf8";
binmode $builder->todo_output,    ":utf8";

use File::Temp qw(tempdir);
my $r = tempdir( CLEANUP => 1 );

my $repo = catdir( $r,     'repo' );
my $wd   = catdir( $r,     'checkout' );
my $tf = catfile( $wd, 'file' );

sub poke {
    my $f;
    open $f, ">", $tf;
    print $f @_;
    close $f;
}

sub in_wd {
    system 'sh', '-c', "cd $wd && " . shift;
}

system 'svnadmin', 'create', $repo;

if ( $ENV{TEST_KGB_BOT_RUNNING} ) {
    diag "will try to send notifications to locally running bot";
    use Cwd;
    my $R = getcwd;
    my $h;
    open $h, '>', "$repo/hooks/post-commit";
    print $h <<"EOF";
#!/bin/sh

PERL5LIB=$R/lib $R/script/kgb-client --repo-id test --uri http://localhost:9999 --pass "truely secret" \$1 \$2
EOF
    close $h;
    chmod 0755, "$repo/hooks/post-commit";
}
system 'svn', 'checkout', "file://$repo", $wd;

poke('one');
in_wd "svn add $tf";
in_wd "svn ci -m 'add file'";

poke('two');
in_wd "svn ci -m 'modify file'";

in_wd "svn rm file";
poke('three');
in_wd "svn add file";
in_wd "svn ci -m 'replace file'";

in_wd "svn rm file";
in_wd "svn ci -m 'remove file. Über cool with cyrillics: здрасти'";

ok( 1, "Test repository prepared" );

use App::KGB::Client::Subversion;
use App::KGB::Client::ServerRef;

my $port = 7645;
my $password = 'v,sjflir';

my $c = new_ok(
    'App::KGB::Client::Subversion' => [
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
            repo_path => $repo,
            revision  => 1,
        }
    ]
);

my $commit = $c->describe_commit;

my $me = getpwuid($>);

is( $commit->id, 1 );
is( $commit->log, 'add file' );
diag "\$>=$> \$<=$< \$ENV{USER}=$ENV{USER} getpwuid(\$>)=$me";
is( $commit->author, $me );
is( scalar @{ $commit->changes }, 1 );

my $change = $commit->changes->[0];
is( $change->path, '/file' );
ok( not $change->prop_change );
is( $change->action, 'A' );

$c->revision(2);
$c->_called(0);
$commit = $c->describe_commit;

is( $commit->id, 2 );
is( $commit->log, 'modify file' );
is( $commit->author, $me );
is( scalar @{ $commit->changes }, 1 );

$change = $commit->changes->[0];
is( $change->path, '/file' );
ok( not $change->prop_change );
is( $change->action, 'M' );

$c->revision(3);
$c->_called(0);
$commit = $c->describe_commit;

is( $commit->id, 3 );
is( $commit->log, 'replace file' );
is( $commit->author, $me );
is( scalar @{ $commit->changes }, 1 );

$change = $commit->changes->[0];
is( $change->path, '/file' );
ok( not $change->prop_change );
is( $change->action, 'R' );

$c->revision(4);
$c->_called(0);
$commit = $c->describe_commit;

is( $commit->id, 4 );
is( $commit->log, 'remove file. Über cool with cyrillics: здрасти' );
is( $commit->author, $me );
is( scalar @{ $commit->changes }, 1 );

$change = $commit->changes->[0];
is( $change->path, '/file' );
ok( not $change->prop_change );
is( $change->action, 'D' );


