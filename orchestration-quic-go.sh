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
DEFAULT_SHAPING="10Mbit 5Mbit 10ms 10ms"
if [[ -f "shapings.txt" ]]; then
	mapfile -t SHAPINGS < "shapings.txt"
fi
if [[ ${#SHAPINGS[@]} -eq 0 ]]; then
	echo "shapings.txt not found or empty — using default: $DEFAULT_SHAPING"
	SHAPINGS=("$DEFAULT_SHAPING")
else
	echo "Loaded ${#SHAPINGS[@]} shaping(s) from shapings.txt:"
	for s in "${SHAPINGS[@]}"; do echo "  $s"; done
fi

function run_experiment_for_defense {
	local DEFENSE=$1
	local SHAPING=$2
	local i
	echo $DEFENSE
	msmID=$(uuidgen)
	shortname=$(python3 /home/fries/website-fingerprinting/website-fingerprinting-measurement/get_service_name.py "${uri}")
	echo ${shortname}
	# read /data/website-fingerprinting/webpage-replay/replay/$shortname/servers-and-hostnames.txt
	IFS=';' read -ra SERVERS < /data/website-fingerprinting/webpage-replay/replay/${shortname}/servers-and-hostnames.txt
	mkdir -p /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}

	READY_FIFO="/tmp/servers_ready_${msmID}-${shortname}"
	if [[ -p $READY_FIFO ]]; then
		echo "${READY_FIFO} already exists, this should not happen"
		rm "$READY_FIFO"
	fi
	mkfifo "$READY_FIFO"
	exec 3<>"$READY_FIFO"
	
	#shaping="10Mbit 5Mbit 10ms 10ms"
	echo "${SHAPING}" > /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/shaping.txt
	#setup shaping with number of servers
	# TODO: capture the return code of setup-shaping and if it is not 0, call delete and exit with error
	./setup-shaping.sh CREATE ${SHAPING} "${#SERVERS[@]}"

	#used by both client and quic-go server
	export TRACE_CSV_DIR=/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/

	ip netns exec client-net tcpdump -i veth0 -w /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/client.pcap 2> /tmp/tcpdump-client.log  &
	tcpdumpclientPID=$!
	ip netns exec bottleneck-net tcpdump -i br-client-inet -w /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/middle.pcap 2> /tmp/tcpdump-middle.log &
	tcpdumpmiddlePID=$!
	#tcpdumpserverPIDS=()
	#for (( i=1; i<=${#SERVERS[@]}; i++ )); do
	#	ip netns exec server-net tcpdump -i any -w "/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/server-$i.pcap" &
	#	tcpdumpserverPIDS+=($!)
	#done
	# example usage of server: TRACE_CSV_DIR=./ ./h3-replay-server --dir /data/website-fingerprinting/webpage-replay/replay/${shortname} --hostAndPort "${IP_OF_HOST}:443" --multihost --origins "$origins" --frontdefense
	# the ip address of the host is determined by its position in the servers array

	mkdir /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/defense-server-state/
	export DEFENSE_SERVER_STATE_DIR=/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/defense-server-state/
	#export QUIC_GO_LOG_LEVEL=DEBUG
	for (( i=0; i<${#SERVERS[@]}; i++ )); do
		# see setup-shaping.sh for the IP address calculation
		IP_OF_HOST="10.237.0.$((i + 3))"
		if [[ ${DEFENSE} == "undefended" || ${DEFENSE} == "front-client-controlled-bidir" || ${DEFENSE} == "front-client-controlled-unidir" || ${DEFENSE} == "testing" ]]; then
			# no front defense, so we use the h3-replay-server
			ip netns exec server-net-$((i+1)) ./h3-replay-server --dir "/data/website-fingerprinting/webpage-replay/replay/${shortname}/" --hostAndPort "${IP_OF_HOST}:443" --multihost --origins "${SERVERS[$i]}" --sslKeyLogFile "/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/sslkey-server-$((i+1)).log" --fifoPipe "$READY_FIFO" >> "/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/server-$((i+1)).log" 2>&1 &
		elif [[ ${DEFENSE} == "front-client-and-server-controlled-bidir" || ${DEFENSE} == "front-server-controlled-unidir" ]]; then
			# front defense, so we use the neqo-bin server
			ip netns exec server-net-$((i+1)) ./h3-replay-server --dir "/data/website-fingerprinting/webpage-replay/replay/${shortname}/" --hostAndPort "${IP_OF_HOST}:443" --multihost --origins "${SERVERS[$i]}" --sslKeyLogFile "/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/sslkey-server-$((i+1)).log" --frontdefenseslidingwindow --fifoPipe "$READY_FIFO" >> "/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/server-$((i+1)).log" 2>&1 &
		elif [[ ${DEFENSE} == "front-qcsd-client-and-server-controlled-bidir" || ${DEFENSE} == "front-server-controlled-unidir" ]]; then
			# front defense, so we use the neqo-bin server
			ip netns exec server-net-$((i+1)) ./h3-replay-server --dir "/data/website-fingerprinting/webpage-replay/replay/${shortname}/" --hostAndPort "${IP_OF_HOST}:443" --multihost --origins "${SERVERS[$i]}" --sslKeyLogFile "/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/sslkey-server-$((i+1)).log" --frontdefense --fifoPipe "$READY_FIFO" >> "/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/server-$((i+1)).log" 2>&1 &
		fi
		#sleep 1
		#ip netns exec server-net ./h3-replay-server --dir /data/website-fingerprinting/webpage-replay/replay/${shortname} --hostAndPort "${IP_OF_HOST}:443" --multihost --origins "${SERVERS[$i]}" --frontdefense
	done

	#ip netns exec server-net nginx -c "/data/website-fingerprinting/webpage-replay/replay/${shortname}.conf" > /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/nginx.log &
	#nginxPID=$!
	#socat TCP-LISTEN:6010,fork,reuseaddr,bind=192.168.0.2 TCP:127.0.0.1:6010 2>/dev/null &
	# wait for everything to run; could be cleaner
	#running HTTP/3 replay server
	#sleep 10
	read -n ${#SERVERS[@]} -u 3
	# hopefully enough to get all the servers started, they do have to read the certificates after all
	exec 3>&- 3<&-
	rm "$READY_FIFO"
	echo "all servers ready"

	export TMPDIR=/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}
	export SSLKEYLOGFILE=/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/sslkey.log
	#export MOZ_LOG=timestamp,sync,nsHttp:5,nsSocketTransport:5,UDPSocket:5,neqo_transport::*:5,neqo_defense::*:5,neqo_glue::*:5,neqo_http3::*:5
	#export MOZ_LOG_FILE=/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/firefox
	mkdir /data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/defense-client-state/
	export DEFENSE_CLIENT_STATE_DIR=/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/defense-client-state/
	ip netns exec client-net python3 "$PWD/measure-website-firefox.py" "${uri}" "${msmID}" "${DEFENSE}"
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
		run_experiment_for_defense "testing" "${DEFAULT_SHAPING}"
	done < websites.txt
elif [[ $iterations == "front-client-controlled-bidir" ]]; then
	echo "Running ${iterations}"
	while read uri; do
		echo ${uri}
		run_experiment_for_defense "front-client-controlled-bidir" "${DEFAULT_SHAPING}"
	done < websites.txt
elif [[ $iterations == "front-client-and-server-controlled-bidir" ]]; then
	echo "Running ${iterations}"
	while read uri; do
		echo ${uri}
		run_experiment_for_defense "front-client-and-server-controlled-bidir" "${DEFAULT_SHAPING}"
	done < websites.txt
elif [[ $iterations == "front-server-controlled-unidir" ]]; then
	echo "Running ${iterations}"
	while read uri; do
		echo ${uri}
		run_experiment_for_defense "front-server-controlled-unidir" "${DEFAULT_SHAPING}"
	done < websites.txt
elif [[ $iterations == "front-client-controlled-unidir" ]]; then
	echo "Running ${iterations}"
	while read uri; do
		echo ${uri}
		run_experiment_for_defense "front-client-controlled-unidir" "${DEFAULT_SHAPING}"
	done < websites.txt
else
	#not sure what happens if you cannot interpret the iterations variable as a number
	echo "Running $iterations iterations"
	for ((i=1; i<=iterations; i++)); do
		#echo "Iteration $i"
		shaping_index=$(( (i - 1) % ${#SHAPINGS[@]} ))
		SHAPING_ITER="${SHAPINGS[$shaping_index]}"
		echo "Iteration $i — using shaping: $SHAPING_ITER"
		while read uri; do
			echo ${uri}
			#run_experiment_for_defense "undefended" "${SHAPING_ITER}"
			#run_experiment_for_defense "front-client-controlled-bidir"
			#run_experiment_for_defense "front-client-controlled-unidir"
			#run_experiment_for_defense "front-client-and-server-controlled-bidir" "${SHAPING_ITER}"
			run_experiment_for_defense "front-qcsd-client-and-server-controlled-bidir" "${SHAPING_ITER}"
		done < websites.txt
	done
fi