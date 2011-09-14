package My::Builder;
use strict;
use warnings;

use base qw(Module::Build);

sub ACTION_orig {
    my $self = shift;
    $self->ACTION_manifest();
    $self->ACTION_dist();
    my $dn       = $self->dist_name;
    my $ver      = $self->dist_version;
    my $pkg_name = 'kgb-bot';
    my $target_dist = "../$dn-$ver.tar.gz";
    my $target_orig = "../$pkg_name\_$ver.orig.tar.gz";

    rename "$dn-$ver.tar.gz", $target_orig or die $!;
    if ( -e $target_dist ) {
        unlink $target_dist or die "unlink($target_dist): $!\n";
    }
    link $target_orig, $target_dist or die "link failed: $!\n";

    $self->ACTION_distclean;
    unlink 'MANIFEST.bak';
    print "$target_orig ready.\n";
    print "with $target_dist linked to it.\n";
}

1;

