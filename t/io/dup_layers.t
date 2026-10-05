#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    skip_all_without_perlio();
    skip_all_without_dynamic_extension('Encode');
}

use strict;
use warnings;
use Config;

# GH #24883: duping onto fd 0, 1 or 2 must restore the saved layers as
# well as the descriptor.  Report through a separate handle: writing to
# the handle under test can hide differences between its input/output sides.
for my $handle (qw(STDIN STDOUT STDERR)) {
    for my $layers ('', ':utf8', ':encoding(latin1)',
                    ':encoding(utf8):crlf', ':stdio:encoding(utf8)',
                    ':unix:encoding(latin1)',
                    ':encoding(utf8):crlf:encoding(utf8)') {
        for my $dup ('&', '&=') {
            my $mode = ($handle eq 'STDIN' ? '<' : '>') . $dup;
            fresh_perl_is(qq{
                my \$handle = \\*$handle;
                my \$mode = '$mode';
                my \$layers = '$layers';
            } . <<'PROG', 'ok', {}, "$mode $handle adopts $layers and restores layers");
use strict;
use warnings;
use PerlIO;
open my $report, '>&', \*STDOUT or die "report: $!";
open my $source, '+>' . $layers, undef or die "source: $!";
my $fd = fileno $handle;
my @original = map { join ' ', PerlIO::get_layers($handle, output => $_) } 0, 1;
for (1 .. 3) {
    open my $saved, $mode, $handle or die "save: $!";
    open $handle, $mode, $source or die "redirect: $!";
    die "descriptor changed" unless fileno($handle) == $fd;
    for my $output (0 .. ($fd == 0 ? 0 : 1)) {
        my $got = join ' ', PerlIO::get_layers($handle, output => $output);
        my $want = join ' ', PerlIO::get_layers($source, output => $output);
        die "redirect layers: $got != $want" unless $got eq $want;
    }
    binmode $handle, ':encoding(utf8)' or die "temporary layers: $!";
    # Use a real dup for restoration even when the redirection shares an fd.
    open $handle, ($fd == 0 ? '<&' : '>&'), $saved or die "restore: $!";
    close $saved or die "close saved: $!";
    die "restored descriptor changed" unless fileno($handle) == $fd;
    for my $output (0, 1) {
        my $got = join ' ', PerlIO::get_layers($handle, output => $output);
        die "restore layers: $got != $original[$output]"
            unless $got eq $original[$output];
    }
}
print $report "ok\n";
PROG
        }
    }
}

for my $handle (qw(STDIN STDOUT STDERR)) {
    my $mode = $handle eq 'STDIN' ? '<' : '>';
    fresh_perl_is(qq{
        my \$handle = \\*$handle;
        my \$mode = '$mode';
    } . <<'PROG', 'ok', {}, "$handle restores layers after a character device");
use strict;
use warnings;
use File::Spec;
use PerlIO;
open my $report, '>&', \*STDOUT or die $!;
open $handle, $mode, File::Spec->devnull or die $!;
binmode $handle, ':encoding(latin1)' or die $!;
open my $saved, $mode . '&', $handle or die $!;
open my $source, '+>:encoding(utf8)', undef or die $!;
open $handle, $mode . '&', $source or die $!;
for my $output (0 .. ($mode eq '<' ? 0 : 1)) {
    die 'source layers lost'
        unless join(' ', PerlIO::get_layers($handle, output => $output))
            eq join(' ', PerlIO::get_layers($source, output => $output));
}
open $handle, $mode . '&', $saved or die $!;
for my $output (0 .. ($mode eq '<' ? 0 : 1)) {
    die 'saved layers lost'
        unless join(' ', PerlIO::get_layers($handle, output => $output))
            eq join(' ', PerlIO::get_layers($saved, output => $output));
}
close $saved or die $!;
print $report "ok\n";
PROG
}

fresh_perl_is(<<'PROG', 'ok', {}, 'flush old output and use the duplicated encoding');
use strict;
use warnings;
open my $report, '>&', \*STDOUT or die $!;
open my $first, '+>', undef or die $!;
open my $second, '+>:encoding(utf8)', undef or die $!;
open STDOUT, '>&', $first or die $!;
print STDOUT 'buffered';
open STDOUT, '>&', $second or die $!;
print STDOUT "\x{e9}";
open STDOUT, '>&', $report or die $!;
seek $first, 0, 0 or die $!;
die 'lost old output' unless <$first> eq 'buffered';
binmode $second, ':raw' or die $!;
seek $second, 0, 0 or die $!;
die 'wrong encoded output' unless <$second> eq "\xc3\xa9";
print "ok\n";
PROG

fresh_perl_is(<<'PROG', 'ok', {}, 'reopened STDIN decodes with the source layers');
use strict;
use warnings;
open my $source, '+>', undef or die $!;
print $source "\xc3\xa9\n";
seek $source, 0, 0 or die $!;
binmode $source, ':encoding(utf8)' or die $!;
open STDIN, '<&', $source or die $!;
die 'wrong decoded input' unless <STDIN> eq "\x{e9}\n";
print "ok\n";
PROG

fresh_perl_is(<<'PROG', 'ok', {}, 'failed dup leaves standard-handle layers intact');
use strict;
use warnings;
use PerlIO;
binmode STDOUT, ':encoding(latin1)' or die $!;
my @before = PerlIO::get_layers(STDOUT);
open my $closed, '+>', undef or die $!;
close $closed or die $!;
{
    no warnings 'io';
    die 'dup unexpectedly succeeded' if open STDOUT, '>&', $closed;
}
die 'layers changed on failure'
    unless "@before" eq join ' ', PerlIO::get_layers(STDOUT);
print "ok\n";
PROG

SKIP: {
    skip 'requires alarm and interruptible pipe reads', 1
        if !$Config{d_alarm} || $^O eq 'MSWin32';
    local $ENV{PERLIO} = 'perlio';
    fresh_perl_is(<<'PROG', 'new', {}, 'signal-handler dup can resume an active read');
use strict;
use warnings;
pipe my $reader, my $writer or die $!;
open STDIN, '<&', $reader or die $!;
open my $source, '+>', undef or die $!;
print $source "new\n";
seek $source, 0, 0 or die $!;
$SIG{ALRM} = sub {
    open STDIN, '<&', $source or die $!;
    $SIG{ALRM} = sub { die 'read timed out' };
    alarm 5;
};
alarm 1;
my $line = <STDIN>;
alarm 0;
print defined($line) ? $line : 'undef';
PROG
}

done_testing();
