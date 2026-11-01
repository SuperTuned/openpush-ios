#!/usr/bin/env bash
# Fails when anything tracked in the repository contains content that must not
# be published: email addresses, local and agent paths, internal hosts, private
# repositories and documents, process markers, secrets, crash logs, a
# non-Apache licence, or the name of the third-party SDK the compatibility layer
# provides API names for, outside that layer.
#
# What is checked:
#   - every tracked file's name;
#   - every line of every tracked text file;
#   - every byte of every tracked binary file: runs of printable ASCII and of
#     UTF-16LE text, read straight from the bytes (no `strings`, which skips
#     some formats);
#   - every entry of a .jar, .aar, .zip or .apk archive, by name and by content,
#     nested archives included.
#
# Private name patterns: names that must not be published cannot be listed in a
# published file, so they live outside the repository. When the environment
# variable OPENPUSH_PRIVATE_PATTERNS names a readable file, its rules are added,
# one per line:
#
#     <pattern id> <perl regex>          (case-insensitive; # starts a comment)
#
# They are applied to everything scanned (names, text, binaries, archive
# entries), and also to this script and the allowlist. Only the pattern id and
# the matched text are printed, never the regex. When the variable is unset the
# check says so once and runs the rules below only; when it is set but the file
# cannot be read or a rule does not compile, the check fails.
#
# Exceptions live in scripts/public-content-allowlist.txt, one per line:
#
#     <path glob> <pattern id> [<line regex>] -- <reason>
#
# The glob is matched against the tracked path (for an archive entry,
# "<archive>!<entry>"); `**` matches across directories, `*` and `?` within
# one. When a line regex is given, the line (or binary string, or file name)
# must also match it. The reason is required. An entry that matches nothing is
# an error, so the list cannot rot.
#
# Output: one "<where>: <pattern id>: <excerpt>" line per hit, where <where> is
# "path:line", "path (name)" or "path@0xoffset". Exits non-zero on any hit,
# allowlist error or private pattern error. Needs only bash 3.2, perl 5 core modules and unzip; no
# network. The same file is used by every OpenPush SDK repository.
#
# Usage: [OPENPUSH_PRIVATE_PATTERNS=<file>] scripts/check-public-content.sh
#        (from anywhere inside the repository)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
export LC_ALL=C

git ls-files -z | perl -0 -e '
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Find qw(find);

my $self_file = "scripts/check-public-content.sh";
my $allow_file = "scripts/public-content-allowlist.txt";

# Pattern id => regex, case-insensitive unless the regex says (?-i).
# "name-only" patterns are applied to file and entry names only.
my @patterns = (
  # Local machine paths, and agent or worktree state.
  [ "local-path", qr{/Users/|/home/|\b[A-Za-z]:\\+Users\\}i ],
  [ "agent-path", qr{\.(?:claude|superpowers|impeccable)\b|\bworktrees?\b}i ],
  # Internal hosts, private repositories, internal documents and markers.
  [ "internal-host", qr/\bstaging\.[a-z0-9-]+\.|\badmin\.openpush\b|\brailway\b|amazonaws\.com|\bAWS\b/i ],
  [ "private-repo",  qr{JuneSoftware/|github\.com[/:]JuneSoftware|git\@github\.com:}i ],
  [ "internal-doc",  qr{\bPRODUCT\.md\b|\bDESIGN\.md\b|\bdocs/[0-9]{2}(?:\b|-)}i ],
  [ "process-marker", qr/(?-i:\bTask [0-9]+(?:\.[0-9]+)*\b|\bFINISH:|\bTHESIS:|\bOWN-WORLD:)|owner[ -]rule/i ],
  [ "product-internal", qr/intelligent[ _-]?delivery/i ],
  # Licence and brand text.
  [ "licence",        qr/modified mit/i ],
  [ "onesignal-inc",  qr/one[ _-]?signal,? inc/i ],
  [ "com-onesignal",  qr/com\.onesignal/i ],
  [ "onesignal",      qr/one[ _-]?signal/i ],
  # Secrets.
  [ "private-key",    qr/-----BEGIN (?:[A-Z0-9]+ )*(?:PRIVATE KEY|CERTIFICATE)/ ],
  [ "aws-key",        qr/(?-i:\b(?:AKIA|ASIA)[0-9A-Z]{16}\b)/ ],
  [ "github-token",   qr/(?-i:\bgh[pousr]_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{22,})/ ],
  [ "stripe-key",     qr/(?-i:\b[rs]k_(?:live|test)_[A-Za-z0-9]{10,})/ ],
  [ "slack-token",    qr/(?-i:\bxox[abprs]-[A-Za-z0-9-]{10,})/ ],
  [ "google-api-key", qr/(?-i:AIza[0-9A-Za-z_-]{35})/, \&not_placeholder ],
  [ "jwt",            qr/(?-i:\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*)/ ],
  # Email addresses other than the published contact and reserved example domains.
  [ "email",          qr/(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+\@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b/, \&disallowed_email ],
  # Tracked files that are never published.
  [ "crash-log",      qr{(?:^|/)(?:hs_err_pid|replay_pid)[^/]*\.log$}, undef, "name-only" ],
  [ "secret-file",    qr{\.(?:p12|p8|pem|jks|keystore|mobileprovision|provisionprofile)$}i, undef, "name-only" ],
  [ "internal-file",  qr{(?:^|/)[^/]*(?:checklist|execution[-_ ]record|[-_ ]plan)[^/]*\.md$}i, undef, "name-only" ],
);

# Names of the compatibility surface itself (products, modules, packages,
# guides, examples and their tests). They are removed before the "onesignal"
# pattern runs, so a line that only names the compatibility layer is not a hit.
my $compat_names = qr/
    OpenPushOneSignal | OpenPush\.OneSignalCompat | OneSignalAliasTests
  | MIGRATING-FROM-ONESIGNAL(?:\.md)? | MigratedFromOneSignal | migrated-from-onesignal
  | OneSignalStyleExport | openpush-onesignal-compat | openpush-android-onesignal
  | ai\.openpush\.android\.onesignal
/x;

sub not_placeholder {
  my ($m) = @_;
  return $m !~ /x{4,}|0{8,}|example|placeholder|your|dummy|fake|sample|test/i
      && $m !~ /(.)\1{7,}/;
}

sub disallowed_email {
  my ($m) = @_;
  my ($local, $domain) = split /\@/, $m, 2;
  return 0 if $local =~ /^(?:this|return|super|continue|break)$/;    # Kotlin labels
  return 0 if $domain =~ /^[0-9]+x\./i;                                # image\@2x.png
  return 0 if lc($m) eq "security\@openpush.ai";
  return 0 if $domain =~ /(?:^|\.)example\.(?:com|org|net)$/i;
  return 0 if $domain =~ /\.(?:example|test|invalid|localhost)$/i;
  return 1;
}

sub glob_to_re {
  my ($glob) = @_;
  my $re = quotemeta($glob);
  $re =~ s/\\\*\\\*\\\//(?:.*\/)?/g;
  $re =~ s/\\\*\\\*/.*/g;
  $re =~ s/\\\*/[^\/]*/g;
  $re =~ s/\\\?/[^\/]/g;
  return qr/^$re$/;
}

# Private name patterns (see the header); their regexes are never printed.
my (@private, @private_errors);
my $private_file = $ENV{OPENPUSH_PRIVATE_PATTERNS};
if (!defined $private_file || $private_file eq "") {
  print "check-public-content: private name patterns not loaded (OPENPUSH_PRIVATE_PATTERNS is unset)\n";
} elsif (open(my $fh, "<", $private_file)) {
  local $/ = "\n";
  my $n = 0;
  while (my $line = <$fh>) {
    $n++;
    chomp $line;
    $line =~ s/\r$//;
    next if $line =~ /^\s*(?:#|$)/;
    my ($id, $re) = $line =~ /^\s*([A-Za-z0-9_-]+)\s+(\S.*?)\s*$/;
    if (!defined $id) { push @private_errors, "private patterns line $n: expected \"<pattern id> <regex>\""; next; }
    my $qr = eval { qr/$re/i };
    if (!defined $qr) { push @private_errors, "private patterns line $n ($id): regex does not compile"; next; }
    push @private, [ $id, $qr ];
  }
  close $fh;
  push @private_errors, "private patterns file has no rules" unless @private || @private_errors;
  print "check-public-content: " . scalar(@private) . " private name pattern(s) loaded\n" unless @private_errors;
} else {
  push @private_errors, "OPENPUSH_PRIVATE_PATTERNS is set but the file cannot be read";
}

# Each regex wrapped once in a capture group, so a match loop never recompiles it.
$_->[1] = qr/($_->[1])/ for @patterns, @private;
my %known = map { $_->[0] => 1 } @patterns, @private;
my (@allow, @allow_errors);
if (open(my $fh, "<", $allow_file)) {
  local $/ = "\n";
  my $n = 0;
  while (my $line = <$fh>) {
    $n++;
    chomp $line;
    $line =~ s/\r$//;
    next if $line =~ /^\s*(?:#|$)/;
    my $cut = rindex($line, " -- ");
    if ($cut < 0) { push @allow_errors, "$allow_file:$n: missing \" -- <reason>\": $line"; next; }
    my $reason = substr($line, $cut + 4);
    my ($glob, $id, $rest) = split(/\s+/, substr($line, 0, $cut), 3);
    if (!defined $id || $reason !~ /\S/) { push @allow_errors, "$allow_file:$n: malformed entry: $line"; next; }
    if (!$known{$id}) { push @allow_errors, "$allow_file:$n: unknown pattern id \"$id\""; next; }
    $rest = undef if defined $rest && $rest !~ /\S/;
    my $line_re = eval { defined $rest ? qr/$rest/ : undef };
    if ($@) { push @allow_errors, "$allow_file:$n: bad line regex: $rest"; next; }
    push @allow, { re => glob_to_re($glob), id => $id, line => $line_re, text => $line, n => $n, used => 0 };
  }
  close $fh;
}

sub allowed {
  my ($path, $id, $text) = @_;
  for my $a (@allow) {
    next unless $a->{id} eq $id && $path =~ $a->{re};
    next if defined $a->{line} && $text !~ $a->{line};
    $a->{used}++;
    return 1;
  }
  return 0;
}

my $hits = 0;
# $path: allowlist path; $where: location shown; $text: one line, string or name;
# $private_only: apply only the private name patterns.
sub check {
  my ($path, $where, $text, $is_name, $private_only) = @_;
  my %reported;    # several private rules may share an id: one hit per id and location
  for my $p ($private_only ? @private : (@patterns, @private)) {
    my ($id, $re, $filter, $scope) = @$p;
    next if defined $scope && !$is_name;
    next if $reported{$id};
    my $subject = $text;
    $subject =~ s/$compat_names//g if $id eq "onesignal";
    my $found = 0;
    while ($subject =~ /$re/g) {
      if (!$filter || $filter->($1)) { $found = 1; last; }
    }
    next unless $found;
    next if allowed($path, $id, $text);
    print "$where: $id: " . excerpt($text, $re) . "\n";
    $reported{$id} = 1;
    $hits++;
  }
}

# The line, or for a long line the 160 characters around the first match.
sub excerpt {
  my ($text, $re) = @_;
  my $shown = $text;
  $shown =~ s/^\s+//;
  return $shown if length($shown) <= 160;
  my $at = $shown =~ $re ? $-[1] : 0;
  my $from = $at > 60 ? $at - 60 : 0;
  return ($from ? "..." : "") . substr($shown, $from, 160) . ($from + 160 < length($shown) ? "..." : "");
}

# Text files scanned with the private name patterns only (this script and its allowlist).
sub scan_private_only {
  my ($path) = @_;
  return unless @private;
  open(my $fh, "<:raw", $path) or die "cannot read $path: $!\n";
  my $n = 0;
  local $/ = "\n";
  while (my $line = <$fh>) {
    $n++;
    chomp $line;
    check($path, "$path:$n", $line, 0, 1);
  }
  close $fh;
}

# Printable ASCII runs and UTF-16LE runs of at least four characters, with offsets.
sub scan_bytes {
  my ($path, $label, $data) = @_;
  while ($data =~ /([\x09\x20-\x7e]{4,})/g) {
    check($path, sprintf("%s\@0x%x", $label, $-[1]), $1, 0);
  }
  while ($data =~ /((?:[\x09\x20-\x7e]\x00){4,})/g) {
    my ($s, $off) = ($1, $-[1]);
    $s =~ s/\x00//g;
    check($path, sprintf("%s\@0x%x", $label, $off), $s, 0);
  }
}

sub is_binary {
  my ($name, $data) = @_;
  return 1 if index(substr($data, 0, 8000), "\0") >= 0;
  return $name =~ /\.(?:png|jpe?g|gif|webp|ico|pdf|so|dylib|a|dex|class|keystore|jks|p12)$/i;
}

my $archive_re = qr/\.(?:jar|aar|zip|apk)$/i;
my $tmp_root;

sub scan_archive {
  my ($archive, $label) = @_;
  $tmp_root ||= tempdir("check-public-content.XXXXXX", TMPDIR => 1, CLEANUP => 1);
  my $dir = tempdir(DIR => $tmp_root);
  local $/ = "\n";
  open(my $list, "-|", "unzip", "-Z1", $archive) or die "cannot list $archive: $!\n";
  my @entries = map { chomp; $_ } <$list>;
  close $list or die "cannot read archive $label\n";
  system("unzip", "-qq", "-o", $archive, "-d", $dir) == 0 or die "cannot unpack archive $label\n";
  for my $entry (@entries) {
    check("$label!$entry", "$label!$entry (name)", $entry, 1);
    my $file = "$dir/$entry";
    next unless -f $file;
    scan_file($file, "$label!$entry", $entry);
  }
}

sub scan_file {
  my ($file, $label, $name) = @_;
  if ($name =~ $archive_re) { scan_archive($file, $label); return; }
  open(my $fh, "<:raw", $file) or die "cannot read $label: $!\n";
  my $data = do { local $/; <$fh> };
  close $fh;
  $data = "" unless defined $data;
  if (is_binary($name, $data)) { scan_bytes($label, $label, $data); return; }
  my $n = 0;
  for my $line (split /\n/, $data) {
    $n++;
    check($label, "$label:$n", $line, 0);
  }
}

local $/ = "\0";
my @files = map { chomp; $_ } <STDIN>;
for my $path (@files) {
  check($path, "$path (name)", $path, 1);
  if ($path eq $self_file || $path eq $allow_file) { scan_private_only($path) if -f $path; next; }
  if (-l $path) { check($path, "$path (link)", readlink($path), 0); next; }
  next unless -f $path;
  scan_file($path, $path, $path);
}

my $errors = 0;
for my $e (@private_errors) { print "$e\n"; $errors++; }
for my $e (@allow_errors) { print "$e\n"; $errors++; }
for my $a (@allow) {
  next if $a->{used};
  print "$allow_file:$a->{n}: unused entry: $a->{text}\n";
  $errors++;
}

if ($hits || $errors) {
  print "\ncheck-public-content: $hits hit(s), $errors allowlist or private pattern error(s). Reword the",
        " content, or add a justified entry to $allow_file.\n";
  exit 1;
}
print "check-public-content: passed (" . scalar(@files) . " tracked files)\n";
'
