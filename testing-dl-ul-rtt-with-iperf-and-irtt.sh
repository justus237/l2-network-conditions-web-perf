#!/bin/bash
#set -ex
#ec2-metadata --availability-zone
if [[ $EUID -ne 0 ]]; then
	echo "$0 is not running as root. Try using sudo."
	exit 2
fi
## should probably source vars and exit if they are already set
## it's kinda weird that this check exists in the orchestration AND in the actual shaping script -> how to solve? probably would have to make this script detect an exit 1 from the shaping script and call delete in the shaping script...

echo "shaping rtts"
while read shaping_string; do
	echo ${shaping_string}
	echo "setting up namespace"
	./setup-shaping.sh CREATE ${shaping_string} ens5
	echo "ping"
	#quoting the arguments somewhat ensures that potential spaces in the arguments don't split up the argument list
	ip netns exec client-net /home/ubuntu/go/bin/irtt client -4 -q -d 10s 192.168.0.2
	echo "download"
	ip netns exec client-net iperf3 -c 192.168.0.2 -R -u -b "10M" #${shapings[0]}
	echo "upload"
	ip netns exec client-net iperf3 -c 192.168.0.2 -u -b "10M" #${shapings[1]}
	echo "shutting down"
	./setup-shaping.sh DELETE
done < dl-ul-rtt-shaping-short.txt
