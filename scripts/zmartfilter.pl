use strict;
use Irssi;
use vars qw($VERSION %IRSSI);

$VERSION = "1.02";
%IRSSI = (
	name        => "zmartfilter",
	description => "smartfilter.pl reimagined, optimized for unusually flakey networks such as IRC over I2P",
	license     => "Public Domain",
);

# The maximum number of filtered messages to display from a user within the
# allow_time before squelching early; set to <=0 for infinite.
Irssi::settings_add_int($IRSSI{name}, "$IRSSI{name}_allow_max", 12);

# The length of time to continue displaying filtered messages from users after
# they last exhibited activity (until allow_max is reached).
Irssi::settings_add_time($IRSSI{name}, "$IRSSI{name}_allow_time", "8hour");

# The length of time after an inactive user joins to squelch automated mode
# change by services messages.
Irssi::settings_add_time($IRSSI{name}, "$IRSSI{name}_join_time", "1min");

# A whitespace-delimited list of channels that are not subject to filtering.
Irssi::settings_add_str($IRSSI{name}, "$IRSSI{name}_whitelist_channels", "");


Irssi::theme_register([
	squelched => "{channick_hilight \$0} {chanhost_hilight \$1} squelched",
]);


my ($allow_max, $allow_time, $join_time, @whitelist_channels, $completion_re);

sub setup_changed {
	$allow_max = Irssi::settings_get_int("$IRSSI{name}_allow_max");
	$allow_time = Irssi::settings_get_time("$IRSSI{name}_allow_time") / 1000;
	$join_time = Irssi::settings_get_time("$IRSSI{name}_join_time") / 1000;
	@whitelist_channels = split(/\s+/, Irssi::settings_get_str("$IRSSI{name}_whitelist_channels"));
	$completion_re = qr/^\s*(\S+)\Q@{[Irssi::settings_get_str("completion_char")]}\E\s/;
}

Irssi::signal_add("setup changed", \&setup_changed);
setup_changed();


# %tactive are last activity timestamps, and %nallowed are the number of
# filterable messages allowed through since the last activity.  Both are keyed
# by ($server->{tag}, $channel, $address).
my (%tactive, %nallowed) = ( collect => time() );

# %tjoined are join timestamps keyed by ($server->{tag}, $channel, $nick), used
# to squelch automated mode change by services messages shortly after inactive
# users join a channel.
my %tjoined = ( collect => time() );

# indicate activity from the given address (or nick if the address is unknown)
# in the given channel on the given server
sub activity {
	my ($server, $target, $address, $nick) = @_;

	if (!$server->ischannel($target) || ($nick && $server->{nick} eq $nick)) {
		# don't bother tracking query windows or myself
		return;
	}

	if (!$address) {
		if (!$nick) {
			return;
		}
		my $user = $server->channel_find($target)->nick_find($nick);
		if (!$user) {
			return;
		}
		$address = $user->{host};
		if (!$address) {
			return;
		}
	}

	if ($server->mask_match_address('*!*@services.*', "", $address)) {
		# don't bother tracking network services
		return;
	}

	my ($key, $now) = ( join($;, $server->{tag}, $target, $address), time() );
	my $threshold = $now - $allow_time;
	if (!exists $tactive{$key} && $tactive{collect} <= $threshold) {
		# remove stale entries from the table before inserting new
		# ones, but at most once every $allow_time
		for my $key (grep { $tactive{$_} <= $threshold } keys %tactive) {
			delete $tactive{$key};
			delete $nallowed{$key};
		}
		$tactive{collect} = $now;
	}

	$tactive{$key} = $now;
	$nallowed{$key} = 0;
}

sub message_server_x_x_address_target { activity(@_[0, 4, 3]); }

sub message_own_public {
	my ($server, $msg, $target) = @_;
	if ($msg =~ $completion_re) {
		# I posted a message directed at someone else -- count the
		# other user as active so that I get to see if he changes nicks
		# or leaves
		activity($server, $target, undef, $1);
	}
}

sub message_join {
	my ($server, $channel, $nick, $address) = @_;

	my ($key, $now) = ( join($;, $server->{tag}, $channel, $nick), time() );
	my $threshold = $now - $join_time;
	if (!exists $tjoined{$key} && $tjoined{collect} <= $threshold) {
		# remove stale entries from the table before inserting new
		# ones, but at most once every $join_time
		for my $key (grep { $tjoined{$_} <= $threshold } keys %tjoined) {
			delete $tjoined{$key};
		}
		$tjoined{collect} = $now;
	}

	$tjoined{$key} = $now;
}

sub message_kick {
	my ($server, $channel, $nick, $kicker, $address) = @_;
	activity($server, $channel, $address);
	# also count the kickee as active so that we get to see if he rejoins
	activity($server, $channel, undef, $nick);
}

sub message_nick {
	my ($server, $newnick, $oldnick) = @_;
	# if this user recently joined any channels then entries relating to
	# $oldnick in the tjoined table need to be copied with $newnick; no
	# reason to bother deleting the $oldnick entries now, they will get
	# collected after $join_time elapses
	for my $oldkey (keys %tjoined) {
		my ($s, $t, $n) = split(/$;/, $oldkey);
		if ($s eq $server->{tag} && $n eq $oldnick) {
			my $newkey = join($;, $s, $t, $newnick);
			$tjoined{$newkey} = $tjoined{$oldkey};
		}
	}
}

sub message_server_channel_nick_address { activity(@_[0, 1, 3, 2]); }

Irssi::signal_add({
	"message public" => \&message_server_x_x_address_target,
	"message own_public" => \&message_own_public,
	"message join" => \&message_join,
	"message kick" => \&message_kick,
	"message nick" => \&message_nick,
	"message invite" => \&message_server_channel_nick_address,
	"message topic" => sub { activity(@_[0, 1, 4]); },
	"message irc op_public" => \&message_server_x_x_address_target,
	"message irc action" => \&message_server_x_x_address_target,
	"message irc own_notice" => \&message_own_public,
	"message irc notice" => \&message_server_x_x_address_target,
	"message irc ctcp" => sub { activity(@_[0, 5, 4]); },
	"message irc mode" => \&message_server_channel_nick_address,
});


# filter at the "print text" signal so that other scripts may still receive the
# message signals if they need them
sub print_text {
	my ($dest, $text, $stripped) = @_;

	# only filter text bound for a dest with a connected server
	my ($now, $server) = ( time(), $dest->{server} );
	if (!$server || !$server->{connected}) {
		return;
	}

	my ($level, @targets) = $dest->{level};
	if ($level & (MSGLEVEL_NICKS | MSGLEVEL_QUITS)) {
		# nick changes and quits are printed only once per window, so
		# $dest could reference a channel where this user is considered
		# inactive when there is another channel in the same window
		# (e.g., /JOIN -window or /QUERY -window) where the user is
		# considered active, in which case the text would be
		# erroneously suppressed; so all further processing must
		# consider every windowitem associated with this window and
		# server
		@targets = grep { $_->{server} && $_->{server}->{tag} eq $server->{tag} } $dest->{window}->items();
	} else {
		# other messages are printed for each windowitem, even if
		# they're in the same window, so @targets includes only the
		# single relevant windowitem
		@targets = ( $dest->{window}->item_find($server, $dest->{target}) );
	}

	# only filter text bound only for channels
	if (grep { !$server->ischannel($_->{name}) } @targets) {
		return;
	}

	# don't filter text bound for channels in the whitelist
	for my $target (@targets) {
		if (grep { $_ eq $target->{name} } @whitelist_channels) {
			return;
		}
	}

	my (@nicks, %addresses);
	if ($level & (MSGLEVEL_JOINS | MSGLEVEL_PARTS | MSGLEVEL_QUITS)) {
		if ($stripped =~ /([^ ]+) \[([^]]+)\] has (changed|joined|left|quit)/) {
			@nicks = ($1);
			# this nick may have just parted or quit, in which case
			# we can't rely on the channel->nick->address lookup,
			# so we need to use the address in the message text
			# when we can
			$addresses{$1} = $2;
		}
	} elsif ($level & MSGLEVEL_NICKS) {
		if ($stripped =~ /[^ ]+ is now known as ([^ ]+)/) {
			@nicks = ($1);
		}
	} elsif ($level & MSGLEVEL_MODES) {
		if ($stripped =~ /mode\/[^ ]+ \[\+[^ ]+ (.+)\] by ChanServ/) {
			@nicks = split(/ +/, $1);
		}
	}
	if (!@nicks) {
		# doesn't match a filtered message
		return;
	}

	# use all filtered message levels for the squelched message level
	my $slevel = MSGLEVEL_JOINS | MSGLEVEL_PARTS | MSGLEVEL_QUITS |
			MSGLEVEL_NICKS | MSGLEVEL_MODES;
	my ($athreshold, $jthreshold) = ( $now - $allow_time, $now - $join_time );
	for my $target (@targets) { for my $nick (@nicks) {
		if ($nick eq $server->{nick}) {
			# it's text that relates to me
			return;
		}
		my $address = $addresses{$nick};
		if (!$address) {
			$address = $target->nick_find($nick);
			$address = $address->{host};
			if (!$address) {
				next;
			}
			$addresses{$nick} = $address;  # for future iterations
		}
		if ($server->mask_match_address('*!*@services.*', "", $address)) {
			# relates to network services
			return;
		}
		my $key = join($;, $server->{tag}, $target->{name}, $address);
		my $tstamp = $tactive{$key};
		if ($tstamp && $athreshold < $tstamp) {
			if (0 < $allow_max && ++$nallowed{$key} <= $allow_max) {
				# relates to an active user who hasn't been
				# squelched by $allow_max yet
				return;
			}
			$server->printformat($target->{name}, $slevel, "squelched",
				$nick, $address);
			delete $tactive{$key};
			delete $nallowed{$key};
		}
		if ($level & MSGLEVEL_MODES) {
			# also check whether any nicks affected by a mode
			# change were NOT recently joined, in which case this
			# was a spontaneous mode change (perhaps a new operator
			# elevation) and I want to see it
			$tstamp = $tjoined{$server->{tag}, $target->{name}, $nick};
			if (!$tstamp || $tstamp <= $jthreshold) {
				return;
			}
		}
	} }

	# if I made it this far it means this text is to be suppressed
	Irssi::signal_stop();
}

Irssi::signal_add_first("print text", \&print_text);
