use Test::More;
use Test::Compile;

my @modules = all_pm_files();

eval { require SVN::Fs; 1 } or do {
    diag $@;
    diag "SVN::Fs unavailable, skipping compilation test of App::KGB::Client::Subversion";
    @modules = grep { $_ !~ m,App/KGB/Client/Subversion.pm$, } @modules;
};

eval { require Git; 1 } or do {
    diag $@;
    diag "Git unavailable, skipping compilation test of App::KGB::Client::Git";
    @modules = grep { $_ !~ m,App/KGB/Client/Git.pm$, } @modules;
};

pm_file_ok($_) for @modules;

done_testing();
