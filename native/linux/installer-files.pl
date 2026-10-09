use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode :flock F_SETFD);
use IO::Handle;
use POSIX ();

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
    my ($dir, $counts) = @_;
    my @info = stat($dir);
    die "unsafe staged directory\n" unless $info[4] == $> && ($info[2] & 07022) == 0;
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
        if (S_ISDIR($child[2])) {
            sysopen(my $nested, $file, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "staged directory unavailable\n";
            sync_tree($nested, $counts);
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

if ($operation eq 'assert-lock') {
    die "retained installer lock required\n" unless defined $operation_lock;
    print "LOCK_OK\n";
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
elsif ($operation eq 'mkdir') {
    die "usage: mkdir PATH OCTAL_MODE UID GID\n" unless @ARGV == 4;
    my ($path, $mode_text, $uid, $gid) = @ARGV;
    die "invalid directory inputs\n" unless $mode_text =~ /\A(?:700|750|755)\z/ && $uid =~ /\A[0-9]{1,10}\z/ && $gid =~ /\A[0-9]{1,10}\z/;
    my ($dir, $held, $name, $anchor) = parent($path);
    mkdir($anchor, oct($mode_text)) or die "directory already exists or unavailable\n";
    chmod(oct($mode_text), $anchor) == 1 or die "directory mode failed\n";
    chown($uid, $gid, $anchor) == 1 or die "directory ownership failed\n";
    sysopen(my $created, $anchor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "directory sync open failed\n";
    $created->sync or die "directory sync failed\n";
    close $created;
    $dir->sync or die "directory parent sync failed\n";
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
