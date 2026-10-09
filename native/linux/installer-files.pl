use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode :flock F_SETFD);
use IO::Handle;
use POSIX ();
use Socket qw(AF_UNIX SOCK_STREAM SOL_SOCKET SO_PEERCRED sockaddr_un);
use JSON::PP ();

# Linux arm64 UAPI: asm-generic/unistd.h defines renameat2 as 276.
# Debian base tools only. These primitives confer no Home authority.
die "installer files requires Linux arm64\n" unless $^O eq 'linux';
open(my $architecture, '-|', '/usr/bin/uname', '-m') or die "cannot inspect architecture\n";
my $machine = <$architecture>;
close $architecture or die "cannot inspect architecture\n";
die "installer files requires Linux arm64\n" unless $machine eq "aarch64\n";
die "installer files requires root\n" unless $> == 0;
POSIX::setgid(0) == 0 or die "installer files requires root group\n";
umask 0077;
my $operation = shift @ARGV // '';
my $operation_lock;
if (@ARGV >= 4 && $ARGV[0] eq '--lock-owner') {
    shift @ARGV;
    my ($owner_pid, $owner_fd, $lock_path) = splice(@ARGV, 0, 3);
    die "invalid lock owner\n" unless $owner_pid =~ /\A[1-9][0-9]{0,9}\z/ && $owner_fd =~ /\A[0-9]{1,5}\z/;
    my $process_fd = syscall(434, 0 + $owner_pid, 0);
    die "installer lock owner unavailable\n" if $process_fd < 0;
    my $inherited = syscall(438, $process_fd, 0 + $owner_fd, 0);
    POSIX::close($process_fd);
    die "cannot retain installer lock\n" if $inherited < 0;
    open($operation_lock, '+<&=', $inherited) or die "cannot bind retained installer lock\n";
    my @info = stat($operation_lock);
    die "invalid retained installer lock\n" unless S_ISREG($info[2]) && $info[4] == 0 && ($info[2] & 07777) == 0600 && $info[3] == 1;
    my ($lock_dir, $lock_held, $lock_name, $lock_anchor) = parent($lock_path);
    my @named = lstat($lock_anchor);
    die "installer lock path changed\n" unless @named && S_ISREG($named[2]) && $named[0] == $info[0] && $named[1] == $info[1];
    flock($operation_lock, LOCK_EX | LOCK_NB) or die "installer lock is not held\n";
    seek($operation_lock, 0, 0) or die "cannot inspect retained installer lock\n";
    my $marker;
    my $count = sysread($operation_lock, $marker, 128);
    die "invalid retained installer lock marker\n" unless defined($count) && $marker eq "WOTEX_HOME_INSTALL_LOCK\t1\n";
}

sub directory {
    my ($path) = @_;
    die "unsafe directory path\n" unless $path =~ m{\A/} && $path !~ m{//|(?:\A|/)(?:\.|\.\.)(?:/|\z)|[\x00-\x1f]};
    sysopen(my $root, '/', O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "cannot open root directory\n";
    my @held = ($root);
    my $current = $root;
    for my $part (grep { length $_ } split m{/}, $path) {
        sysopen(my $next, '/proc/self/fd/' . fileno($current) . '/' . $part,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "directory component unavailable\n";
        my @info = stat($next);
        # Sticky shared temporary parents are permitted; the immediate parent
        # is checked separately before mutation.
        die "unsafe directory owner or mode\n" unless $info[4] == $> && (($info[2] & 0022) == 0 || ($info[2] & 01000) != 0);
        push @held, $next;
        $current = $next;
    }
    my @info = stat($current);
    die "writable directory parent\n" unless ($info[2] & 0022) == 0;
    return ($current, \@held);
}

sub parent {
    my ($path) = @_;
    die "unsafe file path\n" unless $path =~ m{\A(.+)/([A-Za-z0-9_+@.-]+)\z} && $2 ne '.' && $2 ne '..';
    my ($prefix, $name) = ($1, $2);
    my ($dir, $held) = directory($prefix);
    return ($dir, $held, $name, '/proc/self/fd/' . fileno($dir) . '/' . $name);
}

sub hash_bytes {
    my ($bytes) = @_;
    pipe(my $reader, my $writer) or die "cannot create hash input\n";
    pipe(my $result, my $output) or die "cannot create hash output\n";
    my $pid = fork();
    die "cannot start hash tool\n" unless defined $pid;
    if ($pid == 0) {
        close $writer; close $result;
        open STDIN, '<&', fileno($reader) or die "cannot bind hash input\n";
        open STDOUT, '>&', fileno($output) or die "cannot bind hash output\n";
        exec '/usr/bin/sha256sum';
        die "cannot execute hash tool\n";
    }
    close $reader; close $output;
    my $offset = 0;
    while ($offset < length($bytes)) {
        my $written = syswrite($writer, $bytes, length($bytes) - $offset, $offset);
        die "hash input failed\n" unless defined($written) && $written > 0;
        $offset += $written;
    }
    close $writer;
    my $digest = '';
    while (length($digest) < 128) {
        my $chunk;
        my $count = sysread($result, $chunk, 128 - length($digest));
        die "hash output failed\n" unless defined $count;
        last if $count == 0;
        $digest .= $chunk;
    }
    close $result;
    waitpid($pid, 0);
    die "hash tool failed\n" unless $? == 0 && $digest =~ /\A([0-9a-f]{64})  -\n\z/;
    return $1;
}

sub bytes {
    my ($path, $bound, $mode) = @_;
    sysopen(my $input, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die "owned file unavailable\n";
    my @info = stat($input);
    die "owned file type, owner or mode differs\n" unless S_ISREG($info[2]) && $info[4] == $> && $info[3] == 1 && ($info[2] & 07777) == $mode && $info[7] <= $bound;
    my $bytes = '';
    while (length($bytes) <= $bound) {
        my $chunk;
        my $count = sysread($input, $chunk, 65536);
        die "owned file read failed\n" unless defined $count;
        last if $count == 0;
        $bytes .= $chunk;
    }
    close $input;
    die "owned file exceeds bound\n" if length($bytes) > $bound;
    return $bytes;
}

sub rename_noreplace {
    my ($source_dir, $source_name, $target_dir, $target_name) = @_;
    die "atomic publication refused\n" unless syscall(276, fileno($source_dir), $source_name,
                                                      fileno($target_dir), $target_name, 1) == 0;
    $source_dir->sync or die "source directory sync failed\n";
    $target_dir->sync or die "destination directory sync failed\n";
}

sub sync_tree {
    my ($dir, $counts, $public) = @_;
    my @info = stat($dir);
    die "unsafe staged directory\n" unless $info[4] == $> && ($info[2] & 07022) == 0;
    if (defined $public) {
        die "unsafe release directory group\n" unless $info[5] == 0;
        if ($public) {
            chmod(0755, '/proc/self/fd/' . fileno($dir)) == 1 or die "release directory mode failed\n";
        } else {
            die "release directory mode differs\n" unless ($info[2] & 07777) == 0755;
        }
    }
    die "staged directory bound exceeded\n" if ++$counts->[0] > 20000;
    my $anchor = '/proc/self/fd/' . fileno($dir);
    opendir(my $entries, $anchor) or die "staged directory read failed\n";
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($entries);
    closedir $entries;
    for my $name (@names) {
        die "unsafe staged name\n" unless $name =~ /\A[A-Za-z0-9_+@.-]+\z/;
        my $file = $anchor . '/' . $name;
        my @child = lstat($file);
        die "unsafe staged object\n" unless @child && $child[4] == $> && ($child[2] & 07022) == 0;
        die "unsafe release file group\n" if defined($public) && $child[5] != 0;
        if (S_ISDIR($child[2])) {
            sysopen(my $nested, $file, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "staged directory unavailable\n";
            sync_tree($nested, $counts, $public);
            close $nested;
        }
        elsif (S_ISREG($child[2]) && $child[3] == 1) {
            die "staged file bound exceeded\n" if ++$counts->[1] > 20000;
            $counts->[2] += $child[7];
            die "staged byte bound exceeded\n" if $counts->[2] > 2147483648;
            sysopen(my $input, $file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die "cannot sync staged file\n";
            $input->sync or die "staged file sync failed\n";
            close $input;
        } else { die "nonregular or linked staged object\n"; }
    }
    $dir->sync or die "staged directory sync failed\n";
}

# Update ownership stays outside the issued release. The retained initial
# marker scopes these operations to its own private stage and releases tree.
sub update_owner {
    my ($path, $expected) = @_;
    die "retained installer lock required\n" unless defined $operation_lock;
    die "invalid update owner inputs\n" unless $expected =~ /\A[0-9a-f]{64}\z/ &&
        $path =~ m{\A(.+)/\.installer/owner\.json\z};
    my $base = $1;
    my ($root, $root_held) = directory($base);
    my ($admin, $admin_held) = directory($base . '/.installer');
    my @root = stat($root); my @admin = stat($admin);
    die "update namespace ownership differs\n" unless $root[5] == 0 && $admin[5] == 0 &&
        ($root[2] & 07777) == 0755 && ($admin[2] & 07777) == 0700;
    my ($dir, $held, $name, $anchor) = parent($path);
    my @owner = lstat($anchor);
    die "update owner group differs\n" unless @owner && $owner[5] == 0;
    die "update owner differs\n" unless hash_bytes(bytes($anchor, 65536, 0600)) eq $expected;
    return ($base, [$root_held, $admin_held, $held, $root, $admin, $dir]);
}

sub stage_root {
    my ($base, $stage, $expected) = @_;
    die "invalid update stage inputs\n" unless $expected =~ /\A[0-9a-f]{64}\z/ &&
        $stage =~ m{\A\Q$base\E/\.installer/update-stage-[0-9a-f]{64}\z};
    my ($dir, $held) = directory($stage);
    my @info = stat($dir);
    die "update stage ownership differs\n" unless $info[5] == 0 && ($info[2] & 07777) == 0700;
    my $marker = '/proc/self/fd/' . fileno($dir) . '/stage.json';
    my @marker = lstat($marker);
    die "update stage marker group differs\n" unless @marker && $marker[5] == 0;
    die "update stage marker differs\n" unless hash_bytes(bytes($marker, 65536, 0600)) eq $expected;
    opendir(my $entries, '/proc/self/fd/' . fileno($dir)) or die "stage inspection failed\n";
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($entries);
    closedir $entries;
    die "foreign stage objects\n" unless join(' ', @names) eq 'stage.json' ||
        join(' ', @names) eq 'release stage.json';
    return ($dir, $held);
}

sub hash_file {
    my ($input) = @_;
    pipe(my $result, my $output) or die "cannot create staged hash output\n";
    my $pid = fork();
    die "cannot start staged hash tool\n" unless defined $pid;
    if ($pid == 0) {
        close $result;
        open STDIN, '<&', fileno($input) or die "cannot bind staged hash input\n";
        open STDOUT, '>&', fileno($output) or die "cannot bind staged hash output\n";
        exec '/usr/bin/sha256sum';
        die "cannot execute staged hash tool\n";
    }
    close $output;
    my $digest = '';
    while (length($digest) < 128) {
        my $chunk;
        my $count = sysread($result, $chunk, 128 - length($digest));
        die "staged hash output failed\n" unless defined $count;
        last if $count == 0;
        $digest .= $chunk;
    }
    close $result;
    waitpid($pid, 0);
    die "staged hash tool failed\n" unless $? == 0 && $digest =~ /\A([0-9a-f]{64})  -\n\z/;
    return $1;
}

sub same_stage_info {
    my ($a, $b, $identity_only) = @_;
    my @fields = $identity_only ? (0, 1, 2, 3, 4, 5) : (0, 1, 2, 3, 4, 5, 7, 9, 10);
    for my $field (@fields) { return 0 unless $a->[$field] == $b->[$field]; }
    return 1;
}

sub stage_snapshot {
    my ($dir, $relative, $device, $counts, $rows) = @_;
    my @info = stat($dir);
    die "unsafe staged directory\n" unless S_ISDIR($info[2]) && $info[4] == 0 && $info[5] == 0 &&
        $info[0] == $device && (($info[2] & 07777) == 0700 || ($info[2] & 07777) == 0755);
    die "stage directory bound exceeded\n" if ++$counts->[0] > 20000;
    my $anchor = '/proc/self/fd/' . fileno($dir);
    opendir(my $entries, $anchor) or die "stage enumeration failed\n";
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($entries);
    closedir $entries;
    $$rows .= 'D' . "\t" . sprintf('%o', $info[2] & 07777) . "\t$relative\n";
    my %children;
    for my $name (@names) {
        die "unsafe stage name\n" unless $name =~ /\A[A-Za-z0-9_+@.-]+\z/;
        my $next = $relative eq '.' ? $name : $relative . '/' . $name;
        die "stage path bound exceeded\n" if length($next) > 1024 || ($next =~ tr{/}{/}) > 64;
        my $path = $anchor . '/' . $name;
        my @named = lstat($path);
        die "unsafe stage object\n" unless @named && $named[0] == $device &&
            $named[4] == 0 && $named[5] == 0 && ($named[2] & 07022) == 0;
        if (S_ISDIR($named[2])) {
            sysopen(my $nested, $path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "stage directory unavailable\n";
            my @opened = stat($nested);
            die "stage directory changed\n" unless same_stage_info(\@named, \@opened, 0);
            $children{$name} = stage_snapshot($nested, $next, $device, $counts, $rows);
            close $nested;
        } elsif (S_ISREG($named[2]) && $named[3] == 1) {
            die "stage file bound exceeded\n" if ++$counts->[1] > 20000;
            $counts->[2] += $named[7];
            die "stage byte bound exceeded\n" if $counts->[2] > 2147483648;
            sysopen(my $input, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die "stage file unavailable\n";
            my @opened = stat($input);
            die "stage file changed\n" unless same_stage_info(\@named, \@opened, 0);
            my $sha = hash_file($input);
            my @after = stat($input);
            my @renamed = lstat($path);
            die "stage file changed\n" unless @renamed && same_stage_info(\@opened, \@after, 0) &&
                same_stage_info(\@opened, \@renamed, 0);
            close $input;
            $$rows .= 'F' . "\t" . sprintf('%o', $named[2] & 07777) . "\t$named[7]\t$sha\t$next\n";
            $children{$name} = {info => \@named, sha => $sha};
        } else { die "nonregular or linked stage object\n"; }
        die "stage snapshot bound exceeded\n" if length($$rows) > 4194304;
    }
    my @after = stat($dir);
    die "stage directory changed\n" unless same_stage_info(\@info, \@after, 0);
    return {info => \@info, children => \%children};
}

sub remove_stage_tree {
    my ($dir, $snapshot) = @_;
    my @info = stat($dir);
    die "stage directory changed\n" unless same_stage_info($snapshot->{info}, \@info, 0);
    my $anchor = '/proc/self/fd/' . fileno($dir);
    opendir(my $entries, $anchor) or die "stage enumeration failed\n";
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($entries);
    closedir $entries;
    die "stage children changed\n" unless join(' ', @names) eq join(' ', sort keys %{$snapshot->{children}});
    for my $name (@names) {
        my $path = $anchor . '/' . $name;
        my $node = $snapshot->{children}{$name};
        my @named = lstat($path);
        die "stage object changed\n" unless @named && same_stage_info($node->{info}, \@named, 0);
        if (exists $node->{children}) {
            sysopen(my $nested, $path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "stage directory unavailable\n";
            remove_stage_tree($nested, $node);
            my @held = stat($nested); my @final = lstat($path);
            die "stage directory changed\n" unless @final && same_stage_info(\@held, \@final, 1);
            rmdir($path) or die "stage directory removal failed\n";
            close $nested;
        } else {
            sysopen(my $input, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die "stage file unavailable\n";
            my @opened = stat($input);
            die "stage file changed\n" unless same_stage_info($node->{info}, \@opened, 0) &&
                hash_file($input) eq $node->{sha};
            my @final = lstat($path);
            die "stage file changed\n" unless @final && same_stage_info(\@opened, \@final, 0);
            unlink($path) or die "stage file removal failed\n";
            close $input;
        }
    }
    $dir->sync or die "stage removal directory sync failed\n";
}

sub read_exact {
    my ($input, $size) = @_;
    my $bytes = '';
    while (length($bytes) < $size) {
        my $chunk;
        my $count = sysread($input, $chunk, $size - length($bytes));
        die "maintenance input unavailable\n" unless defined($count) && $count > 0;
        $bytes .= $chunk;
    }
    return $bytes;
}

sub write_exact {
    my ($output, $bytes) = @_;
    my $offset = 0;
    while ($offset < length($bytes)) {
        my $count = syswrite($output, $bytes, length($bytes) - $offset, $offset);
        die "maintenance output unavailable\n" unless defined($count) && $count > 0;
        $offset += $count;
    }
}

sub maintenance_endpoint {
    my ($path, $uid) = @_;
    die "invalid maintenance socket path\n" unless length($path) <= 100 &&
        $path =~ m{\A/(?:[A-Za-z0-9_+@.-]+/)*[A-Za-z0-9_+@.-]+\z} &&
        $path !~ m{(?:\A|/)(?:\.|\.\.)(?:/|\z)};
    my @parts = grep { length $_ } split m{/}, $path;
    my $name = pop @parts;
    sysopen(my $dir, '/', O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "socket parent unavailable\n";
    my @held = ($dir);
    for my $index (0 .. $#parts) {
        sysopen(my $next, '/proc/self/fd/' . fileno($dir) . '/' . $parts[$index],
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "socket parent unavailable\n";
        my @info = stat($next);
        if ($index == $#parts) {
            die "maintenance socket parent differs\n" unless $info[4] == $uid && ($info[2] & 07777) == 0700;
        } else {
            # A sticky shared temporary ancestor is permitted for private
            # probes. Every later component is anchored and refuses links.
            die "unsafe socket ancestor\n" unless ($info[4] == 0 || $info[4] == $uid) &&
                (($info[2] & 0022) == 0 || ($info[4] == 0 && ($info[2] & 01000)));
        }
        push @held, $next;
        $dir = $next;
    }
    my $anchor = '/proc/self/fd/' . fileno($dir) . '/' . $name;
    my @endpoint = lstat($anchor);
    die "maintenance socket differs\n" unless @endpoint && S_ISSOCK($endpoint[2]) &&
        $endpoint[4] == $uid && ($endpoint[2] & 07777) == 0600;
    return ($anchor, \@held);
}

if ($operation eq 'assert-lock') {
    die "retained installer lock required\n" unless defined $operation_lock;
    print "LOCK_OK\n";
}
elsif ($operation eq 'maintenance') {
    die "retained installer lock required\n" unless defined $operation_lock;
    die "usage: maintenance UID SOCKET FRAME_SIZE\n" unless @ARGV == 3;
    my ($uid, $path, $size) = @ARGV;
    die "invalid maintenance client inputs\n" unless $uid =~ /\A[1-9][0-9]{2}\z/ &&
        $uid >= 100 && $uid <= 999 && $size =~ /\A[1-9][0-9]{0,3}\z/ && $size <= 4096;
    my $parent_pid = $$;
    my $pid = fork();
    die "cannot start maintenance client\n" unless defined $pid;
    if ($pid == 0) {
        # Drop every group and all UID/GID privilege before reading a bearer
        # or opening the socket. UID changes clear PDEATHSIG: install it after
        # the drop and repeat the parent check to close the intervening race.
        die "cannot drop maintenance client identity\n" unless syscall(159, 0, 0) == 0 &&
            POSIX::setgid(0 + $uid) == 0 && POSIX::setuid(0 + $uid) == 0 &&
            $< == $uid && $> == $uid;
        die "cannot guard maintenance client lifetime\n" unless
            syscall(167, 1, 9, 0, 0, 0) == 0 && getppid() == $parent_pid &&
            syscall(167, 4, 0, 0, 0, 0) == 0;
        close $operation_lock;
        $SIG{ALRM} = sub { die "maintenance client timed out\n"; };
        alarm 15;
        my $frame = read_exact(\*STDIN, 0 + $size);
        die "invalid maintenance frame\n" unless length($frame) >= 5 &&
            unpack('N', substr($frame, 0, 4)) == length($frame) - 4;
        my $request = eval { JSON::PP->new->utf8->max_depth(4)->decode(substr($frame, 4)) };
        die "invalid maintenance request\n" unless ref($request) eq 'HASH';
        my $op = $request->{operation} // '';
        my %fields = (
            maintenance_status => 'api_version credential operation',
            maintenance_update_status => 'api_version credential operation',
            maintenance_operation_status => 'api_version authority_epoch credential operation operation_id',
            begin_maintenance => 'api_version authority_epoch credential expected_revision operation operation_id'
        );
        die "unsupported maintenance request\n" unless exists $fields{$op} &&
            join(' ', sort keys %$request) eq $fields{$op} &&
            !ref($request->{api_version}) && $request->{api_version} eq '1' &&
            !ref($request->{credential}) && $request->{credential} =~ /\A[A-Za-z0-9_-]{43}\z/;
        my ($anchor, $held) = maintenance_endpoint($path, 0 + $uid);
        socket(my $socket, AF_UNIX, SOCK_STREAM, 0) or die "maintenance socket unavailable\n";
        connect($socket, sockaddr_un($anchor)) or die "maintenance socket unavailable\n";
        my $peer = getsockopt($socket, SOL_SOCKET, SO_PEERCRED);
        die "maintenance peer differs\n" unless defined($peer) && length($peer) == 12 &&
            (unpack('iII', $peer))[1] == $uid;
        write_exact($socket, $frame);
        my $response_size = unpack('N', read_exact($socket, 4));
        die "maintenance response exceeds bound\n" unless $response_size > 0 && $response_size <= 4096;
        my $body = read_exact($socket, $response_size);
        close $socket;
        write_exact(\*STDOUT, pack('N', (unpack('iII', $peer))[0]) . $body);
        alarm 0;
        exit 0;
    }
    while (waitpid($pid, 0) < 0) { next if $!{EINTR}; die "cannot wait for maintenance client\n"; }
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
}
elsif ($operation eq 'exec' || $operation eq 'copy') {
    if ($operation eq 'copy') {
        die "usage: copy SOURCE MANIFEST PIN DESTINATION\n" unless @ARGV == 4;
        my $tools = $0; $tools =~ s{/[^/]+\z}{};
        unshift @ARGV, $tools . '/bootstrap';
    } else {
        die "retained installer lock required\n" unless defined $operation_lock && @ARGV >= 1;
    }
    my $parent_pid = $$;
    my $pid = fork();
    die "cannot start installer tool\n" unless defined $pid;
    if ($pid == 0) {
        # No privileged tool can outlive this lock-retaining parent.
        die "cannot guard installer tool lifetime\n" unless syscall(167, 1, 9, 0, 0, 0) == 0 && getppid() == $parent_pid;
        exec { $ARGV[0] } @ARGV;
        die "cannot execute installer tool\n";
    }
    while (waitpid($pid, 0) < 0) { next if $!{EINTR}; die "cannot wait for installer tool\n"; }
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
}
elsif ($operation eq 'lock-run') {
    die "usage: lock-run LOCK EXECUTABLE ARGS\n" unless @ARGV >= 2;
    my $path = shift @ARGV;
    my ($dir, $held, $name, $anchor) = parent($path);
    my $marker = "WOTEX_HOME_INSTALL_LOCK\t1\n";
    if (sysopen(my $created, $anchor, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)) {
        print $created $marker or die "cannot mark installer lock\n";
        $created->flush or die "installer lock flush failed\n";
        $created->sync or die "installer lock sync failed\n";
        close $created;
        $dir->sync or die "installer lock parent sync failed\n";
    }
    die "foreign installer lock\n" unless bytes($anchor, 128, 0600) eq $marker;
    sysopen(my $lock, $anchor, O_RDWR | O_NOFOLLOW | O_NONBLOCK) or die "installer lock unavailable\n";
    flock($lock, LOCK_EX | LOCK_NB) or die "another installer holds the lock\n";
    fcntl($lock, F_SETFD, 0) or die "cannot inherit installer lock\n";
    $ENV{WOTEX_HOME_INSTALL_LOCK_FD} = fileno($lock);
    $ENV{WOTEX_HOME_INSTALL_LOCK_PATH} = $path;
    $ENV{LANG} = 'C.UTF-8';
    $ENV{LC_ALL} = 'C.UTF-8';
    $ENV{ERL_FLAGS} = '+S 4:4 +SDcpu 2 +SDio 2';
    $ENV{ERL_CRASH_DUMP} = '/dev/null';
    my $pid = fork();
    die "cannot start locked operation\n" unless defined $pid;
    if ($pid == 0) { exec { $ARGV[0] } @ARGV; die "cannot execute locked operation\n"; }
    $SIG{TERM} = sub { kill 'TERM', $pid; };
    $SIG{INT} = sub { kill 'INT', $pid; };
    while (waitpid($pid, 0) < 0) { next if $!{EINTR}; die "cannot wait for locked operation\n"; }
    my $status = $?;
    close $lock;
    exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
}
elsif ($operation eq 'write-new' || $operation eq 'replace') {
    die "usage: write-new/replace PATH OCTAL_MODE NEW_SHA SIZE [OLD_SHA]\n" unless @ARGV == ($operation eq 'replace' ? 5 : 4);
    my ($path, $mode_text, $digest, $size, $old) = @ARGV;
    die "invalid write inputs\n" unless $mode_text =~ /\A(?:600|644)\z/ && $digest =~ /\A[0-9a-f]{64}\z/ && $size =~ /\A(?:0|[1-9][0-9]{0,6})\z/ && $size <= 1048576 && (!defined($old) || $old =~ /\A[0-9a-f]{64}\z/);
    my $mode = oct($mode_text);
    my ($dir, $held, $name, $anchor) = parent($path);
    my $input = '';
    while (length($input) < $size) {
        my $chunk;
        my $remaining = $size - length($input);
        my $count = sysread(STDIN, $chunk, $remaining > 65536 ? 65536 : $remaining);
        die "write input failed or truncated\n" unless defined($count) && $count > 0;
        $input .= $chunk;
    }
    die "write input differs or exceeds bound\n" unless length($input) <= 1048576 && hash_bytes($input) eq $digest;
    if (defined $old) { die "old file differs\n" unless hash_bytes(bytes($anchor, 1048576, $mode)) eq $old; }
    my $temporary = '.woh-install-' . $$ . '-' . $name;
    my $staged = '/proc/self/fd/' . fileno($dir) . '/' . $temporary;
    sysopen(my $output, $staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, $mode) or die "temporary write conflict\n";
    my $ok = eval {
        print $output $input or die "temporary write failed\n";
        $output->flush or die "temporary file flush failed\n";
        chmod($mode, $staged) == 1 or die "temporary file mode failed\n";
        $output->sync or die "temporary file sync failed\n";
        close $output or die "temporary close failed\n";
        if (defined $old) {
            die "old file changed\n" unless hash_bytes(bytes($anchor, 1048576, $mode)) eq $old;
            die "atomic replacement failed\n" unless syscall(276, fileno($dir), $temporary, fileno($dir), $name, 0) == 0;
            $dir->sync or die "replacement directory sync failed\n";
        } else { rename_noreplace($dir, $temporary, $dir, $name); }
        1;
    };
    unless ($ok) { my $error = $@; close $output; unlink $staged; die $error; }
    print "WRITE_OK\n";
}
elsif ($operation eq 'publish' || $operation eq 'sync') {
    die "usage: publish SOURCE DESTINATION OWNER_SHA | sync SOURCE OWNER_SHA\n" unless @ARGV == ($operation eq 'publish' ? 3 : 2);
    my ($source, $target, $owner) = $operation eq 'publish' ? @ARGV : ($ARGV[0], $ARGV[0], $ARGV[1]);
    die "invalid owner digest\n" unless $owner =~ /\A[0-9a-f]{64}\z/;
    my ($source_dir, $source_held, $source_name, $source_anchor) = parent($source);
    my ($target_dir, $target_held, $target_name, $target_anchor) = parent($target);
    my ($root, $held) = directory($source);
    sysopen(my $owner_dir, '/proc/self/fd/' . fileno($root) . '/.installer', O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "staged ownership directory unavailable\n";
    my $marker = '/proc/self/fd/' . fileno($owner_dir) . '/owner.json';
    die "staged owner differs\n" unless hash_bytes(bytes($marker, 65536, 0600)) eq $owner;
    sync_tree($root, [0, 0, 0]);
    my @held_root = stat($root);
    my @named_root = lstat($source_anchor);
    die "staged directory changed\n" unless @named_root && $named_root[0] == $held_root[0] && $named_root[1] == $held_root[1];
    if ($operation eq 'publish') {
        rename_noreplace($source_dir, $source_name, $target_dir, $target_name);
        print "PUBLISH_OK\n";
    } else {
        $source_dir->sync or die "namespace parent sync failed\n";
        print "SYNC_OK\n";
    }
}
elsif ($operation eq 'publish-release') {
    die "usage: publish-release SOURCE DESTINATION OWNER_PATH OWNER_SHA STAGE_SHA TREE_SHA INVENTORY_SHA\n" unless @ARGV == 7;
    my ($source, $target, $owner_path, $owner, $marker, $tree, $inventory) = @ARGV;
    die "invalid release digests\n" unless $tree =~ /\A[0-9a-f]{64}\z/ && $inventory =~ /\A[0-9a-f]{64}\z/;
    my ($base, $ownership) = update_owner($owner_path, $owner);
    die "release publication outside owned namespace\n" unless
        $source =~ m{\A(\Q$base\E/\.installer/update-stage-[0-9a-f]{64})/release\z};
    my $stage = $1;
    die "release publication outside owned namespace\n" unless
        $target =~ m{\A\Q$base\E/releases/[0-9a-f]{64}\z};
    my ($staged, $stage_held) = stage_root($base, $stage, $marker);
    my ($source_dir, $source_held, $source_name, $source_anchor) = parent($source);
    my ($target_dir, $target_held, $target_name, $target_anchor) = parent($target);
    my @parent = stat($target_dir);
    die "release parent differs\n" unless $parent[5] == 0 && ($parent[2] & 07777) == 0755;
    die "occupied release preserved\n" if lstat($target_anchor);
    my @stage_info = stat($staged);
    my $rows = "WOTEX_HOME_INSTALL_STAGE\t1\n";
    stage_snapshot($staged, '.', $stage_info[0], [0, 0, 0], \$rows);
    die "staged tree differs\n" unless hash_bytes($rows) eq $tree;
    my ($root, $held) = directory($source);
    my $report = '/proc/self/fd/' . fileno($root) . '/release-inventory.json';
    die "release inventory differs\n" unless hash_bytes(bytes($report, 2097152, 0644)) eq $inventory;
    sync_tree($root, [0, 0, 0], 1);
    my @held_root = stat($root); my @named_root = lstat($source_anchor);
    die "staged release changed\n" unless @named_root && same_stage_info(\@held_root, \@named_root, 1);
    update_owner($owner_path, $owner);
    rename_noreplace($source_dir, $source_name, $target_dir, $target_name);
    print "RELEASE_PUBLISH_OK\n";
}
elsif ($operation eq 'sync-release') {
    die "usage: sync-release RELEASE OWNER_PATH OWNER_SHA INVENTORY_SHA\n" unless @ARGV == 4;
    my ($source, $owner_path, $owner, $inventory) = @ARGV;
    die "invalid release inventory digest\n" unless $inventory =~ /\A[0-9a-f]{64}\z/;
    my ($base, $ownership) = update_owner($owner_path, $owner);
    die "release sync outside owned namespace\n" unless $source =~ m{\A\Q$base\E/releases/[0-9a-f]{64}\z};
    my ($source_dir, $source_held, $source_name, $source_anchor) = parent($source);
    my @parent = stat($source_dir);
    die "release parent differs\n" unless $parent[5] == 0 && ($parent[2] & 07777) == 0755;
    my ($root, $held) = directory($source);
    my $report = '/proc/self/fd/' . fileno($root) . '/release-inventory.json';
    die "release inventory differs\n" unless hash_bytes(bytes($report, 2097152, 0644)) eq $inventory;
    sync_tree($root, [0, 0, 0], 0);
    my @held_root = stat($root); my @named_root = lstat($source_anchor);
    die "published release changed\n" unless @named_root && same_stage_info(\@held_root, \@named_root, 1);
    update_owner($owner_path, $owner);
    $source_dir->sync or die "release parent sync failed\n";
    print "RELEASE_SYNC_OK\n";
}
elsif ($operation eq 'remove-stage') {
    die "usage: remove-stage STAGE OWNER_PATH OWNER_SHA STAGE_SHA TREE_SHA\n" unless @ARGV == 5;
    my ($stage, $owner_path, $owner, $marker, $tree) = @ARGV;
    die "invalid stage tree digest\n" unless $tree =~ /\A[0-9a-f]{64}\z/;
    my ($base, $ownership) = update_owner($owner_path, $owner);
    my ($root, $held) = stage_root($base, $stage, $marker);
    my ($dir, $parent_held, $name, $anchor) = parent($stage);
    my @info = stat($root); my @named = lstat($anchor);
    die "stage name changed\n" unless @named && same_stage_info(\@info, \@named, 0);
    my $rows = "WOTEX_HOME_INSTALL_STAGE\t1\n";
    my $snapshot = stage_snapshot($root, '.', $info[0], [0, 0, 0], \$rows);
    die "stage tree differs; retained\n" unless hash_bytes($rows) eq $tree;
    update_owner($owner_path, $owner);
    remove_stage_tree($root, $snapshot);
    my @final = lstat($anchor); my @held_final = stat($root);
    die "stage name changed\n" unless @final && same_stage_info(\@held_final, \@final, 1);
    rmdir($anchor) or die "stage root removal failed\n";
    $dir->sync or die "stage parent sync failed\n";
    print "STAGE_REMOVE_OK\n";
}
elsif ($operation eq 'mkdir') {
    die "usage: mkdir PATH OCTAL_MODE UID GID\n" unless @ARGV == 4;
    my ($path, $mode_text, $uid, $gid) = @ARGV;
    die "invalid directory inputs\n" unless $mode_text =~ /\A(?:700|750|755)\z/ && $uid =~ /\A[0-9]{1,10}\z/ && $gid =~ /\A[0-9]{1,10}\z/;
    my ($dir, $held, $name, $anchor) = parent($path);
    my $temporary = '.woh-install-' . $$ . '-' . $name;
    my $staged = '/proc/self/fd/' . fileno($dir) . '/' . $temporary;
    mkdir($staged, 0700) or die "temporary directory conflict\n";
    my $ok = eval {
        chmod(oct($mode_text), $staged) == 1 or die "directory mode failed\n";
        chown($uid, $gid, $staged) == 1 or die "directory ownership failed\n";
        sysopen(my $created, $staged, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "directory sync open failed\n";
        $created->sync or die "directory sync failed\n";
        close $created;
        rename_noreplace($dir, $temporary, $dir, $name);
        1;
    };
    unless ($ok) { my $error = $@; rmdir $staged; die $error; }
    print "MKDIR_OK\n";
}
elsif ($operation eq 'remove') {
    die "usage: remove PATH OCTAL_MODE EXPECTED_SHA\n" unless @ARGV == 3;
    my ($path, $mode_text, $digest) = @ARGV;
    die "invalid removal inputs\n" unless $mode_text =~ /\A(?:600|644)\z/ && $digest =~ /\A[0-9a-f]{64}\z/;
    my ($dir, $held, $name, $anchor) = parent($path);
    die "removal file differs\n" unless hash_bytes(bytes($anchor, 1048576, oct($mode_text))) eq $digest;
    unlink($anchor) or die "owned removal failed\n";
    $dir->sync or die "removal directory sync failed\n";
    print "REMOVE_OK\n";
}
else { die "unknown installer file operation\n"; }
