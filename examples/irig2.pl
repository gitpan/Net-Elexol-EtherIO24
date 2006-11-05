#!/usr/bin/perl -w

use strict;

use Net::Elexol::EtherIO24;

my $debug = 0;

my $ro = 1;

my $addrw = "192.168.100.83";  # i/o module with relays attached
my $addrr = "192.168.100.83";  # i/o module with rain sensor
my $rain_sensor_line = 0;      # line on module for rain sensor


system("ping -c 1 $addrw >/dev/null 2>&1"); # wake it up
system("ping -c 1 $addrr >/dev/null 2>&1"); # wake it up

my $rain_sensor = 0; # is it raining?
my $rain_sensor_inverted = 1;

Net::Elexol::EtherIO24->debug($debug);
my $eior = Net::Elexol::EtherIO24->new(target_addr=>$addrr, threaded=>1);

if(!$eior) {
	print STDERR "ERROR: Can't create new EtherIO24 object for $addrr: ".Net::Elexol::EtherIO24->error."\n";
	# Rather than exit here, we revert to assuming it's raining
	# and shut everything down (which only works, of course, if
	# we can get to the other i/o module).

	$rain_sensor = 1;
} else {
	# Check rain sensor

	my $prev = 2;
	while(1) {
		$rain_sensor = $eior->get_line_live($rain_sensor_line);
		print "RAIN: $rain_sensor\n" if($rain_sensor != $prev);
		$prev = $rain_sensor;
	}

	$rain_sensor = $eior->get_line($rain_sensor_line);
	$rain_sensor += $eior->get_line($rain_sensor_line); # debounce
	$rain_sensor += $eior->get_line($rain_sensor_line); # debounce
	$rain_sensor = 1 if($rain_sensor);
}

$rain_sensor = !$rain_sensor if($rain_sensor_inverted);

if($rain_sensor) {
	# It's raining, turn all off.
	@ARGV = ();
}

print $$." It's ".($rain_sensor?"":"not ")."raining.\n";

exit if($ro);

if(scalar(@ARGV) == 1 && $ARGV[0] eq 'raincheck') {
	# exit now, only checking if it's raining, and it's not, so all goes as normal.
	# Otherwise, if it was raining, ARGV is replaced with (), meaning all outputs get turned off
	exit;
}

my $eiow = Net::Elexol::EtherIO24->new(target_addr=>$addrw, threaded=>1);
if(!$eiow) {
	print STDERR "ERROR: Can't create new EtherIO24 object for $addrw: ".Net::Elexol::EtherIO24->error."\n";
	exit 1;
}

my @lines = ();
for my $line (0..23) {
	print "line $line dir: ".$eiow->get_line_dir($line)."  ".
	      "line $line val: ".$eiow->get_line($line)."\n" if($debug);
	$eiow->set_line_dir($line, 0); # it's an output. make it so.
	$lines[$line] = 0;
}

while (my $line = shift) {
	if(defined($line)) {
		$lines[$line] = 1;
	}
}

for my $line(0..23) {
	$eiow->set_line($line, $lines[$line]);
	print "line $line val: ".$eiow->get_line($line)."\n" if($debug);
}

exit;
