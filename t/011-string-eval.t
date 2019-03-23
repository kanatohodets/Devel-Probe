use strict;
use warnings;
use Test::More;
use Devel::Probe;
my $file = __FILE__;
my $expected = {
    $file => {
        29 => 1,
        36 => 1,
    }
};

my $triggered;
Devel::Probe::trigger(sub {
    my ($file, $line) = @_;
    $triggered->{$file}->{$line} = 1;
});

my $actions = [
    { action => "enable" },
    map {
        { action => "define", file => $file, lines => [$_] }
    } sort keys %{ $expected->{$file} }
];

Devel::Probe::config({actions => $actions});

eval '
    my $single_nested = 1; # probe 1
';

eval '
    eval q!
        eval q|
            eval q(
                my $deeply_nested = 1; # probe 2
            );
        |;
    !;
';


# This test matters because entering a string eval resets the value of __FILE__
# to '(eval 1234)', where 1234 is an internal perl ID, and the value of
# __LINE__ to be relative to the start of the string being eval'd. These are
# not names that a user can reasonably set a probe on, so Devel::Probe skips
# over string eval frames and adds their line numbers to the 'real' line offset
# to create sensible names.
is_deeply(
    $triggered,
    $expected,
    "probes fired inside string eval using human-readable file/line names"
);

done_testing;
