use strict;
use warnings;
use POSIX ();

die "Linux root required\n" unless $^O eq 'linux' && $> == 0;
my $pin = $ENV{WOTEX_HOME_BOOTSTRAP_PIN} // '';
my $source = $ENV{WOTEX_HOME_EXPECT_SOURCE_REVISION} // '';
die "public source/pin required\n" unless $pin =~ /\A[0-9a-f]{64}\z/ && $source =~ /\A[0-9a-f]{40}\z/;
die "probe requires no installed Home namespace\n" if lstat('/opt/wotex-home');

sub check {
    my ($input, $reason) = @_;
    pipe(my $receive, my $send) or die "probe output pipe unavailable\n";
    pipe(my $read, my $write) or die "probe input pipe unavailable\n";
    my $pid = fork();
    die "probe child unavailable\n" unless defined $pid;
    if ($pid == 0) {
        close $receive; close $write;
        open STDIN, '<&', fileno($read) or die "probe input unavailable\n";
        open STDOUT, '>&', fileno($send) or die "probe output unavailable\n";
        open STDERR, '>&', fileno($send) or die "probe diagnostics unavailable\n";
        close $read; close $send;
        exec '/trusted/install', '--development', 'update', '/release', '/bootstrap.tsv', $pin;
        die "probe launcher unavailable\n";
    }
    close $read; close $send;
    print $write $input or die "probe input failed\n";
    close $write or die "probe input close failed\n";
    my $output = '';
    while (1) {
        my $bytes;
        my $count = sysread($receive, $bytes, 4096);
        die "probe output failed\n" unless defined $count;
        last unless $count;
        $output .= $bytes;
        die "probe output exceeded bound\n" if length($output) > 8192;
    }
    close $receive;
    waitpid($pid, 0) == $pid or die "probe child wait failed\n";
    die "public update did not refuse in absent installation\n" if $? == 0;
    die "public bootstrap source/pin differs\n" unless
        $output =~ /VERIFIED_STAGE\t[^\t\n]+\t\Q$source\E\t\Q$pin\E\n/;
    die "public update refusal differs\n" unless $output =~ /release update refused: \Q$reason\E\n/;
    die "credential appeared in diagnostics\n" if index($output, 'A' x 43) >= 0;
    die "public update created installation\n" if lstat('/opt/wotex-home');
    opendir(my $temporary, '/var/tmp') or die "probe cleanup observation failed\n";
    my @left = grep { /\A\.wotex-home-bootstrap-/ } readdir($temporary);
    closedir $temporary;
    die "public bootstrap custody remained\n" if @left;
}

# Both cases execute the real trusted bootstrap, fixed marked lock, packaged
# ERTS/CLI and bounded stdin reader. The bearer is a synthetic all-zero fixture.
# No installed controller exists, so no service or Store action can succeed.
check('A' x 43 . "\n", 'update_ownership_unavailable');
check('A' x 42 . "B\n", 'update_credential_refused');
print "PACKAGED_UPDATE_ENTRY_OK source=$source; bounded stdin and absent-installation refusal, no installed-service or physical qualification\n";
