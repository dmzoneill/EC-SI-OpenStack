#!/usr/local/bin/perl
while (<>) 
{
	chop;
	@F = split;
	$L = $F[3];                     # local cache result code
	$H = $F[8];                     # hierarchy code
	next unless ($L =~ /TCP_/);     # skip UDP and errors
	$N++;
	$timeout++ if ($H =~ /TIMEOUT/);
	if ($L =~ /HIT/) {
		$local_hit++;
	} elsif ($H =~ /HIT/) {
		$remote_hit++;
	} elsif ($H =~ /MISS/) {
		$remote_miss++;
	} elsif ($H =~ /DIRECT/) {
		$direct++;
	} else {
		$other++;
	}
}
printf "TCP-REQUESTS %d\n", $N;
printf "TIMEOUT %f\n", 100*$timeout/$N;
printf "LOCAL-HIT %f\n", 100*$local_hit/$N;
printf "REMOTE-HIT %f\n", 100*$remote_hit/$N;
printf "REMOTE-MISS %f\n", 100*$remote_miss/$N;
printf "DIRECT %f\n", 100*$direct/$N;
printf "OTHER %f\n", 100*$other/$N;