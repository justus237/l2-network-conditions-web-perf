#!/bin/bash
#set -ex
if [[ $EUID -ne 0 ]]; then
	echo "$0 is not running as root. Try using sudo."
	exit 2
fi

function run_experiment_for_defense {
	local DEFENSE=$1
	echo $DEFENSE
	echo "10Mbit 5Mbit 10ms 10ms"
	./setup-shaping.sh CREATE 10Mbit 5Mbit 10ms 10ms "1"
	msmID=$(uuidgen)
	shortname=$(python3 /home/fries/website-fingerprinting/website-fingerprinting-measurement/get_service_name.py "${uri}")
	echo ${shortname}
	mkdir /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}
	timestamp="`date "+%Y-%m-%d_%H_%M_%S"`"
	

	ip netns exec client-net tcpdump -G 3600 -i any -w /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/client.pcap &
	tcpdumpclientPID=$!
	ip netns exec bottleneck-net tcpdump -G 3600 -i any -w /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/middle.pcap &
	tcpdumpmiddlePID=$!
	ip netns exec server-net tcpdump -G 3600 -i any -w /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/server.pcap &
	tcpdumpserverPID=$!

	ip netns exec server-net nginx -c "/data/website-fingerprinting/webpage-replay/replay/${shortname}.conf" > /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/nginx.log &
	nginxPID=$!
	#socat TCP-LISTEN:6010,fork,reuseaddr,bind=192.168.0.2 TCP:127.0.0.1:6010 2>/dev/null &
	# wait for everything to run; could be cleaner
	sleep 5

	export TMPDIR=/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}
	export TRACE_CSV_DIR=/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/trace.csv
	export SSLKEYLOGFILE=/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/sslkey.log
	export MOZ_LOG=timestamp,sync,nsHttp:5,nsSocketTransport:5,UDPSocket:5,neqo_transport::*:5,neqo_defense::*:5,neqo_glue::*:5
	export MOZ_LOG_FILE=/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/firefox
	ip netns exec client-net python3 /home/fries/website-fingerprinting/website-fingerprinting-measurement/measure-website-firefox.py "${uri}" "${msmID}" "$DEFENSE"
	kill -SIGINT $tcpdumpclientPID
	wait $tcpdumpclientPID
	kill -SIGINT $tcpdumpmiddlePID
	wait $tcpdumpmiddlePID
	kill -SIGINT $tcpdumpserverPID
	wait $tcpdumpserverPID
	kill -SIGTERM $nginxPID
	wait $nginxPID
	./setup-shaping.sh DELETE
}

iterations=$1
#while true; do
for ((i=1; i<=iterations; i++)); do
echo "Iteration $i"
while read uri; do
	echo ${uri}
	run_experiment_for_defense "undefended"
	run_experiment_for_defense "front"
done < websites.txt
done
