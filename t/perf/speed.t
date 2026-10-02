#!./perl
#
# All the tests in this file are ones that run exceptionally slowly
# (each test taking seconds or even minutes) in the absence of particular
# optimisations. Thus it is a sort of canary for optimisations being
# broken.
#
# Although it includes a watchdog timeout, this is set to a generous limit
# to allow for running on slow systems; therefore a broken optimisation
# might be indicated merely by this test file taking unusually long to
# run, rather than actually timing out.
#

BEGIN {
    chdir 't' if -d 't';
    @INC = ('../lib');
    require './test.pl';
}
use Config;

use strict;
use warnings;
use 5.010;

$| = 1;

plan tests => 2;

watchdog(60);

SKIP: {
    # RT #121975 / GH #13878 COW speedup lost after e8c6a474

    # without COW, this test takes minutes; with COW, its less than a
    # second
    #
    skip "PERL_NO_COW", 1 if $Config{ccflags} =~ /PERL_NO_COW/;

    my ($x, $y);
    $x = "x" x 1_000_000;
    $y = $x for 1..1_000_000;
    pass("COW 1Mb strings");
}

SKIP: {
    # GH #24872: reading match offsets repeatedly scanned the UTF-8 string.
    skip "PERL_NO_COW", 1 if $Config{ccflags} =~ /PERL_NO_COW/;
    local ${^UTF8CACHE} = 1;

    my $n = 200_000;
    my $s = ("\x{3042}\x{3044}\x{3046} abc ") x $n;
    my ($count, $sum) = (0, 0);
    while ($s =~ /abc/g) {
        $sum += $-[0] + $+[0];
        ++$count;
    }
    is("$count $sum", "$n " . (8 * $n * $n + 3 * $n),
       'UTF-8 match offsets');
}

watchdog(0);

1;
