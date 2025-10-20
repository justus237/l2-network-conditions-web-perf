#!/bin/bash
#set -ex
if [[ $EUID -ne 0 ]]; then
	echo "$0 is not running as root. Try using sudo."
	exit 2
fi

#undefended -> nothing in both
#front-client -> front in neqo and nothing in quic-go
#front-server -> front-client-only in neqo and front in quic-go
#["front-client-controlled-bidir", "front-client-controlled-unidir", "front-client-and-server-controlled-bidir"] -> uses neqo
#["front-client-and-server-controlled-bidir", "front-server-controlled-unidir"] -> uses quic-go
# unidir for now implies FROM the entity that controls the defense
# TODO: implement disabling connection reuse by using the root cert instead of a cert with SANs

BASE_DIR="/data/website-fingerprinting/packet-captures/"

function run_experiment_for_defense {
	local DEFENSE=$1
	echo $DEFENSE
	msmID=$(uuidgen)
	shortname=$(python3 /home/fries/website-fingerprinting/website-fingerprinting-measurement/get_service_name.py "${uri}")
	echo ${shortname}
	# read /data/website-fingerprinting/webpage-replay/replay/$shortname/servers-and-hostnames.txt
	IFS=';' read -ra SERVERS < /data/website-fingerprinting/webpage-replay/replay/${shortname}/servers-and-hostnames.txt
	mkdir -p ${BASE_DIR}${DEFENSE}/${msmID}-${shortname}
	
	echo "10Mbit 5Mbit 10ms 10ms"
	#setup shaping with number of servers
	# TODO: capture the return code of setup-shaping and if it is not 0, call delete and exit with error
	./setup-shaping.sh CREATE 10Mbit 5Mbit 10ms 10ms "${#SERVERS[@]}"

	#used by both client and quic-go server
	export TRACE_CSV_DIR=${BASE_DIR}${DEFENSE}/${msmID}-${shortname}/

	ip netns exec client-net tcpdump -i any -w ${BASE_DIR}${DEFENSE}/${msmID}-${shortname}/client.pcap 2> /tmp/tcpdump-client.log  &
	tcpdumpclientPID=$!
	ip netns exec bottleneck-net tcpdump -i any -w ${BASE_DIR}${DEFENSE}/${msmID}-${shortname}/middle.pcap 2> /tmp/tcpdump-middle.log &
	tcpdumpmiddlePID=$!
	#tcpdumpserverPIDS=()
	#for (( i=1; i<=${#SERVERS[@]}; i++ )); do
	#	ip netns exec server-net tcpdump -i any -w "${BASE_DIR}$DEFENSE/${msmID}-${shortname}/server-$i.pcap" &
	#	tcpdumpserverPIDS+=($!)
	#done
	# example usage of server: TRACE_CSV_DIR=./ ./h3-replay-server --dir /data/website-fingerprinting/webpage-replay/replay/${shortname} --hostAndPort "${IP_OF_HOST}:443" --multihost --origins "$origins" --frontdefense
	# the ip address of the host is determined by its position in the servers array

	export QUIC_GO_LOG_LEVEL=DEBUG
	for (( i=0; i<${#SERVERS[@]}; i++ )); do
		# see setup-shaping.sh for the IP address calculation
		IP_OF_HOST="10.237.0.$((i + 3))"
		if [[ ${DEFENSE} == "undefended" || ${DEFENSE} == "front-client-controlled-bidir" || ${DEFENSE} == "front-client-controlled-unidir" || ${DEFENSE} == "testing" ]]; then
			# no front defense, so we use the h3-replay-server
			ip netns exec server-net-$((i+1)) ./h3-replay-server --dir "/data/website-fingerprinting/webpage-replay/replay/${shortname}/" --hostAndPort "${IP_OF_HOST}:443" --multihost --origins "${SERVERS[$i]}" --sslKeyLogFile "${BASE_DIR}${DEFENSE}/${msmID}-${shortname}/sslkey-server-$((i+1)).log" >> "${BASE_DIR}${DEFENSE}/${msmID}-${shortname}/server-$((i+1)).log" 2>&1 &
		elif [[ ${DEFENSE} == "front-client-and-server-controlled-bidir" || ${DEFENSE} == "front-server-controlled-unidir" ]]; then
			# front defense, so we use the neqo-bin server
			ip netns exec server-net-$((i+1)) ./h3-replay-server --dir "/data/website-fingerprinting/webpage-replay/replay/${shortname}/" --hostAndPort "${IP_OF_HOST}:443" --multihost --origins "${SERVERS[$i]}" --sslKeyLogFile "${BASE_DIR}${DEFENSE}/${msmID}-${shortname}/sslkey-server-$((i+1)).log" --frontdefense >> "${BASE_DIR}${DEFENSE}/${msmID}-${shortname}/server-$((i+1)).log" 2>&1 &
		fi
		sleep 1
		#ip netns exec server-net ./h3-replay-server --dir /data/website-fingerprinting/webpage-replay/replay/${shortname} --hostAndPort "${IP_OF_HOST}:443" --multihost --origins "${SERVERS[$i]}" --frontdefense
	done

	#ip netns exec server-net nginx -c "/data/website-fingerprinting/webpage-replay/replay/${shortname}.conf" > /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/nginx.log &
	#nginxPID=$!
	#socat TCP-LISTEN:6010,fork,reuseaddr,bind=192.168.0.2 TCP:127.0.0.1:6010 2>/dev/null &
	# wait for everything to run; could be cleaner
	#running HTTP/3 replay server
	sleep 10
	# hopefully enough to get all the servers started, they do have to read the certificates after all

	export TMPDIR=${BASE_DIR}${DEFENSE}/${msmID}-${shortname}
	export SSLKEYLOGFILE=${BASE_DIR}${DEFENSE}/${msmID}-${shortname}/sslkey.log
	export MOZ_LOG=timestamp,sync,nsHttp:5,nsSocketTransport:5,UDPSocket:5,neqo_transport::*:5,neqo_defense::*:5,neqo_glue::*:5,neqo_http3::*:5
	export MOZ_LOG_FILE=${BASE_DIR}${DEFENSE}/${msmID}-${shortname}/firefox
	mkdir ${BASE_DIR}${DEFENSE}/${msmID}-${shortname}/defense-state/
	export DEFENSE_STATE_DIR=${BASE_DIR}${DEFENSE}/${msmID}-${shortname}/defense-state/
	ip netns exec client-net python3 "$PWD/measure-website-firefox.py" "${uri}" "${msmID}" "${DEFENSE}" "${BASE_DIR}"
	#TODO: maybe use exit code of this script as success indicator
	
	kill -SIGINT $tcpdumpclientPID
	wait $tcpdumpclientPID
	kill -SIGINT $tcpdumpmiddlePID
	wait $tcpdumpmiddlePID
	#for tcpdumpserverPID in "${tcpdumpserverPIDS[@]}"; do
	#	kill -SIGINT $tcpdumpserverPID
	#	wait $tcpdumpserverPID
	#done
	#kill -SIGTERM $nginxPID
	#wait $nginxPID
	./setup-shaping.sh DELETE
}

iterations=$1
# if iterations is not a number but instead "testing" we run the experiment only once and call it testing
if [[ $iterations == "testing" ]]; then
	echo "Running ${iterations}"
	while read uri; do
		echo ${uri}
		run_experiment_for_defense "testing"
	done < websites.txt
elif [[ $iterations == "front-client-controlled-bidir" ]]; then
	echo "Running ${iterations}"
	while read uri; do
		echo ${uri}
		run_experiment_for_defense "front-client-controlled-bidir"
	done < websites.txt
elif [[ $iterations == "front-client-and-server-controlled-bidir" ]]; then
	echo "Running ${iterations}"
	while read uri; do
		echo ${uri}
		run_experiment_for_defense "front-client-and-server-controlled-bidir"
	done < websites.txt
elif [[ $iterations == "front-server-controlled-unidir" ]]; then
	echo "Running ${iterations}"
	while read uri; do
		echo ${uri}
		run_experiment_for_defense "front-server-controlled-unidir"
	done < websites.txt
elif [[ $iterations == "front-client-controlled-unidir" ]]; then
	echo "Running ${iterations}"
	while read uri; do
		echo ${uri}
		run_experiment_for_defense "front-client-controlled-unidir"
	done < websites.txt
else
	#not sure what happens if you cannot interpret the iterations variable as a number
	echo "Running $iterations iterations"
	# TODO: somehow introduce a script or check here that can tell how many iterations have already been done and only do the remaining ones
	# this will be specific for each website and each defense...
	# so we will likely have to loop over the websites first and then do the iterations for each website and each defense
	for ((i=1; i<=iterations; i++)); do
	echo "Iteration $i"
		while read uri; do
			echo ${uri}
			run_experiment_for_defense "undefended"
			run_experiment_for_defense "front-client-controlled-bidir"
			run_experiment_for_defense "front-client-controlled-unidir"
			run_experiment_for_defense "front-client-and-server-controlled-bidir"
		done < websites.txt
	done
fi