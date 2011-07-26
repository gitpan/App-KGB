use Test::More tests => 1;
use autodie;

system 'sh -n eg/post-commit';

ok(1);
