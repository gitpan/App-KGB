use Test::More;
use Test::Compile;

my @modules = all_pm_files();

eval { require SVN::Fs; 1 } or do {
    warn "SVN::Fs unavailable, skipping compilation test of App::KGB::Client::Subversion\n";
    @modules = grep { $_ !~ m,App/KGB/Client/Subversion.pm$, } @modules;
};

eval { require Git; 1 } or do {
    warn "Git unavailable, skipping compilation test of App::KGB::Client::Git\n";
    @modules = grep { $_ !~ m,App/KGB/Client/Git.pm$, } @modules;
};

pm_file_ok($_) for @modules;

done_testing();
