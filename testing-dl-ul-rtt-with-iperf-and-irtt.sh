#!/bin/bash
#set -ex
#ec2-metadata --availability-zone
if [[ $EUID -ne 0 ]]; then
	echo "$0 is not running as root. Try using sudo."
	exit 2
fi
## should probably source vars and exit if they are already set
## it's kinda weird that this check exists in the orchestration AND in the actual shaping script -> how to solve? probably would have to make this script detect an exit 1 from the shaping script and call delete in the shaping script...

# Tests every usage of the shaping scripts with irtt (RTT) and iperf3 (UDP at the
# nominal shaped rate, both directions). For each line of dl-ul-rtt-shaping-short.txt
# (which already covers the NO_SHAPING permutations, i.e. the mirroring/no-mirroring
# code paths) it runs:
#   setup-shaping.sh           single server ns | ${MULTI_NS} server ns | NAT mode
#   setup-shaping-wireguard.sh single server ns | ${MULTI_NS} server ns | NAT mode
# Server-namespace tests self-host iperf3/irtt inside the server namespace(s);
# NAT-mode tests self-host them on the host and target the host's own address on
# INET_IFACE (the client still crosses the shaped bottleneck to reach it). NAT-mode
# tests are skipped if the interface does not exist.
#
# usage: $0 [INET_IFACE]
INET_IFACE=${1:-ens5}
IRTT=/home/ubuntu/go/bin/irtt
MULTI_NS=2

# iperf3 sends UDP at the nominal capacity of the shaping under test
# 10Mbit -> 10M, 576kbit -> 576K; NO_SHAPING -> just send plenty
function iperf_rate {
	if [[ $1 == "NO_SHAPING" ]]; then
		echo "100M"
	else
		echo "${1%bit}"
	fi
}

SERVER_PIDS=()
function start_servers {
	for ns in "$@"; do
		ip netns exec "${ns}" iperf3 -s &> /dev/null &
		SERVER_PIDS+=($!)
		ip netns exec "${ns}" "${IRTT}" server &> /dev/null &
		SERVER_PIDS+=($!)
	done
	# give them a moment to bind
	sleep 1
}

function stop_servers {
	# the shaping DELETE would kill them with the namespaces anyway, but killing them
	# here keeps the job control output out of the teardown
	for pid in "${SERVER_PIDS[@]}"; do
		kill "${pid}" &> /dev/null
	done
	wait "${SERVER_PIDS[@]}" &> /dev/null
	SERVER_PIDS=()
}

function run_tests {
	local target=$1
	echo "ping (irtt) against ${target}"
	#quoting the arguments somewhat ensures that potential spaces in the arguments don't split up the argument list
	ip netns exec client-net "${IRTT}" client -4 -q -d 10s "${target}"
	echo "download"
	ip netns exec client-net iperf3 -c "${target}" -R -u -b "${DL_RATE}"
	echo "upload"
	ip netns exec client-net iperf3 -c "${target}" -u -b "${UL_RATE}"
}

echo "shaping rtts"
while read shaping_string; do
	[[ -z ${shaping_string} || ${shaping_string:0:1} == "#" ]] && continue
	echo "===== ${shaping_string} ====="
	read -ra shaping_arr <<< "${shaping_string}"
	DL_RATE=$(iperf_rate "${shaping_arr[0]}")
	UL_RATE=$(iperf_rate "${shaping_arr[1]}")

	for setup_script in ./setup-shaping.sh ./setup-shaping-wireguard.sh; do
		echo "--- ${setup_script}: single server namespace ---"
		"${setup_script}" CREATE ${shaping_string}
		start_servers server-net
		run_tests 10.237.0.3
		stop_servers
		"${setup_script}" DELETE

		# NOTE: in setup-shaping.sh multi-server shaping is known to be only partially
		# correct (see the comment in its setup_shaping); this test makes that visible.
		# The wireguard variant always shapes the single link to the gateway instead.
		echo "--- ${setup_script}: ${MULTI_NS} server namespaces ---"
		"${setup_script}" CREATE ${shaping_string} "${MULTI_NS}"
		server_ns_list=()
		for (( i=1; i<=MULTI_NS; i++ )); do
			server_ns_list+=("server-net-${i}")
		done
		start_servers "${server_ns_list[@]}"
		for (( i=0; i<MULTI_NS; i++ )); do
			run_tests "10.237.0.$((i + 3))"
		done
		stop_servers
		"${setup_script}" DELETE

		HOST_IP=$(ip -4 -o addr show "${INET_IFACE}" 2> /dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
		if [[ -n ${HOST_IP} ]]; then
			echo "--- ${setup_script}: NAT mode via ${INET_IFACE} against the host (${HOST_IP}) ---"
			"${setup_script}" CREATE ${shaping_string} "${INET_IFACE}"
			# the servers run on the host itself, no namespace needed
			iperf3 -s &> /dev/null &
			SERVER_PIDS+=($!)
			"${IRTT}" server &> /dev/null &
			SERVER_PIDS+=($!)
			sleep 1
			run_tests "${HOST_IP}"
			stop_servers
			"${setup_script}" DELETE
		else
			echo "--- ${setup_script}: skipping NAT mode, ${INET_IFACE} does not exist or has no IPv4 address ---"
		fi
	done
done < dl-ul-rtt-shaping-short.txt
