#!/usr/bin/perl
use strict;
use warnings;
use v5.014;
use POE qw(Component::IRC::State);
use Getopt::Long;

our %config = ();
our %handlers = ();
our @modules = qw(
	Joke
	Regexp
	Base
	Web
	Encoder
);
our %module_states = ();
our %module_errors = ();
# unloaded modules
our @unloaded = qw();
our $cfgfile="$ENV{HOME}/.nothingbot.conf";

if (not -e $cfgfile) {
	open my $out, ">", $cfgfile or die "failed to create config file - $!";
	print $out 
	"# Lines starting with '#' are ignored.\n",
	"# nickname to use in IRC\n",
	"nick=nothingbot\n",
	"# real name to use for IRC\n",
	"user=nothingbot\n",
	"# IRC server to connect to\n",
	"server=irc.example.com\n",
	"# port of this IRC server (usually 6667 for plain, 6697 for SSL)\n",
	"port=6667\n",
	"# prefix to use for commands like help\n",
	"prefix=+\n",
	"# comma-separated list of channels to use.\n",
	"channels=##example,##example2\n",
	"# IRC user mask of admin user. CHANGE THIS OR HAVE PEOPLE HAX YOUR NOTHINGBOT.\n",
	"umask=*!*@*\n";
	print STDERR "no config file. A default has been generated at $cfgfile. ",
    "You may want to edit it before going any further.\n";
	exit 2;
}
our $gnick;
our $user;
our $srvr;
our $port;
our $prefix;
our $umask="";
our @channels;
my @ownercmds = qw(join quit restart reload); # only the owner can do these.
my @opcmds = qw(leave); # only channel ops can make the bot leave a channel.
my $print_help = 0;

GetOptions(
	"config|cfg=s"  => \$cfgfile,
	"help"			=> \$print_help
);
if ($print_help != 0) {
	print "usage: $0 [--config=FILE] [--help]\n",
	"by default, config is stored in $ENV{HOME}/.nothingbot.conf\n";
	exit 3;
}

load_config();

sub add_op_cmd {
	my $cmd = shift;
	print "op => $cmd\n";
	push @opcmds, $cmd;
}
sub add_owner_cmd {
	my $cmd = shift;
	print "owner => $cmd\n";
	push @ownercmds, $cmd;
}

sub load_config {
	undef $gnick;
   	undef $user;
	undef $srvr;
	undef $port;
   	undef $prefix;
	@channels = ();
	%config = ();
	$umask = "";
	my $file;
	open $file, "<", $cfgfile or die "Failed to read config file $file: $!";
	while (<$file>) {
		chomp;
		next if /^\s*#/;
		die "invalid line at $cfgfile line $." if not m/=/; # $. = line number. perldoc -v $.
		my @parts = split('=', $_, 2);
		if ($parts[0] eq "nick") {
			$gnick = $parts[1];
		}
		elsif ($parts[0] eq "user") {
			$user = $parts[1];
		}
		elsif ($parts[0] eq "server") {
			$srvr=$parts[1];
		}
		elsif ($parts[0] eq "port") {
			$port=$parts[1];
		}
		elsif ($parts[0] eq "prefix") {
			$prefix=$parts[1];
		}
		elsif ($parts[0] eq "channels") {
			@channels=split/,/, $parts[1];
		}
		elsif ($parts[0] eq "umask") {
			if ($parts[1] =~ /^\*!\*\@\*/) {
				print STDERR "$parts[1] is an invalid umask - too open. can't have people haxing your computer now, can we?\n";
				exit 5;
			}
			$umask = $parts[1];
			$umask =~ s/\*/\.\*/g;
		}
		$config{$parts[0]} = $parts[1];

	}
	close $file;
}

my %help = ();#("NothingBot \x02v0.1\x02");
sub register_listener_hash {
	my $hash = shift;
	my $super = (caller(0))[0];
	print "Procesing hash from $super....\n";
	$handlers{$super} = $hash;

}

sub register_help_msgs {
	my $source = shift;
	#push @help, "\x02Commands from module $source\x02:";
	my @j = grep { s/^\Q$prefix\E// } @_;
	$help{$source} = \@j;
}
push @INC, "./plugins";
for (@modules) {
	eval 'require "plugins/$_.pm";';
	if (not $@) {
		require "plugins/$_.pm";
		print "NothingBot::Plugins::${_}::register()\n";
		"NothingBot::Plugins::${_}"->register();
		$module_states{"NothingBot::Plugins::$_"} = "SUCCESS";
	}
	else {
		$module_states{"NothingBot::Plugins::$_"} = "FAILED";
		$module_errors{"NothingBot::Plugins::$_"} = $@;
		print STDERR "Module '$_' failed to load: $@\n";
	}
}


our $irc = POE::Component::IRC::State->spawn(
	nick => $gnick,
	server => $srvr,
	port => int $port,
	ircname => $user,
	flood	=> 1,
	username=>"nothingbot"
	
) or die "Failed to connect: $!";

POE::Session->create(
	package_states => [
		main => [ qw(_default _start irc_001 irc_public irc_msg irc_whois irc_ctcp) ],
	],
	heap => { irc => $irc }
);

$poe_kernel->run();

my @memory = ();

my %lastmessages = ();


our $AWAY = undef;

sub _start {
	my ($kernel, $heap) = @_[KERNEL, HEAP];

	my $irc_session = $heap->{irc}->session_id();
	$kernel->post($irc_session => register => 'all');
	$kernel->post($irc_session => connect => {} );
	return;
}

sub _default {
	my ($event, $args) = @_[ARG0 .. $#_];
	if ($event eq "irc_372") {
		return;
	}
	my @output = ( "$event: ");
	for my $arg (@$args) {
		if (ref $arg eq 'ARRAY') {
			push(@output, "\n\t[" . join(', ', @$arg) . ']');
		}
		else {
			push @output, $arg;
		}
	}
	print join(' ', @output), "\n";
	return 0;
}

sub irc_001 {
	my ($kernel, $sender) = @_[KERNEL, SENDER];
	my $poco = $sender->get_heap(); #POE::Component object
	print "Connected to ", $poco->server_name(), "\n";
	$kernel->post( $sender => join => $_ ) for @channels;
	return;
}

sub irc_msg {
	my @new_args = @_;

	irc_public(@_);
}

sub should_handle_msg {
	return 1;
}

our $DISABLE_AUTH = 0;
sub check_can_run {
	my $cmd = shift;
	my $who = shift;
	my $where = shift;
	my $is_chan = 0;
	if (grep(/^#/, @$where)) {
		$is_chan = 1;
	}
	print "$is_chan\n";
	my @biglist = @opcmds;
	#push @opcmds, $_ for @ownercmds;
	print "check auth: $cmd for $who in ", join(' ', @$where), "\n";
	
	if ($who =~ /^$umask$/ and ($DISABLE_AUTH != 1 or $cmd eq "recover")) {
		print "$who =~ /^$umask$/\n";
		return 1;
	}
	elsif (scalar(grep !/^$cmd$/, @biglist) == $#biglist) {
		print "$cmd not in biglist\n";
		return 1;
	}
	elsif (grep /^$cmd$/, @opcmds) {
		if ($is_chan and $irc->yield(is_channel_operator => $where => (split(/!/, $who))[0])) {
			print "$cmd is op cmd and $who is op.\n";
			return 1;
		}
		else {
			print "ACCESS DENIED - op required for $who\n";
			return 0;
		}
	}
	elsif (grep /^$cmd$/, @ownercmds) {
		print "not umask. disallowing.\n";
		return 0;
	}
	print "allowed by default.\n";
	return 1;
}

sub irc_public {
	my ($kernel, $sender, $who, $where, $what) = @_[KERNEL, SENDER, ARG0..ARG2];
	if ($AWAY and not $what =~ /^\Q$prefix\Ecomeback/) {
		return	;
	}
	my $nick = (split/!/, $who)[0];
	my $chan = $where;
	if (grep($gnick, @$where) and not grep(/^#/, @$where)) {
		my @w = grep { $_ ne $gnick } @$where;
		push @w, $nick;
		$where = \@w;
	}
	my @w = grep { $_ ne $gnick } @$where;
	$where = \@w;
	my $poco = $sender->get_heap();
	print "$who ($chan->[0]): '$what'\n";
	if ($what =~ /^\Q$prefix\E/) {
		my $cmd = (split/ /, $what)[0];
		$cmd =~ s/^\Q$prefix\E//;
		if (check_can_run($cmd, $who, $where) == 0) {
			$::irc->yield(notice => $nick => "Access denied.");
			return;
		}
		if ((split/ /, $what)[-1] =~ /^\@\@/) {
			print "@@ detected!\n";
			# redirect
			my $targ = (split/ /, $what)[-1];
			$targ =~ s/^\@\@//;
			print "new targ: $targ\n";
			$who = "$targ!*@*";
			if (grep $nick, @$where and not grep(/^#/, @$where)) {
				my @w = grep {$_ ne $nick} @$where;
				push @w, $targ;
				$where = \@w;
			}
			$nick = $targ;
			my @z = split/ /, $what;
			pop @z;
			$what = join(' ', @z);
		}
	}
	print "new what: $what\n";	
	if ($what =~ /^\Q${prefix}\Ehelp/i or $what =~ /^${gnick}.? help/) {
		my @args = split/ /, $what;
		shift @args;
		if (@args) {
			if (grep /^\Q$args[0]\E$/, keys %help) {
				print "notice to $nick\n";
				$irc->yield(notice => $nick => "Command(s) from \x02$args[0]\x0f: " . join(', ', @{$help{$args[0]}}));
				return;
			}

			my @matches = ();
			for (keys %help) {
				my $h = $help{$_};
				for my $k (grep(/^\Q$args[0]\E/, @{$h})) {
					push @matches, $k;
				}
			}
			$kernel->post($sender => notice => $nick => "Match(es): " . join(", ", @matches));
		}
		else {
			my $str = "";
			for (keys %help) {
				$str .= "\x02$_\x0f ";
				for (@{$help{$_}}) {
					$str .= (split/ /)[0] . " ";
				}
			}
			$kernel->post($sender => notice => $nick => "$str");
		   	$kernel->post($sender => notice => $nick => "help <cmd> for more info on a command. You can also tell me".
			   " things in the format '$gnick, x is y, ok?', and ask for it back in the format '$gnick, what is x?'");
		}
		#for (@help) {
		#	$kernel->post($sender => privmsg => $nick => $_);
		#}
		#$kernel
		return;
	}
	elsif ($what =~ /^\Q${prefix}\Eauthlevel/i) {
		if ($who =~ /^$umask/) {
			$kernel->post($sender => notice => $nick => "You are my master.");
		}
		else {
			$kernel->post($sender => notice => $nick => "You are just another person.");
		}
		return;
	}
	elsif ($what =~ /^\Q${prefix}\Erecover/) {
		$::irc->yield(notice => $nick => "auth \x02re-activated\x0f.");
		$DISABLE_AUTH = 0;
	}
	elsif ($what =~ /^\Q${prefix}\Eauth disable/) {
		$::irc->yield(notice => $nick => "auth \x02disabled\x0f. '${prefix}recover to re-activate");
		$DISABLE_AUTH = 1;
	}
	OUTER:
	for my $package (keys %handlers) {
		if (grep /^$package$/, @unloaded) {
			next;
		}
		print "$package...\n";
		for my $handler (@{$handlers{$package}->{irc_msg}}) {
			#print "pass message on to $handler.\n";
			#if (not defined $handler or *handler->{PACKAGE} eq "__ANON__") {
			#	print "it's a trap!\n";
			#	next;
			#}
			print "  handler!\n";
			my $answer = 0;
			my $stdout = "";
			my $stderr = "";
			{
				local *STDOUT;
				local *STDERR;

				open STDOUT, ">", \$stdout;
				open STDERR, ">", \$stderr;
				$answer = eval '$handler->($who, $where, $what)';
				if ($@) {
					print "ERROR: $package failed to process event irc_msg (args $who, $where, $what): $@\n";
					$@ =~ s/\n//g;
					chomp $@;
					my $np = (split/::/,$package,3)[2];
					$stdout =~ s/\n//g;
					$stderr =~ s/\n//g;
					$irc->yield(notice => $nick => "\x0304Error\x0f :: running handler from module $np :: \x2f$@\x0f");
					$irc->yield(notice => $nick => "\x0304Error\x0f :: handler $np :: stdout :: $stdout");
					$irc->yield(notice => $nick => "\x0304Error\x0f :: handler $np :: stderr :: $stderr");
					next;
				}
			}
			if (defined $answer and $answer == 1) {
				print "$package\'s handler said to stop\n";
				last OUTER; # they want us to stop!
			}
		}
	}

}



sub irc_ctcp {
	my ($ctcp, $sender, $towhom, $what) = @_[ARG0..ARG3];
	if ($AWAY) {
		return;
	}
	$ctcp = lc $ctcp;
	if ($ctcp eq "source") {
		print "ctcp source detected.\n";
		$irc->yield(ctcpreply => (split(/!/,$sender))[0] => "SOURCE https://github.com/keepcalm444/nothingbot");
	}
	OUTER:
	for my $package (keys %handlers) {
		if (grep /^$package$/, @unloaded) {
			next;
		}
		for my $handler (@{$handlers{$package}->{irc_ctcp}}) {
			#print "pass message on to $handler.\n";
			#if (not defined $handler or *handler->{PACKAGE} eq "__ANON__") {
			#	print "it's a trap!\n";
			#	next;
			#}
			if ($handler->($ctcp, $sender, $towhom, $what) == 1) {
				last OUTER; # they want us to stop!
			}
		}
		for my $handler (@{$handlers{$package}->{"irc_ctcp_$ctcp"}}) {
			#print "pass message on to $handler.\n";
			#if (not defined $handler or *handler->{PACKAGE} eq "__ANON__") {
			#	print "it's a trap!\n";
			#	next;
			#}
			if ($handler->($sender, $towhom, $what) == 1) {
				last OUTER; # they want us to stop!
			}
		}
	}
}

sub irc_whois {
	print "whois!\n";
	my $hash = $_[ARG0];
	print ref $hash, "\n";
	print "data:\n";
	for (keys $hash) {
		if ($_ ne "channels") {
			print "$_: $hash->{$_}\n";
		}
		else {
			print "$_: ", join(', ', @{$hash->{$_}}), "\n";
		}
	}
}
