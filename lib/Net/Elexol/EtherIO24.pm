# Module for manipulating Elexol Ether I/O 24 units
#
# Copyright (c) 2005 Chris Luke <chrisy@flirble.org>.  All rights
# reserved.  This program is free software; you can redistribute it
# and/or modify it under the same terms as Perl itself.
# 
# Feel free to use, modify and redistribute it as long as
# you retain the correct attribution.
# 

package Net::Elexol::EtherIO24;

require 5.8.0;

use warnings;
use strict;

use threads;
use threads::shared;

use Socket;
use IO::Socket::INET;
use IO::Select;


=head1 NAME

Net::Elexol::EtherIO24 - Object interface for manipulating Elexol Ether I/O 24 units with Perl

=cut

our $VERSION = '0.13';

=head1 VERSION

Version 0.13.

Requires Perl 5.8.0.

=cut

# =============================================================================

=head1 SYNOPSIS

  use Net::Elexol::EtherIO24;

  Net::Elexol::EtherIO24->debug(1);
  my $eio = Net::Elexol::EtherIO24->new(target_addr=>$addr, threaded=>1);

  for my $line (0..23) {
    print "line $line dir: ".$eio->get_line_dir($line)."  ".
          "line $line val: ".$eio->get_line($line)."\n";
  }

  $eio->close;

=head1 DESCRIPTION

The Ether I/O 24 manufactured by Elexol is an inexpensive and simple to
use/operate device designed for remote control or remote sensing.
It has 24 lines that are each programmable for input or output and a
variety of other things.

The control protocol is relatively simplistic and UDP based. This Perl
module attempts to abstract this protocol and add other features
along the way.

It is thread savvy and will use threads if told to. It might perform
adequately without threads, but various functionality would be reduced as
a result. In particular, the module functions in a nice asynchronous
way when it can use threads. Threads support requires Perl 5.8.
This module may not function correctly, or even compile, with an older Perl.
Your Perl will require Threads to be enabled at compile-time, even if you
don't use Threads.

It uses C<IO::Socket::INET> for network I/O. It was developed using Perl
on a BSD system, but has been shown to function using Perl with Cygwin and
Windows.

=cut

# =============================================================================

my $_debug = 0;
my $_dbg = 'etherio24';
my $_error = 0;

share($_debug);
share($_error);

# =============================================================================

=head1 CONSTRUCTOR

=over 4

=item I<new(args, ...)>

Creates a new C<Net::Elexol::EtherIO24> object complete with associated
socket and any necessary threads (if enabled). Returns undef if
this is not possible, whereupon the application can check
C<< Net::Elexol::EtherIO24->error() >> for any relevant error string.

Arguments are given in C<< key => value >> form from these candidates:

=over 4

=item I<target_addr>

Address or hostname of the device to communicate with. B<Mandatory>.

=item I<target_port>

UDP port number to communicate on. Defaults to '2424'.

=item I<prefetch_status>

Indicates that the current status and configuration of ports on
the device should be immediately fetched. Defaults to '1', which
enables this feature.

=item I<presend_status>

Indicates that the initial state should be immediately sent to the
device. This would set all lines to inputs with no pullups and
threshold set to TTL levels. If at some point we add a way to pre-set
this status, then this feature might become useful!

=item I<threaded>

Enables Perl ithreads and creates a thread to listen to replies from the
EtherIO24 unit. This currently requires Perl 5.8 to function. For the
most part, client applications do not need to be thread aware, but some
functionality may change this assumption.

=item I<recv_timeout>, I<service_recv_timeout>, I<service_status_fetch>

These values control various timers and are unlikely to need any
tweaking. However: recv_timeout is the time recv_result will hang around
waiting for an answer. service_recv_timeout is the timer used in the
packet receiver thread, when threading, to wait for packets before 
seeing if there's anything else to do. service_status_fetch is how
often in that same thread we fire off a call to the status_fetch
method, just to keep our status up-to-date, just in case. These
timers are all integer seconds.

=item I<data>

Various state information is contained within a hash. If not given, one
is created and used anonymously. However, the application can pass in
a reference to a hash here, for whatever reason. Idle curiosity perhaps?

Many of the items in this hash are C<threads::shared> when we are threading.

=back

=back

=cut

sub new {
	my $proto = shift;
	my %arg = @_;

	my $class = ref($proto) || $proto;
	my $self  = {};

	return 0 if(!$arg{'target_addr'});

	$self->{'socket'} = IO::Socket::INET->new(
			PeerAddr =>	$arg{'target_addr'},
			PeerPort =>	$arg{'target_port'} || '2424',
			Proto =>	'udp',
			ReuseAddr =>	1,
	);
	if(!$self->{'socket'}) {
		$_error = "Net::Elexol::EtherIO24->new can't create socket: $@\n";
		return undef;
	}

	# It's worth noting that when threading, our backround servicing
	# thread only sees the values of these things as they were at the
	# time the thread started. Anything that changes needs to go into
	# $self->{'data'} and be share()'ed. The best place to initialise
	# such a thing is in init_state() further down.

	$self->{'prefetch_status'} = 1;
	$self->{'presend_status'} = 0;
	$self->{'threaded'} = 0;
	$self->{'recv_timeout'} = 1;
	$self->{'service_recv_timeout'} = 1;
	$self->{'service_status_fetch'} = 60;

	foreach my $field (('prefetch_status', 'presend_status', 'threaded', 'recv_timeout',
			'service_recv_timeout', 'service_status_fetch', )) {
		$self->{$field} = $arg{$field} if(defined($arg{$field}));
	}

	# Bless me...
	bless($self, $class);

	# Things relating to the state of the IO24 module
	$self->{'data'} = {};
	if($arg{'data'}) {
		$self->{'data'} = $arg{'data'};
	}

	_init_state($self);

	if($self->{'threaded'}) {
		$self->{'thread_service'} = threads->new(\&_service_loop, $self);
		$self->{'thread_service'}->detach;
	}

	if($self->{'prefetch_status'}) {
		if(!$self->status_fetch) {
			$self->close;
			$_error .= ' while prefetching status';
			return undef;
		}
		if(!$self->eeprom_fetch) {
			$self->close;
			$_error .= ' while prefetching eeprom contents';
			return undef;
		}
	}
	$self->status_send() if($self->{'presend_status'});

	return $self;
}

DESTROY {
	my $self = shift;
	$self->close;
}

=head1 METHODS

=over 4

=item I<close>

Closes network resources and waits (briefly) for any running threads to end. Should
be called when the host application is ending.

=cut

sub close {
	my $self = shift;

	return if(!$self->{'data'}->{'running'});

	$self->{'data'}->{'running'} = 0;
	$self->{'socket'}->close;

	if($self->{'threaded'}) {
		print "$_dbg: waiting for thread to die\n" if($_debug>1);
		sleep($self->{'service_recv_timeout'}); # time enough for thread to close
	}
}

sub _service_loop {
	my $self = shift;

	my $status_time = time() + $self->{'service_status_fetch'};


	while($self->{'data'}->{'running'}) {
		if($self->{'service_status_fetch'} && $status_time < time()) {
			# 0=don't recv_result, which would cause a deadlock
			$self->status_fetch(0);
			$status_time = time() + $self->{'service_status_fetch'};
		}

		$self->recv_command;
	}
	print "$_dbg: service_loop shutting down\n" if($_debug>1);
}

=item I<debug($level)>

The higher $level is, the more debugging is output. "3" is currently the useful
limit.

=cut

sub debug {
	my $self = shift;
	if(@_) { $_debug = shift; }
	return $_debug;
}

=item I<error>

Returns a string description of the last error, or 0 if no error recorded.

Note that this value is global - it is shared between all EtherIO24 objects
so that you can return an error should C<new()> fail to construct a new object.

=cut

sub error {
	my $self = shift;
	return $_error;
}

# =============================================================================

my $status_commands = {
	'status A' => 'a',
	'status B' => 'b',
	'status C' => 'c',
	'dir A' => '!a',
	'dir B' => '!b',
	'dir C' => '!c',
	'pullup A' => '@a',
	'pullup B' => '@b',
	'pullup C' => '@c',
	'thresh A' => '#a',
	'thresh B' => '#b',
	'thresh C' => '#c',
	'schmitt A' => '$a',
	'schmitt B' => '$b',
	'schmitt C' => '$c',
};

# reverse mapping of status commands
my $status_map = {};
foreach my $key (keys %$status_commands) {
	$status_map->{$status_commands->{$key}} = $key;
}

my $set_commands = {
	'status A' => 'A',
	'status B' => 'B',
	'status C' => 'C',
	'dir A' => '!A',
	'dir B' => '!B',
	'dir C' => '!C',
	'pullup A' => '@A',
	'pullup B' => '@B',
	'pullup C' => '@C',
	'thresh A' => '#A',
	'thresh B' => '#B',
	'thresh C' => '#C',
	'schmitt A' => '$A',
	'schmitt B' => '$B',
	'schmitt C' => '$C',
};

# reverse mapping of set command
my $set_map = {};
foreach my $key (keys %$set_commands) {
	$set_map->{$set_commands->{$key}} = $key;
}

# What a status query results in
my $cmd_map = {
	'a' => 'A',
	'!a' => '!A',
	'@a' => '@A',
	'#a' => '#A',
	'$a' => '$A',
	'b' => 'B',
	'!b' => '!B',
	'@b' => '@B',
	'#b' => '#B',
	'$b' => '$B',
	'c' => 'C',
	'!c' => '!C',
	'@c' => '@C',
	'#c' => '#C',
	'$c' => '$C',
	'IO24' => 'IO24',
	'%' => '%',
	'`' => '\'',
	'*' => ' ',
	'\'R' => 'R',
};

my $cmd_rev_map = {};
foreach my $key (keys %$cmd_map) {
	$cmd_rev_map->{$cmd_map->{$key}} = $key;
}

my $send_commands = {
	'IO24' => {
		length => 4,
		'desc' => 'ID units',
		},

	'A' => {
		'length' => 2,
		'desc' => 'Wr Port A',
		'type' => 'hex_byte',
		},
	'B' => {
		'length' => 2,
		'desc' => 'Wr Port C',
		'type' => 'hex_byte',
		},
	'C' => {
		'length' => 2,
		'desc' => 'Wr Port C',
		'type' => 'hex_byte',
		},

	'a' => {
		'length' => 1,
		'desc' => 'Rd Port A',
		},
	'b' => {
		'length' => 1,
		'desc' => 'Rd Port B',
		},
	'c' => {
		'length' => 1,
		'desc' => 'Rd Port C',
		},

	'!A' => {
		'length' => 3,
		'desc' => 'Wr Dir A',
		'type' => 'hex_byte',
		},
	'!B' => {
		'length' => 3,
		'desc' => 'Wr Dir B',
		'type' => 'hex_byte',
		},
	'!C' => {
		'length' => 3,
		'desc' => 'Wr Dir C',
		'type' => 'hex_byte',
		},

	'!a' => {
		'length' => 2,
		'desc' => 'Rd Dir A',
		},
	'!b' => {
		'length' => 2,
		'desc' => 'Rd Dir B',
		},
	'!c' => {
		'length' => 2,
		'desc' => 'Rd Dir C',
		},

	'@A' => {
		'length' => 3,
		'desc' => 'Wr Pullup A',
		'type' => 'hex_byte',
		},
	'@B' => {
		'length' => 3,
		'desc' => 'Wr Pullup B',
		'type' => 'hex_byte',
		},
	'@C' => {
		'length' => 3,
		'desc' => 'Wr Pullup C',
		'type' => 'hex_byte',
		},

	'#A' => {
		'length' => 3,
		'desc' => 'Wr Thresh A',
		'type' => 'hex_byte',
		},
	'#B' => {
		'length' => 3,
		'desc' => 'Wr Thresh B',
		'type' => 'hex_byte',
		},
	'#C' => {
		'length' => 3,
		'desc' => 'Wr Thresh C',
		'type' => 'hex_byte',
		},

	'$A' => {
		'length' => 3,
		'desc' => 'Wr Schmitt A',
		'type' => 'hex_byte',
		},
	'$B' => {
		'length' => 3,
		'desc' => 'Wr Schmitt B',
		'type' => 'hex_byte',
		},
	'$C' => {
		'length' => 3,
		'desc' => 'Wr Schmitt C',
		'type' => 'hex_byte',
		},

	'@a' => {
		'length' => 2,
		'desc' => 'Rd Pullup a',
		},
	'@b' => {
		'length' => 2,
		'desc' => 'Rd Pullup b',
		},
	'@c' => {
		'length' => 2,
		'desc' => 'Rd Pullup c',
		},

	'#a' => {
		'length' => 2,
		'desc' => 'Rd Thresh a',
		},
	'#b' => {
		'length' => 2,
		'desc' => 'Rd Thresh b',
		},
	'#c' => {
		'length' => 2,
		'desc' => 'Rd Thresh c',
		},

	'$a' => {
		'length' => 2,
		'desc' => 'Rd Schmitt a',
		},
	'$b' => {
		'length' => 2,
		'desc' => 'Rd Schmitt b',
		},
	'$c' => {
		'length' => 2,
		'desc' => 'Rd Schmitt c',
		},

	'\'R' => {
		'length' => 5,
		'desc' => 'Rd EEPROM word',
		'type' => 'eeprom',
		'nobundle' => 1,
		},
	'\'W' => {
		'length' => 5,
		'desc' => 'Wr EEPROM word',
		'type' => 'eeprom',
		'nobundle' => 1,
		},
	'\'E' => {
		'length' => 5,
		'desc' => 'Erase EEPROM word',
		'type' => 'eeprom',
		'nobundle' => 1,
		},
	'\'0' => {
		'length' => 5,
		'desc' => 'Write disable EEPROM',
		'type' => 'eeprom',
		'nobundle' => 1,
		},
	'\'1' => {
		'length' => 5,
		'desc' => 'Write enable EEPROM',
		'type' => 'eeprom',
		'nobundle' => 1,
		},
	'\'@' => {
		'length' => 5,
		'desc' => 'Reset module',
		'type' => 'eeprom',
		'nobundle' => 1,
		},

	'`' => {
		'length' => 2,
		'desc' => 'Echo byte',
		'type' => 'hex_byte',
		},
	'*' => {
		'length' => 1,
		'desc' => 'Echo a space',
		},
	'%' => {
		'length' => 1,
		'desc' => 'Read host data',
		},
};

my $recv_commands = {
	'IO24' => {
		length => 12,
		'desc' => 'ID units',
		'type' => 'io24',
		},

	'A' => {
		'length' => 2,
		'desc' => 'Wr Port A',
		'type' => 'hex_byte',
		},
	'B' => {
		'length' => 2,
		'desc' => 'Wr Port C',
		'type' => 'hex_byte',
		},
	'C' => {
		'length' => 2,
		'desc' => 'Wr Port C',
		'type' => 'hex_byte',
		},

	'!A' => {
		'length' => 3,
		'desc' => 'Wr Dir A',
		'type' => 'hex_byte',
		},
	'!B' => {
		'length' => 3,
		'desc' => 'Wr Dir B',
		'type' => 'hex_byte',
		},
	'!C' => {
		'length' => 3,
		'desc' => 'Wr Dir C',
		'type' => 'hex_byte',
		},

	'@A' => {
		'length' => 3,
		'desc' => 'Wr Pullup A',
		'type' => 'hex_byte',
		},
	'@B' => {
		'length' => 3,
		'desc' => 'Wr Pullup B',
		'type' => 'hex_byte',
		},
	'@C' => {
		'length' => 3,
		'desc' => 'Wr Pullup C',
		'type' => 'hex_byte',
		},

	'#A' => {
		'length' => 3,
		'desc' => 'Wr Thresh A',
		'type' => 'hex_byte',
		},
	'#B' => {
		'length' => 3,
		'desc' => 'Wr Thresh B',
		'type' => 'hex_byte',
		},
	'#C' => {
		'length' => 3,
		'desc' => 'Wr Thresh C',
		'type' => 'hex_byte',
		},

	'$A' => {
		'length' => 3,
		'desc' => 'Wr Schmitt A',
		'type' => 'hex_byte',
		},
	'$B' => {
		'length' => 3,
		'desc' => 'Wr Schmitt B',
		'type' => 'hex_byte',
		},
	'$C' => {
		'length' => 3,
		'desc' => 'Wr Schmitt C',
		'type' => 'hex_byte',
		},

	'R' => {
		'length' => 4,
		'desc' => 'Rd EEPROM word',
		'type' => 'eeprom_recv',
		},

	'\'' => {
		'length' => 2,
		'desc' => 'Echo byte',
		'type' => 'hex_byte',
		},
	' ' => {
		'length' => 1,
		'desc' => 'Echo a space',
		},
	'%' => {
		'length' => 16,
		'desc' => 'Read host data',
		'type' => 'host_data',
		},
};

# =============================================================================

sub _init_state {
	my $self = shift;
	my $data = $self->{'data'};

	$data->{'running'} = 1;
	share($data->{'running'});

	foreach my $key (keys %$status_commands) {
		$data->{$key} = 0;
		share($data->{$key});
	}
	foreach my $addr (0..63) {
		$data->{'rcvd eeprom '.$addr} = 0;
		share($data->{'rcvd eeprom '.$addr});
		$data->{'eeprom '.$addr} = 0;
		share($data->{'eeprom '.$addr});
	}
	foreach my $cmd (keys %$cmd_map) {
		$data->{'rcvd '.$cmd_map->{$cmd}} = 1;
		share($data->{'rcvd '.$cmd_map->{$cmd}});
		$data->{'rcvdcmd '.$cmd_map->{$cmd}} = 0;
		share($data->{'rcvdcmd '.$cmd_map->{$cmd}});
	}

	foreach my $var ((
			'last_status_fetch',
			'last_status_send',
			'last_eeprom_fetch')) {
		$data->{$var} = 0;
		share($data->{$var});
	}
}

=item I<eeprom_fetch($recv=1, $fetchall=0)>

Fetch the contents of the eeprom. If recv is 1 then it will wait
for the results to arrive, otherwise it returns immediately.

Additionally gets all the reserved and user space words if $fetchall is 1.

Returns 1 on success, 0 on failure.

=cut

sub eeprom_fetch {
	my $self = shift;
	my $recv = shift || 1;
	my $fetchall = shift || 0;

	my $last = 24;
	$last = 63 if($fetchall);

	foreach my $addr (0..24) {
		my $cmd = "'R".pack("CCC", $addr, 0, 0);
		if(!send_command($self, $cmd)) {
			print STDERR "WARNING: Unable to send eeprom request.\n";
			return 0;
		} else {
			if($recv && !recv_result($self, $cmd)) {
				print STDERR "WARNING: Timeout waiting for eeprom reply.\n";
				return 0;
			}
		}
	}
	$self->{'data'}->{'last_eeprom_fetch'} = time();
	return 1;
}

=item I<status_fetch($recv)>

Query the EtherIO24 for its current status. This will store
the current status of all I/O lines and their programmed
settings. If you don't intend to reset these settings then
this is important in order for the Net::Elexol::EtherIO24 to be
able to manipulate I/O lines on a per-bit basis.

If recv is 1 then it will wait
for the results to arrive, otherwise it returns immediately.

Returns 1 on success, 0 on failure.

=cut

sub status_fetch {
	my $self = shift;
	my $recv = shift;

	# Issue "read" commands and issue a read_command.
	# We can ignore the response since status-responses
	# will get updated in our state automagically.
	my $cmd;
	foreach my $key (sort keys %$status_commands) {
		$cmd .= $status_commands->{$key};
	}
	if(!send_command($self, $cmd)) {
		print STDERR "WARNING: Unable to send status request.\n";
		return 0;
	} else {
		if($recv && !recv_result($self, $cmd)) {
			print STDERR "WARNING: Error receiving status reply ($_error)\n" if($_debug);
			return 0;
		}
	}
	$self->{'data'}->{'last_status_fetch'} = time();
	return 1;
}

=item I<status_send>

Send all current status to the EtherIO24.

Returns 1 on success, 0 on failure.

=cut

sub status_send {
	my $self = shift;

	# Issue a series of write commands.
	my $cmd = '';
	foreach my $key (sort keys %$set_commands) {
		$cmd .= $set_commands->{$key}.pack("C", $self->{$key});
	}
	if(!send_command($self, $cmd)) {
		print STDERR "WARNING: Unable to send status.\n";
		return 0;
	}
	$self->{'data'}->{'last_status_send'} = time();
}

# =============================================================================

sub _decode_cmd {
	my $cmd = shift;
	my $len = shift;
	my $type = shift;

	my $txt = '';
	if($type eq 'hex_byte') {
		# dump non-cmd chars as hex bytes
		foreach my $i ($len..length($cmd)-1) {
			$txt .= sprintf("%02.2x ", unpack("x$i C1", $cmd));
		}
	} elsif($type eq 'eeprom') {
		my($addr, $msb, $lsb) = unpack("x2 CCC", $cmd);
		$txt = sprintf("addr: %d (%02.2x) val: %02.2x %02.2x",
			$addr, $addr, $msb, $lsb);
	} elsif($type eq 'eeprom_recv') {
		my($addr, $msb, $lsb) = unpack("x CCC", $cmd);
		$txt = sprintf("addr: %d (%02.2x) val: %02.2x %02.2x",
			$addr, $addr, $msb, $lsb);
	} elsif($type eq 'host_data') {
		$txt .= sprintf("Serial: %02.2x%02.2x%02.2x ".
				"IP: %d.%d.%d.%d ".
				"MAC: %02.2x:%02.2x:%02.2x:%02.2x:%02.2x:%02.2x",
				unpack("x$len CCCCCCCCCCCCC", $cmd));
	} elsif($type eq 'io24') {
		$txt .= sprintf("MAC: %02.2x:%02.2x:02.2x:02.2x:02.2x:02.2x  ".
				"Fw: %02.2x.$02.2x",
				unpack("x$len CCCCCCCC", $cmd));
	}

	return $txt;
}

sub _find_cmd {
	my $cmd = shift;
	my $cmds = shift;

	foreach my $len (1..length($cmd)) {
		my $c = substr($cmd, 0, $len);
		if($cmds->{$c}) {
			return $c;
		}
	}
	return 0;
}

=item I<verify_send_command($cmd)>

Not normally called directly.

Verify commands to be sent. Returns 1 if the command(s) is(are) valid. Returns
0 if any command is invalud. Will search the entire string given for multiple commands.

Will perform various processing tasks on the command, such as resetting the
"status received" flags for any status fields referenced by the command.

=cut

sub verify_send_command {
	my $self = shift;
	my $cmd = shift;

	my $data = $self->{'data'};
	my $start = 0;
	my $ok = 1;
	while($start < length($cmd) && $ok) {
		my $c = _find_cmd(substr($cmd, $start, 6), $send_commands);
		if($c) {
			# found it!
			my $len = length($c);
			my $chk = substr($cmd, $start, $send_commands->{$c}->{'length'});
			if($_debug>1) {
				my $type = $send_commands->{$c}->{'type'} || 0;
				my $txt = _decode_cmd($chk, $len, $type);
				print "verify_send_command: cmd \"$c\" -> \"".
					$send_commands->{$c}->{'desc'}."\"".
					($txt ne ''?": $txt":"")."\n";
			}
# Hmm, what was this block of code for? It seems to slow things down and occasionaly hang the whole thing!
#			#if($set_map->{$c} && $self->{'threaded'}) {
#			if($cmd_map->{$c} && $self->{'threaded'}) {
#				# block waiting for any outstanding status queries to return
#				# to avoid a race condition
#				#my $f = 'rcvd '.$c;
#				my $f = 'rcvd '.$cmd_map->{$c};
#				my $timeout = time() + $self->{'recv_timeout'};
#				lock($data->{$f});
#				while(!$data->{$f}) {
#					print "verify_send_command: flag snd check data->{$f} = ".$data->{$f}."\n" if($_debug>2);
#					last if(!cond_timedwait($data->{$f}, $timeout));
#				}
#				print "verify_send_command: flag snd result data->{$f} = ".$data->{$f}."\n" if($_debug>2);
#				if(!$data->{$f}) {
#					$_error = 'Timeout waiting for outstanding status reply '.
#						'while trying to send new status';
#					$ok = 0;
#					last;
#				}
#
#			}
			if($cmd_map->{$c}) { # reset "received" status for query commands
				my $f = 'rcvd '.$cmd_map->{$c};
				if($cmd_map->{$c} eq 'R') { # save eeprom data
					# eepromness
					my($addr, $msb, $lsb) = unpack("x$len CCC", $chk);
					$f = 'rcvd eeprom '.$addr;
				}
				lock($data->{$f});
				$data->{$f} = 0;
				print "verify_send_command: flag send data->{$f} set to 0\n" if($_debug>2);
			}
			$start += $send_commands->{$c}->{'length'};
		} else {
			print "verify_send_command: cmd unknown: \"".substr($cmd, $start, 2)."\"\n" if($_debug);
			$ok = 0;
			last;
		}
	}

	return $ok;
}

=item I<verify_recv_command($cmd)>


Not normally called directly.

Verify a command is valid and if so, return how many bytes of it form
that valid command or 0 if invalid.

Will perform various tasks on the command, such as updating the stored
status of things referenced in the command. When threading, it also
sends a signal to indicate that new status has arrived, if relevant.

=cut

sub verify_recv_command {
	my $self = shift;
	my $cmd = shift;

	my $data = $self->{'data'};
	my $c = _find_cmd(substr($cmd, 0, 6), $recv_commands);
	if($c) {
		# found it!
		my $len = length($c);
		my $chk = substr($cmd, 0, $recv_commands->{$c}->{'length'});
		if(1||$_debug>1) {
			my $type = $recv_commands->{$c}->{'type'} || 0;
			my $txt = _decode_cmd($chk, $len, $type);
			print "verify_recv_command: cmd \"$c\" -> \"".
				$recv_commands->{$c}->{'desc'}."\"".
				($txt ne ''?": $txt":"")."\n" if($_debug>1);
		}
		# flag received status
		if($c ne 'R') { # only if not an eeprom
			my $f = 'rcvd '.$c;
			lock($data->{$f});
			$data->{$f} = 1;
			print "verify_recv_command: flag rcvd data->{$f} = 1\n" if($_debug>2);
			$data->{'rcvdcmd '.$c} = $chk; # store whole rcvd cmd too
			cond_signal($data->{$f});
		}

		if($set_map->{$c}) { # save new status
			my $k = $set_map->{$c};
			$data->{$k} = unpack("x$len C", $cmd);
			print "verify_recv_command: set_map \"$c\" ($k) = ".
				sprintf("%02.2x", $data->{$k})."\n" if($_debug>1);
		} elsif($c eq 'R') { # save eeprom data
			# eepromness
			my($addr, $msb, $lsb) = unpack("x$len CCC", $chk);
			$data->{'eeprom '.$addr} = ($msb * 256) + $lsb;
			print "verify_recv_command: eeprom \"$c\" addr $addr = ".
				sprintf("%02.2x %02.2x", $msb, $lsb)."\n" if($_debug>1);

			my $f = 'rcvd eeprom '.$addr;
			lock($data->{$f});
			$data->{$f} = 1;
			print "verify_recv_command: flag rcvd data->{$f} set to 1\n" if($_debug>2);
			$data->{'rcvdcmd '.$c} = $chk; # store whole rcvd cmd too
			cond_signal($data->{$f});
		}
		return $recv_commands->{$c}->{'length'};
	}

	print "verify_recv_command: cmd unknown: \"".substr($cmd, 0, 2)."\"\n" if($_debug);

	return 0;
}

# =============================================================================

=item I<send_command($cmd)>

Send a packet to the EtherIO24 unit. Passes it through verify_send_command
and then to send_pkt.

Returns 0 on failure, or the result of send_pkt otherwise.

=cut

sub send_command {
	my $self = shift;
	my $cmd = shift;

	return 0 if(!verify_send_command($self, $cmd));

	return send_pkt($self, $cmd);
}


=item I<recv_command>

Not normally called directly. See C<recv_result()> instead.

Wait for a packet from the EtherIO24 unit. Returns an array of received commands
upto any point where an invalid command was found in the input. Is NOT
thread-friendly unless used in a particular way!

Received packets are passed through verify_recv_command to parse into
commands and perform any automatic processing on them.

=cut

sub recv_command {
	my $self = shift;

	my $data = $self->{'data'};
	my $cmds = recv_pkt($self);
	if(!$cmds) {
		return 0;
	}

	my @cmds = ();
	while(length($cmds)) {
		my $len = verify_recv_command($self, $cmds);
		if(!$len) {
			print "recv_command encountered invalid command. Returning ".
				scalar(@cmds)." commands to caller.\n" if($_debug);
			last;
		}
		push(@cmds, substr($cmds, 0, $len));
		$cmds = substr($cmds, $len);
	}
	$_error = 0;
	return @cmds;
}

=item I<recv_result($cmd)>

Wait for results to arrive. May happen sync or async. Is thread-friendly.

Need to give $cmd for threaded operation so it knows what result in particular to wait for.
Returns undef if there was a problem doing this, such as a timeout waiting for the reply.

Replies with the reply command as received, except when it's an eeprom command and threads
are being used. In this case the actual command returned is an indeterminate recent eeprom
related reply.

=cut

sub recv_result {
	my $self = shift;
	my $cmd = shift; # what we wait for

	my $data = $self->{'data'};
	if($self->{'threaded'}) {
		# wait for our result to arrive
		my $c = _find_cmd($cmd, $send_commands) || _find_cmd($cmd, $recv_commands) || $cmd;
		if($cmd_map->{$c}) {
			$c = $cmd_map->{$c};
		}
		my $f = 'rcvd '.$c;
		if($c eq 'R') {
			my $len = length(_find_cmd($cmd, $send_commands));
			my($addr, $msb, $lsb) = unpack("x$len CCC", $cmd);
			$f = 'rcvd eeprom '.$addr;
		}

		my $timeout = time() + $self->{'recv_timeout'};
		lock($data->{$f});
		while(!$data->{$f}) {
			print "recv_result: flag check data->{$f} = ".$data->{$f}."\n" if($_debug>2);
			last if(!cond_timedwait($data->{$f}, $timeout));
		}
		print "recv_result: flag result data->{$f} = ".$data->{$f}."\n" if($_debug>2);
		if(!$data->{$f}) {
			$_error = 'Timeout waiting for reply';
			return undef;
		}
		if(!defined($data->{'rcvdcmd '.$c})) {
			# eek, strange error
			$_error = 'Data not delivered to main thread.';
			return 0;
		}
		$_error = 0;
		return $data->{'rcvdcmd '.$c};
	}

	# Go-do in realtime
	return recv_command($self);
}
	
# =============================================================================

=item I<send_pkt>

Send a packet over the socket. Not normally called directly.

=cut

sub send_pkt {
	my $self = shift;
	my $pkt = shift;

	my $socket = $self->{'socket'};
	my $ret =$socket->send($pkt);
	if(!defined($ret) || $ret<=0) {
		print "send_pkt: Unable to send packet: $!\n";
		return 0;
	}
	return 1;
}

=item I<recv_pkt>

Wait for a packet to come in. Not normally called directly.

=cut

sub recv_pkt {
	my $self = shift;

	my $data = $self->{'data'};
	my $socket = $self->{'socket'};

	# see if anything waits for us
	my @ready = ();
	my $sel = new IO::Select($socket);
	@ready = $sel->can_read($self->{'service_recv_timeout'});

	foreach my $fh (@ready) {
		if($fh = $socket) {
			# get packet
			my $pkt;
			if(!defined($socket->recv($pkt, 8192))) {
				$_error = "Unable to receive packet: $!";
				print "recv_pkt: Unable to receive packet: $!\n" if($_debug);
				return 0;
			}
			print "recv_pkt: received ".length($pkt)." bytes\n" if($_debug>1);
			$_error = 0;
			return $pkt;
		} else {
			# some other socket issue perhaps
		}
	}
	return 0;
}

# =============================================================================

sub _getgrp {
	my $line = shift;

	my $grp;
	$grp = "A" if($line >= 0 && $line < 8);
	$grp = "B" if($line >= 8 && $line < 16);
	$grp = "C" if($line >= 16 && $line < 24);
	my $bit = $line % 8;

	return ($grp, $bit, (1 << $bit));
}

# =============================================================================

=item I<reboot>

Restarts the module. Needed to make any eeprom changes take affect.

=cut

sub reboot {
	my $self = shift;

	return send_command($self, "'@".pack('C*', 0, 0xaa, 0x55));
}

=item I<set_line($line, $val)>

Sets the line to boolean val and sends to EtherIO module.

Ignored if line is (believed to be) an input.

=cut

sub set_line {
	my $self = shift;
	my $line = shift;
	my $val = shift;

	return undef if(!defined($line));
	return undef if(!defined($val));
	return undef if($line < 0 || $line > 23);

	my $data = $self->{'data'};

	my ($linegrp, $bitno, $bitval) = _getgrp($line);

	my $var;
	$var = "dir ".$linegrp;
	if(($data->{$var} & $bitval)) {
		print "set_line: line $line ignored, is input\n" if($_debug > 1);
		return 0;
	}

	$var = "status ".$linegrp;
	if($val) {
		print "set_line: line $line set to ON\n" if($_debug > 1);
		$data->{$var} |= $bitval;
	} else {
		print "set_line: line $line set to OFF\n" if($_debug > 1);
		$data->{$var} &= ~$bitval;
	}
	return send_command($self, $set_commands->{$var}.pack("C", $data->{$var}));
}

=item I<get_line_live($line)>

Returns live boolean value of line.

=cut

sub get_line_live {
	my $self = shift;
	my $line = shift;

	return undef if(!defined($line));
	return undef if($line < 0 || $line > 23);

	my $data = $self->{'data'};

	my ($linegrp, $bitno, $bitval) = _getgrp($line);

	# get live value
	my $var;
	$var = "status ".$linegrp;
	send_command($self, $status_commands->{$var});
	recv_result($self, $status_commands->{$var});

	$var = "status ".$linegrp;
	my $val = (($data->{$var} & $bitval) != 0) + 0;
	print "get_line_live: line $line = ".($val?"ON":"OFF")."\n" if($_debug > 1);
	return $val;
}

=item I<get_line($line)>

Returns stored boolean value of line. If it's an
input, gets the live value instead.

=cut

sub get_line {
	my $self = shift;
	my $line = shift;

	return undef if(!defined($line));
	return undef if($line < 0 || $line > 23);

	my $data = $self->{'data'};

	my ($linegrp, $bitno, $bitval) = _getgrp($line);

	my $var;
	$var = "dir ".$linegrp;
	if(($data->{$var} & $bitval)) {
		# get live value
		print "get_line: getting live value for line $line\n" if($_debug > 1);
		$var = "status ".$linegrp;
		my $cmd = $status_commands->{$var};
		send_command($self, $cmd);
		recv_result($self, $cmd);
	}
	$var = "status ".$linegrp;
	my $val = (($data->{$var} & $bitval) != 0) + 0;
	print "get_line: line $line = ".($val?"ON":"OFF")."\n" if($_debug > 1);
	return $val;
}

=item I<set_line_dir($line, $dir)>

Set line direction. 0 = output, 1 = input.

=cut

sub set_line_dir {
	my $self = shift;
	my $line = shift;
	my $dir = shift;

	return undef if(!defined($line));
	return undef if($line < 0 || $line > 23);

	my $data = $self->{'data'};

	my ($linegrp, $bitno, $bitval) = _getgrp($line);

	my $var;
	$var = "dir ".$linegrp;
	if($dir) {
		print "set_line_dir: line $line set to ON\n" if($_debug > 1);
		$data->{$var} |= $bitval;
	} else {
		print "set_line_dir: line $line set to OFF\n" if($_debug > 1);
		$data->{$var} &= ~$bitval;
	}
	return send_command($self, $set_commands->{$var}.pack("C", $data->{$var}));
}

=item I<get_line_dir($line)>

Returns (stored) direction setting for $line. 0 = output, 1 = input.

=cut

sub get_line_dir {
	my $self = shift;
	my $line = shift;

	return undef if(!defined($line));
	return undef if($line < 0 || $line > 23);

	my $data = $self->{'data'};

	my ($linegrp, $bitno, $bitval) = _getgrp($line);

	my $var;
	$var = "dir ".$linegrp;
	my $val = (($data->{$var} & $bitval) != 0) + 0;
	print "get_line_dir: line $line = ".($val?"IN":"OUT")."\n" if($_debug > 1);
	return $val;
}

=item I<set_line_pullup($line, $pullup)>

Set input line pullup. 0 = pullup off, 1 = pullup on.

=cut

sub set_line_pullup {
	my $self = shift;
	my $line = shift;
	my $pullup = shift;

	return undef if(!defined($line));
	return undef if($line < 0 || $line > 23);

	my $data = $self->{'data'};

	my ($linegrp, $bitno, $bitval) = _getgrp($line);

	my $var;
	$var = "pullup ".$linegrp;
	if($pullup) {
		print "set_line_pullup: line $line set to pullup ON\n" if($_debug > 1);
		$data->{$var} |= $bitval;
	} else {
		print "set_line_pullup: line $line set to pullup OFF\n" if($_debug > 1);
		$data->{$var} &= ~$bitval;
	}
	return send_command($self, $set_commands->{$var}.pack("C", $data->{$var}));
}

=item I<get_line_pullup($line)>

Returns (stored) pullup setting for $line. 0 = pullup off, 1 = pullup on.

=cut

sub get_line_pullup {
	my $self = shift;
	my $line = shift;

	return undef if(!defined($line));
	return undef if($line < 0 || $line > 23);

	my $data = $self->{'data'};

	my ($linegrp, $bitno, $bitval) = _getgrp($line);

	my $var;
	$var = "pullup ".$linegrp;
	my $val = (($data->{$var} & $bitval) != 0) + 0;
	print "get_line_pullup: line $line = ".($val?"pullup ON":"pullup OFF")."\n" if($_debug > 1);
	return $val;
}

=item I<set_line_thresh($line, $thresh)>

Set line threshhold. 0 = 2.5v (TTL), 1 = 1.4v (CMOS).

=cut

sub set_line_thresh {
	my $self = shift;
	my $line = shift;
	my $thresh = shift;

	return undef if(!defined($line));
	return undef if($line < 0 || $line > 23);

	my $data = $self->{'data'};

	my ($linegrp, $bitno, $bitval) = _getgrp($line);

	my $var;
	$var = "thresh ".$linegrp;
	if($thresh) {
		print "set_line_thresh: line $line set to 1.4v (CMOS)\n" if($_debug > 1);
		$data->{$var} |= $bitval;
	} else {
		print "set_line_thresh: line $line set to 2.5v (TTL)\n" if($_debug > 1);
		$data->{$var} &= ~$bitval;
	}
	return send_command($self, $set_commands->{$var}.pack("C", $data->{$var}));
}

=item I<get_line_thresh($line)>

Returns (stored) threshold setting for $line. 0 = 2.5v (TTL), 1 = 1.4v (CMOS).

=cut

sub get_line_thresh {
	my $self = shift;
	my $line = shift;

	return undef if(!defined($line));
	return undef if($line < 0 || $line > 23);

	my $data = $self->{'data'};

	my ($linegrp, $bitno, $bitval) = _getgrp($line);

	my $var;
	$var = "thresh ".$linegrp;
	my $val = (($data->{$var} & $bitval) != 0) + 0;
	print "get_line_thresh: line $line = ".($val?"1.4v (CMOS)":"2.5v (TTL)")."\n" if($_debug > 1);
	return $val;
}

=item I<set_line_schmitt($line, $schmitt)>

Set line Schmitt trigger. 0 = off, 1 = on.

=cut

sub set_line_schmitt {
	my $self = shift;
	my $line = shift;
	my $schmitt = shift;

	return undef if(!defined($line));
	return undef if($line < 0 || $line > 23);

	my $data = $self->{'data'};

	my ($linegrp, $bitno, $bitval) = _getgrp($line);

	my $var;
	$var = "schmitt ".$linegrp;
	if($schmitt) {
		print "set_line_schmitt: line $line set to ON\n" if($_debug > 1);
		$data->{$var} |= $bitval;
	} else {
		print "set_line_schmitt: line $line set to OFF\n" if($_debug > 1);
		$data->{$var} &= ~$bitval;
	}
	return send_command($self, $set_commands->{$var}.pack("C", $data->{$var}));
}

=item I<get_line_schmitt($line)>

Returns (stored) schmitt setting for $line. 0 = off, 1 = on.

=cut

sub get_line_schmitt {
	my $self = shift;
	my $line = shift;

	return undef if(!defined($line));
	return undef if($line < 0 || $line > 23);

	my $data = $self->{'data'};

	my ($linegrp, $bitno, $bitval) = _getgrp($line);

	my $var;
	$var = "schmitt ".$linegrp;
	my $val = (($data->{$var} & $bitval) != 0) + 0;
	print "get_line_schmitt: line $line = ".($val?"IN":"OUT")."\n" if($_debug > 1);
	return $val;
}

=item I<set_autoscan_addr($addr, $port)>

Programs an IP address to use for autoscan functions.

$addr is an ASCII string representation of an IP address.
$port is a numeric UDP port number.

If not specified, it will attempt to determine the current
IP address and port of the open UDP socket. This may not always
be successful!

If $addr is a numeric 0 then the autoscan function will be disabled
on the module.

Changes made by this function require a module restart to take effect.

=cut

sub set_autoscan_addr {
	my $self = shift;
	my $addr = shift;
	my $port = shift;

	my $data = $self->{'data'};

	if(!$self->{'prefetch_status'}) {
		eeprom_fetch($self, 1);  # 1=wait for response
	}

		$data->{'eeprom 5'} &= ~5; # subtract bit 4 to enable autoscan
		send_command($self, "'W".pack('C*', 5, ($data->{'eeprom 5'} >> 8) & 0xff, $data->{'eeprom 5'} & 0xff));
}

=item I<set_autoscan_line($line, $state)>

Sets the autoscan state of line $line.

Where $state = 1, the module will send status changes for $line.

Changes made by this function require a module restart to take effect.

=cut

sub set_autoscan_line {
	my $self = shift;
	my $line = shift;
	my $state = shift || 1;
}

=item I<set_startup_status($state)>

If $state is 1, uses the current status to set the startup status. Details such
as line direction, trigger levels, etc are programmed into the
eeprom. Status from the module is fetched prior to setting
the startup status if not pre-fetched at object creation.

Otherwise, disables startup port status setting.

Changes made by this function require a module restart to take effect.

=cut

sub set_startup_status {
	my $self = shift;
	my $state = shift || 1;

	my $data = $self->{'data'};

	if(!$self->{'prefetch_status'}) {
		status_fetch($self, 1);  # 1=wait for response
		eeprom_fetch($self, 1);  # 1=wait for response
	}

	my $fields = {
		8	=> [ 'status A',  'dir A' ],
		9	=> [ 'pullup A',  'thresh A' ],
		10	=> [ 'dir B',     'schmitt A' ],
		11	=> [ 'thresh B',  'status B' ],
		12	=> [ 'schmitt B', 'pullup B' ],
		13	=> [ 'status C',  'dir C' ],
		14	=> [ 'pullup C',  'thresh C' ],
		15	=> [ 0,           'schmitt C' ],
	};

	send_command($self, "'1".pack('CCC', 0, 0xaa, 0x55)); # write enable

	if($state) {
		$data->{'eeprom 5'} &= ~2; # subtract bit 2 to enable port preset
		send_command($self, "'W".pack('CCC', 5, ($data->{'eeprom 5'} >> 8) & 0xff, $data->{'eeprom 5'} & 0xff));

		foreach my $field (sort { $a <=> $b } keys %$fields) {
			my $arr = $fields->{$field};
			$data->{'eeprom '.$field} = ((@$arr[0]?$data->{@$arr[0]}:0) * 256) + (@$arr[1]?$data->{@$arr[1]}:0);
			send_command($self, "'W" . pack('CCC', $field, ($data->{'eeprom '.$field} >> 8) & 0xff, $data->{'eeprom '.$field} & 0xff));
		}
	} else {
		$data->{'eeprom 5'} |= 2; # add bit 2 to enable port preset
		send_command($self, "'W".pack('C*', 5, ($data->{'eeprom 5'} >> 8) & 0xff, $data->{'eeprom 5'} & 0xff));

		foreach my $field (sort { $a <=> $b } keys %$fields) {
			send_command($self, "'W" . pack('CCC', $field, 0xff, 0xff));
		}
	}

	send_command($self, "'0".pack('CCC', 0, 0xaa, 0x55)); # write disable
}

=back

=head1 NOTE

The author is not in any way affiliated with Elexol, the manufacturer of the device
this Perl module is designed to operate. This module has been developed using only
data available in the public domain.

=head1 SEE ALSO

L<http://www.flirble.org/chrisy/elexol/>, L<http://www.elexol.com/>, L<http://www.elexol.com/Downloads/EtherIO24UM11.pdf>

=head1 AUTHOR

Chris Luke C<< <chrisy@flirble.org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-net-elexol-etherio24@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Net-Elexol-EtherIO24>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

Copyright 2005 Chris Luke, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1; # End of Net::Elexol::EtherIO24

