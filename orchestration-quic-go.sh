#!/bin/bash
#set -ex
if [[ $EUID -ne 0 ]]; then
	echo "$0 is not running as root. Try using sudo."
	exit 2
fi

bundledir=$PWD

## in general: arguments that are strings are passed using environment variables, floats are kept as int for as long as possible;

# The FRONT defense family base name is front-client-and-server-controlled-bidir
# (client+server-controlled, bidirectional); "undefended" is the no-defense base. The
# older front-client-*/front-server-* names are kept only for the named dispatch
# branches below (neqo/client-side combos); "unidir" implies FROM the entity that
# controls the defense.
#
# Each experiment is identified by a LABEL (= results directory) = base name plus zero
# or more suffixes; run_experiment_for_defense decodes the suffixes into orthogonal
# axes (verified in scratchpad/test_decode.sh):
#   -qcsd          -> cumulative-counter FRONT (server --frontdefense, FF mode 1).
#                     Inherently first-connection-only, so it implies -first-conn.
#                     Without it: sliding-window FRONT (--frontdefenseslidingwindow,
#                     FF mode 2).
#   -first-conn    -> defend only the first QUIC connection (server FRONT_DEFENSE_CLAIM_FILE
#                     + client single_per_run pref). Implied by -qcsd.
#   -single-conn   -> one server for ALL origins on 10.237.0.3 with a single all-SAN
#                     cert (all-origins_{cert,key}.pem, from webpage-replay), so the
#                     browser coalesces every origin onto shared connections. Without
#                     it, one server per captured server on 10.237.0.{i+3}.
#   -exit-on-load  -> quit right after page load (measure script does not wait for the
#                     defense to finish). Without it, wait for the defense to finish.
#   -moz           -> drive the distro/.deb Firefox instead of my build.
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

# the measurement plan: experiment labels run each iteration. Comment out any you
# don't want to run.
EXPERIMENTS=(
	"front-client-and-server-controlled-bidir-qcsd"
	"front-client-and-server-controlled-bidir"
	"front-client-and-server-controlled-bidir-first-conn"
	"front-client-and-server-controlled-bidir-single-conn"
	"front-client-and-server-controlled-bidir-exit-on-load"
	"front-client-and-server-controlled-bidir-qcsd-exit-on-load"
	"undefended"
	"undefended-moz"
)

function run_experiment_for_defense {
	local EXPERIMENT=$1
	local SHAPING=$2
	local s_i
	#echo $EXPERIMENT

	# decode the experiment label into the orthogonal axes (substring-based, so suffix
	# order does not matter; see scratchpad/test_decode.sh)
	local COUNTER=sliding;    [[ $EXPERIMENT == *-qcsd*         ]] && COUNTER=qcsd
	local CONN_MODE=multi;    [[ $EXPERIMENT == *-single-conn*  ]] && CONN_MODE=single
	local EXIT_ON_LOAD=false; [[ $EXPERIMENT == *-exit-on-load* ]] && EXIT_ON_LOAD=true
	local FF_BUILD=mine;      [[ $EXPERIMENT == *-moz*          ]] && FF_BUILD=moz
	# qcsd (cumulative counter) is inherently a first-connection-only defense, so it
	# implies first-conn; the sliding window can also be restricted via -first-conn.
	local FIRST_CONN=false
	{ [[ $COUNTER == qcsd ]] || [[ $EXPERIMENT == *-first-conn* ]]; } && FIRST_CONN=true
	# base defense family (drives the server flag + Firefox pref) = label minus the
	# known suffixes (robust to any order/count)
	local DEFENSE=$EXPERIMENT changed=1
	while [[ $changed == 1 ]]; do
		changed=0
		for s in -qcsd -first-conn -single-conn -exit-on-load -moz; do
			if [[ $DEFENSE == *"$s" ]]; then DEFENSE=${DEFENSE%"$s"}; changed=1; fi
		done
	done

	msmID=$(uuidgen)
	shortname=$(python3 "${bundledir}/get_service_name.py" "${uri}")
	echo ${shortname}
	# read /data/website-fingerprinting/webpage-replay/replay/$shortname/servers-and-hostnames.txt
	# servers are separated by ';', origins within a server by ','
	IFS=';' read -ra SERVERS < /data/website-fingerprinting/webpage-replay/replay/${shortname}/servers-and-hostnames.txt

	# results go under the experiment label so variants never share a directory
	local RESULT_DIR="/data/website-fingerprinting/packet-captures/${EXPERIMENT}/${msmID}-${shortname}"
	mkdir -p "${RESULT_DIR}"

	READY_FIFO="/tmp/servers_ready_${msmID}-${shortname}"
	if [[ -p $READY_FIFO ]]; then
		echo "${READY_FIFO} already exists, this should not happen"
		rm "$READY_FIFO"
	fi
	mkfifo "$READY_FIFO"
	exec 3<>"$READY_FIFO"

	#shaping="10Mbit 5Mbit 10ms 10ms"
	echo "${SHAPING}" > "${RESULT_DIR}/shaping.txt"
	# one server namespace per captured server, or a single shared one in single mode
	local NUM_NS=${#SERVERS[@]}
	[[ $CONN_MODE == single ]] && NUM_NS=1
	# TODO: capture the return code of setup-shaping and if it is not 0, call delete and exit with error
	./setup-shaping.sh CREATE ${SHAPING} "${NUM_NS}"

	#used by both client and quic-go server
	export TRACE_CSV_DIR="${RESULT_DIR}/"

	#ip netns exec client-net tcpdump -i veth0 -w "${RESULT_DIR}/client.pcap" 2> /tmp/tcpdump-client.log  &
	#tcpdumpclientPID=$!
	ip netns exec bottleneck-net tcpdump -i br-client-inet -w "${RESULT_DIR}/middle.pcap" 2> /tmp/tcpdump-middle.log &
	tcpdumpmiddlePID=$!

	mkdir "${RESULT_DIR}/defense-server-state/"
	export DEFENSE_SERVER_STATE_DIR="${RESULT_DIR}/defense-server-state/"
	# first-connection-only: the server claims the defense on the first QUIC connection
	# across all server processes via this file. Unset it otherwise so a previous
	# experiment in this run does not leak the setting (and so every connection defends).
	# The path lives in the unique RESULT_DIR, so it is fresh per measurement.
	if [[ $FIRST_CONN == true ]]; then
		export FRONT_DEFENSE_CLAIM_FILE="${RESULT_DIR}/front-defense.claim"
	else
		unset FRONT_DEFENSE_CLAIM_FILE
	fi

	# the server defense flag is the same for every server, so compute it once
	local DEFENSE_FLAG=""
	if [[ ${DEFENSE} == "front-client-and-server-controlled-bidir" || ${DEFENSE} == "front-server-controlled-unidir" ]]; then
		# cumulative counter (qcsd) vs sliding window
		if [[ $COUNTER == qcsd ]]; then
			DEFENSE_FLAG="--frontdefense"
		else
			DEFENSE_FLAG="--frontdefenseslidingwindow"
		fi
	fi
	# undefended / front-client-controlled-* / testing -> no quic-go front defense

	#export QUIC_GO_LOG_LEVEL=DEBUG
	local EXPECTED_READY
	if [[ $CONN_MODE == single ]]; then
		# one server serves every origin from a single IP using one certificate that
		# carries all origins as SANs (all-origins_{cert,key}.pem, from webpage-replay).
		# Passing --cert/--key makes multihost mode use that single cert for every
		# origin, so the browser coalesces the origins onto shared connections. Routing
		# is still by Host header via --multihost + --origins.
		local ALL_ORIGINS
		ALL_ORIGINS=$(IFS=,; echo "${SERVERS[*]}")
		ip netns exec server-net-1 ./h3-replay-server \
			--dir "/data/website-fingerprinting/webpage-replay/replay/${shortname}/" \
			--hostAndPort "10.237.0.3:443" \
			--multihost \
			--origins "${ALL_ORIGINS}" \
			--cert "/data/website-fingerprinting/webpage-replay/replay/${shortname}/all-origins_cert.pem" \
			--key "/data/website-fingerprinting/webpage-replay/replay/${shortname}/all-origins_key.pem" \
			--sslKeyLogFile "${RESULT_DIR}/sslkey-server.log" \
			${DEFENSE_FLAG} \
			--fifoPipe "$READY_FIFO" \
			>> "${RESULT_DIR}/server.log" 2>&1 &
		EXPECTED_READY=1
	else
		# one server per captured server, each on its own IP, loading the per-origin
		# certs from the replay dir (multihost mode with empty --cert/--key)
		for (( s_i=0; s_i<${#SERVERS[@]}; s_i++ )); do
			# see setup-shaping.sh for the IP address calculation
			IP_OF_HOST="10.237.0.$((s_i + 3))"
			ip netns exec server-net-$((s_i+1)) ./h3-replay-server \
				--dir "/data/website-fingerprinting/webpage-replay/replay/${shortname}/" \
				--hostAndPort "${IP_OF_HOST}:443" \
				--multihost \
				--origins "${SERVERS[$s_i]}" \
				--sslKeyLogFile "${RESULT_DIR}/sslkey-server-$((s_i+1)).log" \
				${DEFENSE_FLAG} \
				--fifoPipe "$READY_FIFO" \
				>> "${RESULT_DIR}/server-$((s_i+1)).log" 2>&1 &
		done
		EXPECTED_READY=${#SERVERS[@]}
	fi

	# wait for every server to signal readiness (they have to read the certificates first)
	read -n ${EXPECTED_READY} -u 3
	exec 3>&- 3<&-
	rm "$READY_FIFO"
	echo "all servers ready"

	export TMPDIR="${RESULT_DIR}"
	export SSLKEYLOGFILE="${RESULT_DIR}/sslkey.log"
	#export MOZ_LOG=timestamp,sync,nsHttp:5,nsSocketTransport:5,UDPSocket:5,neqo_transport::*:5,neqo_defense::*:5,neqo_glue::*:5,neqo_http3::*:5
	#export MOZ_LOG_FILE=${RESULT_DIR}/firefox
	mkdir "${RESULT_DIR}/defense-client-state/"
	export DEFENSE_CLIENT_STATE_DIR="${RESULT_DIR}/defense-client-state/"
	# in single mode every hostname must resolve to the one server; pass its IP so the
	# measure script overrides all DNS to it (empty in multi mode -> per-server IPs).
	# args: page msmID defense experiment-label single-server-ip exit-on-load ff-build first-conn
	ip netns exec client-net python3 "$PWD/measure-website-firefox.py" "${uri}" "${msmID}" "${EXPERIMENT}" "${COUNTER}" "${CONN_MODE}" "${EXIT_ON_LOAD}" "${FF_BUILD}" "${FIRST_CONN}"
	#TODO: maybe use exit code of this script as success indicator

	#kill -SIGINT $tcpdumpclientPID
	#wait $tcpdumpclientPID
	kill -SIGINT $tcpdumpmiddlePID
	wait $tcpdumpmiddlePID
	# DELETE tears down the server namespaces, which also kills the server processes
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
	#for exp in "${EXPERIMENTS[@]}"; do
	#not sure what happens if you cannot interpret the iterations variable as a number
	echo "Running $iterations iterations"
	for ((i=1; i<=iterations; i++)); do
		#echo "Iteration $i"
		shaping_index=$(( (i - 1) % ${#SHAPINGS[@]} ))
		SHAPING_ITER="${SHAPINGS[$shaping_index]}"
		echo "Iteration $i — using shaping: $SHAPING_ITER"
		while read uri; do
			echo ${uri}
			for exp in "${EXPERIMENTS[@]}"; do
				# run every experiment in the plan for this website/iteration
				run_experiment_for_defense "$exp" "${SHAPING_ITER}"
			done
		done < websites.txt
	done
	#done
fi
