use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode);
use POSIX ();

die "usage: install --development install|uninstall SOURCE MANIFEST SHA256\n" unless @ARGV == 5 && $ARGV[0] eq '--development' && $ARGV[1] =~ /\A(?:install|uninstall)\z/;
die "Linux root required\n" unless $^O eq 'linux' && $> == 0;
POSIX::setgid(0) == 0 or die "root group required\n";
my (undef, $action, $source, $manifest, $pin) = @ARGV;
die "absolute inputs and SHA256 required\n" unless $source =~ m{\A/} && $manifest =~ m{\A/} && $pin =~ /\A[0-9a-f]{64}\z/;
my $tools = $0;
$tools =~ s{/[^/]+\z}{};
umask 0077;
sysopen(my $random, '/dev/urandom', O_RDONLY) or die "private staging identity unavailable\n";
my $nonce;
sysread($random, $nonce, 32) == 32 or die "private staging identity unavailable\n";
close $random;
my $private = '/var/tmp/.wotex-home-bootstrap-' . unpack('H*',$nonce);
my @parent = lstat('/var/tmp');
die "unsafe bootstrap parent\n" unless @parent && S_ISDIR($parent[2]) && $parent[4] == 0 && (($parent[2] & 0022) == 0 || ($parent[2] & 01000) != 0);
mkdir($private,0700) or die "cannot create private bootstrap staging\n";
my $release = $private . '/release';
sub cleanup {
    my ($directory, $bound) = @_;
    sysopen(my $held, $directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "private cleanup directory unavailable\n";
    my @info = stat($held);
    die "private cleanup ownership differs\n" unless $info[4] == 0;
    my $anchor = '/proc/self/fd/' . fileno($held);
    opendir(my $entries, $anchor) or die "private cleanup enumeration failed\n";
    my @names = grep { $_ ne '.' && $_ ne '..' } readdir($entries);
    closedir $entries;
    for my $name (@names) {
        die "private cleanup exceeds bound\n" if ++$$bound > 24000;
        my $target = $anchor . '/' . $name;
        my @child = lstat($target);
        die "private cleanup ownership differs\n" unless @child && $child[4] == 0;
        if (S_ISDIR($child[2])) { cleanup($target,$bound); rmdir($target) or die "private cleanup directory removal failed\n"; }
        elsif (S_ISREG($child[2]) || S_ISLNK($child[2])) { unlink($target) or die "private cleanup file removal failed\n"; }
        else { die "private cleanup object unsupported\n"; }
    }
    close $held;
}
system($tools . '/bootstrap', $source, $manifest, $pin, $release);
unless ($? == 0) {
    my $count = 0; cleanup($private,\$count); rmdir($private);
    die "bootstrap verification refused\n";
}
# Verify/copy before any inspected code executes. The local temporary filesystem
# must permit ERTS execution; a noexec failure performs no installation.
my @installers = glob($release . '/lib/wotex_home-*/priv/linux-install/installer-files');
unless (@installers == 1) {
    my $count = 0; cleanup($private,\$count);
    rmdir($private) or die "private bootstrap cleanup failed\n";
    die "exact installer payload missing\n";
}
my $installer = $installers[0];
$ENV{WOTEX_HOME_INSTALL_RELEASE} = $release;
$ENV{WOTEX_HOME_INSTALL_MANIFEST} = $manifest;
$ENV{WOTEX_HOME_INSTALL_PIN} = $pin;
$ENV{WOTEX_HOME_INSTALL_ACTION} = $action;
my $script = 'Woh.Tool.LinuxInstallerCLI.main()';
# The file launcher clears environment; public inputs therefore travel through
# explicit env arguments after the lock has been acquired.
system($installer,'lock-run','/run/wotex-home-installer.lock','/usr/bin/env',
       'WOTEX_HOME_INSTALL_RELEASE=' . $release, 'WOTEX_HOME_INSTALL_MANIFEST=' . $manifest,
       'WOTEX_HOME_INSTALL_PIN=' . $pin, 'WOTEX_HOME_INSTALL_ACTION=' . $action,
       'RELEASE_TMP=' . $private . '/runtime', $release . '/bin/wotex_home','eval',$script);
my $status = $?;
my $count = 0;
cleanup($private,\$count);
rmdir($private) or die "private bootstrap cleanup failed\n";
die "installer failed; owned lifecycle record or inert installation staging retained\n" unless $status == 0;
print "INSTALLER_COMPLETE\n";
