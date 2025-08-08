#!/bin/bash
#set -ex
#ec2-metadata --availability-zone
if [[ $EUID -ne 0 ]]; then
	echo "$0 is not running as root. Try using sudo."
	exit 2
fi
echo "Disabling IPv6 and making sure IPv4 forwarding is enabled"
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.ens5.disable_ipv6=1
## should probably source vars and exit if they are already set
## it's kinda weird that this check exists in the orchestration AND in the actual shaping script -> how to solve? probably would have to make this script detect an exit 1 from the shaping script and call delete in the shaping script...
while true
do
	while read uri; do
	echo ${uri}
		echo "shaping rtts"
		while read rtt_symm; do
			echo ${rtt_symm}
			echo "setting up namespace"
			./setup-shaping.sh CREATE "NO_SHAPING NO_SHAPING ${rtt_symm} ens5"
			echo "web perf"
			#quoting the arguments somewhat ensures that potential spaces in the arguments don't split up the argument list
			#ip netns exec client-net python3 lei-measure-website.py "${uri}" "rtt ${rtt_symm}" eu-central-1
			CURR_TIME=$(date '+%Y-%m-%d_%H-%M-%S')
			ip netns exec client-net node navigation-and-paint-timings-run.js "rtt ${rtt_symm}" "${uri}" > "msm_${CURR_TIME}.log" 2>&1
			echo "shutting down"
			./setup-shaping.sh DELETE
		done < rtts-symmetric.txt

		echo "shaping dl bandwidth"
		while read dlbw; do
			echo "${dlbw}"
			#apply download
			./setup-shaping.sh CREATE "${dlbw} NO_SHAPING NO_SHAPING NO_SHAPING ens5"
			echo "web perf"
			#ip netns exec client-net python3 lei-measure-website.py "${uri}" "dl bw ${dlbw}" eu-central-1
			CURR_TIME=$(date '+%Y-%m-%d_%H-%M-%S')
			ip netns exec client-net node navigation-and-paint-timings-run.js "dl bw ${dlbw}" "${uri}" > "msm_${CURR_TIME}.log" 2>&1
			echo "shutting down"
			./setup-shaping.sh DELETE
		done < bandwidths-dl.txt

		echo "shaping ul bandwidth"
		while read ulbw; do
			echo "${ulbw}"
			#apply upload
			./setup-shaping.sh CREATE "NO_SHAPING ${ulbw} NO_SHAPING NO_SHAPING ens5"
			echo "web perf"
			#ip netns exec client-net python3 lei-measure-website.py "${uri}" "ul bw ${ulbw}" eu-central-1
			CURR_TIME=$(date '+%Y-%m-%d_%H-%M-%S')
			ip netns exec client-net node navigation-and-paint-timings-run.js "ul bw ${ulbw}" "${uri}" > "msm_${CURR_TIME}.log" 2>&1
			echo "shutting down"
			./setup-shaping.sh DELETE
		done < bandwidths-ul.txt
		#lei-setup-bandwidth-only.sh CREATE 10Mbit 5Mbit ens5
		#lei-setup-bandwidth-only.sh DELETE
		#ip netns exec client-net python3 lei-measure-website.py
	done < websites.txt
done