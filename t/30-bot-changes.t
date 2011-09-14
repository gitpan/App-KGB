use Test::More tests => 2;

use App::KGB::Change;

sub is_common_dir {
    my ( $cs, $wanted ) = @_;

    is( App::KGB::Change->detect_common_dir(
            [ map ( App::KGB::Change->new($_), @$cs ) ]
        ),
        $wanted
    );
}

is_common_dir( [ '(A)foo/bar', '(A)foo/dar', '(A)foo/bar/dar' ], 'foo' );
is_common_dir( [ '(A)debian/patches/series', '(A)debian/patches/moo.patch' ], 'debian/patches' );
