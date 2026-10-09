use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode);

# Debian base tools only; no Home, Erlang, compiler or inspected code runs.
die "usage: bootstrap SOURCE MANIFEST SHA256 PRIVATE_DESTINATION\n" unless @ARGV == 4;
my ($source, $manifest, $pin, $destination) = @ARGV;
die "bootstrap requires Linux\n" unless $^O eq 'linux';
die "invalid bootstrap pin\n" unless $pin =~ /\A[0-9a-f]{64}\z/;
die "absolute paths required\n" unless $source =~ m{\A/} && $manifest =~ m{\A/} && $destination =~ m{\A/};
die "invalid destination\n" if $destination =~ m{(?:\A|/)(?:\.|\.\.)(?:/|\z)|//|/\z} || $destination =~ /[\x00-\x1f]/;
umask 0077;
$SIG{ALRM} = sub { die "bootstrap timed out\n" };
alarm 120;

sub hash_result {
    my ($result, $pid) = @_;
    my $digest = '';
    while (length($digest) < 128) {
        my $chunk;
        my $read = sysread($result, $chunk, 128 - length($digest));
        die "cannot read trusted hash output\n" unless defined($read);
        last if $read == 0;
        $digest .= $chunk;
    }
    close $result;
    waitpid($pid, 0);
    die "trusted hash tool failed\n" unless $? == 0 && $digest =~ /\A([0-9a-f]{64})  -\n\z/;
    return $1;
}

sub hash_process {
    my ($input) = @_;
    pipe(my $result, my $output) or die "cannot create hash output\n";
    my $pid = fork();
    die "cannot start trusted hash tool\n" unless defined $pid;
    if ($pid == 0) {
        close $result;
        open STDIN, '<&', fileno($input) or die "cannot bind hash input\n";
        open STDOUT, '>&', fileno($output) or die "cannot bind hash output\n";
        exec '/usr/bin/sha256sum';
        die "cannot execute trusted hash tool\n";
    }
    close $output;
    return ($result, $pid);
}

sub sha256 {
    my ($bytes) = @_;
    pipe(my $reader, my $writer) or die "cannot create hash input\n";
    my ($result, $pid) = hash_process($reader);
    close $reader;
    my $offset = 0;
    while ($offset < length($bytes)) {
        my $written = syswrite($writer, $bytes, length($bytes) - $offset, $offset);
        die "cannot hash manifest\n" unless defined($written) && $written > 0;
        $offset += $written;
    }
    close $writer;
    return hash_result($result, $pid);
}

sub sha256_file {
    my ($path) = @_;
    sysopen(my $input, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die "cannot open staged hash input\n";
    my ($result, $pid) = hash_process($input);
    close $input;
    return hash_result($result, $pid);
}

sysopen(my $manifest_file, $manifest, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die "manifest unavailable\n";
my @manifest_stat = stat($manifest_file);
die "manifest is nonregular or overlong\n" unless S_ISREG($manifest_stat[2]) && $manifest_stat[7] > 0 && $manifest_stat[7] <= 2097152;
my $bytes = '';
while (length($bytes) <= 2097152) {
    my $chunk;
    my $count = sysread($manifest_file, $chunk, 65536);
    die "manifest read failed\n" unless defined $count;
    last if $count == 0;
    $bytes .= $chunk;
}
close $manifest_file;
die "manifest exceeds bound\n" if length($bytes) > 2097152;
die "bootstrap pin differs\n" unless sha256($bytes) eq $pin;
die "unterminated bootstrap manifest\n" unless $bytes =~ /\n\z/;
my @lines = split /\n/, $bytes;
my $header = shift @lines;
die "invalid bootstrap header\n" unless $header =~ /\AWOTEX_HOME_BOOTSTRAP\t1\t([0-9a-f]{40})\z/;
my $revision = $1;
die "bootstrap file limit exceeded\n" unless @lines > 0 && @lines <= 10000;
my (@entries, %seen, $previous);
my $total = 0;
for my $line (@lines) {
    die "invalid bootstrap entry\n" unless $line =~ /\A([0-9a-f]{64})\t([0-7]{1,3})\t(0|[1-9][0-9]{0,9})\t([A-Za-z0-9_+@.\/-]{1,512})\z/;
    my ($digest, $mode, $size, $path) = ($1, oct($2), 0 + $3, $4);
    die "unsafe bootstrap path\n" if $path =~ m{\A[/\-]|/\z} || grep { $_ eq '' || $_ eq '.' || $_ eq '..' } split m{/}, $path;
    die "duplicate or unsorted bootstrap path\n" if exists($seen{$path}) || (defined($previous) && $previous ge $path);
    die "bootstrap refuses group/other writable mode\n" if ($mode & 0022) != 0;
    $seen{$path} = 1; $previous = $path; $total += $size;
    die "bootstrap byte limit exceeded\n" if $total > 1073741824;
    push @entries, [$digest, $mode, $size, $path];
}
die "bootstrap inventory missing\n" unless $seen{'release-inventory.json'};

sysopen(my $source_dir, $source, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "source directory unavailable\n";
my $parent = $destination;
$parent =~ s{/[^/]+\z}{};
if ($parent eq '') { $parent = '/'; }
sysopen(my $parent_dir, $parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "destination parent unavailable\n";
my @parent_stat = stat($parent_dir);
die "destination parent must be owned and private from other writers\n" unless @parent_stat && S_ISDIR($parent_stat[2]) && $parent_stat[4] == $> && ($parent_stat[2] & 0022) == 0;
my ($destination_name) = $destination =~ m{/([^/]+)\z};
my $anchored_destination = '/proc/self/fd/' . fileno($parent_dir) . '/' . $destination_name;
die "destination already exists\n" if lstat($anchored_destination);
mkdir($anchored_destination, 0700) or die "cannot create private staging\n";
sysopen(my $target_root, $anchored_destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "cannot open private staging\n";
my @target_stat = stat($target_root);
my $target_anchor = '/proc/self/fd/' . fileno($target_root);
my (@created_files, @created_dirs);
push @created_dirs, $anchored_destination;
my $directory_count = 1;
my $ok = eval {
    for my $entry (@entries) {
        my ($digest, $mode, $size, $path) = @$entry;
        my @components = split m{/}, $path;
        my $file_name = pop @components;
        my $directory = $source_dir;
        my @handles;
        my $target_dir = $target_anchor;
        for my $component (@components) {
            my $fd_path = '/proc/self/fd/' . fileno($directory) . '/' . $component;
            sysopen(my $next, $fd_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "source directory component unavailable\n";
            push @handles, $next;
            $directory = $next;
            $target_dir .= '/' . $component;
            unless (lstat($target_dir)) {
                die "bootstrap directory limit exceeded\n" if ++$directory_count > 10000;
                mkdir($target_dir, 0700) or die "cannot create staged directory\n";
                push @created_dirs, $target_dir;
            }
        }
        my $fd_path = '/proc/self/fd/' . fileno($directory) . '/' . $file_name;
        sysopen(my $input, $fd_path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die "source file unavailable: $path\n";
        my @before = stat($input);
        die "source file type/size/mode differs: $path\n" unless S_ISREG($before[2]) && $before[7] == $size && ($before[2] & 07777) == $mode;
        my $target = $target_dir . '/' . $file_name;
        sysopen(my $output_file, $target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or die "cannot create staged file\n";
        push @created_files, $target;
        my $remaining = $size;
        while ($remaining > 0) {
            my $chunk;
            my $count = sysread($input, $chunk, $remaining > 65536 ? 65536 : $remaining);
            die "source file truncated: $path\n" unless defined($count) && $count > 0;
            my $offset = 0;
            while ($offset < $count) {
                my $written = syswrite($output_file, $chunk, $count - $offset, $offset);
                die "staging write failed\n" unless defined($written) && $written > 0;
                $offset += $written;
            }
            $remaining -= $count;
        }
        my $extra;
        my $count = sysread($input, $extra, 1);
        my @after = stat($input);
        die "source file changed: $path\n" unless defined($count) && $count == 0 && $after[7] == $size && ($after[2] & 07777) == $mode;
        close $input;
        close $output_file or die "staging close failed\n";
        die "staged bytes differ: $path\n" unless sha256_file($target) eq $digest;
        chmod($mode, $target) == 1 or die "cannot set staged mode\n";
    }
    # Leave all directories private; the installer later publishes its own
    # verified release with declared traversal modes. This staging is inert.
    my @presented = lstat($destination);
    die "destination path changed\n" unless @presented && $presented[0] == $target_stat[0] && $presented[1] == $target_stat[1];
    1;
};
unless ($ok) {
    my $error = $@ || "bootstrap failed\n";
    unlink($_) for reverse @created_files;
    rmdir($_) for reverse @created_dirs;
    die $error;
}
close $source_dir;
close $target_root;
close $parent_dir;
alarm 0;
print "VERIFIED_STAGE\t$destination\t$revision\t$pin\n";
