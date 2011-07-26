package main;
use strict;
use warnings;
use lib qw(privinc);
use My::Builder;

my $builder = My::Builder->new(
    dist_name   => 'App::KGB',
    dist_version_from => 'lib/App/KGB.pm',
    license        => 'gpl',
    build_requires => {
        autodie               => 0,
        'Test::Compile'       => 0,
        'Test::Pod::Coverage' => 0,
        'Test::Pod'           => 0,
        'Test::Simple'        => '0.92',
    },
    requires => {
        perl                           => '5.010',
        'Class::Accessor'              => 0,
        'Digest::SHA'                  => 0,
        'Git'                          => 0,
        'IPC::System::Simple'          => 0,
        'POE::Component::IRC'          => '5.56',
        'POE::Component::Server::SOAP' => 0,
        'POE'                          => 0,
        'Proc::PID::File'              => 0,
        'SOAP::Lite'                   => 0,
# these barf with M::B in perl 5.12[.1] and version.pm available
# we comment themm here as a workaround
# see http://bugs.debian.org/582739 and http://bugs.debian.org/589812
#        'SVN::Fs'                      => 0,
#        'SVN::Repos'                   => 0,
#        'SVN::Core'                    => 0,
        'YAML'                         => 0,
    },
    bindoc_dirs  => [qw(script sbin)],
    install_path => {
        sbin => '/usr/sbin',
        etc  => 'etc'
    },
    sbin_files => { 'script/kgb-bot' => 'sbin/kgb-bot' },
    etc_files => { 'etc/kgb.conf' => 'etc/kgb-bot/kgb.conf' },
    script_files => 'script/kgb-client',
);

$builder->add_build_element('sbin');
$builder->add_build_element('etc');

$builder->create_build_script();
