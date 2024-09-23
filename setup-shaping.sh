#!/bin/bash
#set -ex

#TODO: ensure that MTU is set correctly, that MTU is set correctly and that a local dns resolver exists

# gentoo tutorial (https://wiki.gentoo.org/wiki/Traffic_shaping) also uses modprobe sch_fq_codel

# Topology:
# 
#     |    client-net     |            bottleneck-net            |      NAT       |
#     |                   |             netem + htb              |                |
#     |   -----------     |     -----------------------------    |                |
#     |   |  veth3  | --------- | veth0, veth1, ifb0, ifb1 | --------- veth2 --------- Inet
#     |   -----------     |     -----------------------------    |                |
#



#sudo check
##if we are not root we immediately exit
if [[ $EUID -ne 0 ]]; then
    echo "$0 is not running as root. Try using sudo."
    exit 1
fi

#check ipv4 forwarding
##it is required to be enabled on the root host if we want to access the Internet
if [[ $(sysctl -n net.ipv4.ip_forward) -ne 1 ]]; then
  echo "IPv4 forwarding is disabled. Please enable it with: sudo sysctl -w net.ipv4.ip_forward=1"
  exit 1
fi

#argument parsing
##check number of arguments or print help
##early exit if we just need to print help; some code duplication going on
##because we check way further down below which function to run...
COMMAND=$1
if [[ "${COMMAND}" = "CREATE" ]]; then
  if [ "$#" -ne 6 ]; then
  echo "CREATE usage: $0 CREATE <DL_CAPACITY> <UL_CAPACITY> <DL_DELAY_FROM_INET> <UL_DELAY_TO_INET> <INET_IFACE>"
  echo "Delays need explicit [ms] unit, capacities need explicit [kbit|Mbit] (per second) unit. No space between the number and unit."
  echo "We use NO_SHAPING to indicate that one of the shapings should not be applied."
  echo ""
  exit 7
  fi
elif [[ "${COMMAND}" =~ ^(help|HELP|--help|-h|--h|-help|--HELP|-H|--H|-HELP)$ ]]; then
  #print usage
  echo "Usage help: $0 CREATE <DL_CAPACITY> <UL_CAPACITY> <DL_DELAY_FROM_INET> <UL_DELAY_TO_INET> <INET_IFACE>"
  echo "$0 DESTROY"
  echo "For CREATE: Delays need explicit [ms] unit, capacities need explicit [kbit|Mbit] (per second) unit."
  echo "No space between the number and unit. We use NO_SHAPING to indicate that one of the shapings should not be applied."
  echo ""
  exit 0
fi

#actually parse arguments
readonly DOWNSTREAM_THROUGHPUT=$2
readonly UPSTREAM_THROUGHPUT=$3
readonly DELAY_FROM_INET=$4
readonly DELAY_TO_INET=$5
readonly INET_IFACE=$6
#setup some variables that we will use later on
CLIENT_NS="client-net"
BOTTLENECK_NS="bottleneck-net"
#get our current directory and force the user to cd into the proper directory to make the python calls work
if [[ ! -e setup-shaping.sh ]]; then
  echo >&2 "Please cd into the bundle before running this script."
  exit 1
fi
bundledir=$PWD

function load_kernel_modules {
  #to also shape incoming traffic (RX direction from bottleneck namespace point of view)
  #technically we don't need to activate this if we only have one uplink and one downlink shaping
  #i.e., if we only shape capacity XOR latency in each of the directions
  #loading and unloading modprobes is definitely not free -> TODO
  echo "Activating modprobes for ifb and mirroring."
  modprobe -q ifb numifbs=0
  modprobe act_mirred
}

function create_namespaces {
  echo "Creating namespaces."
  ip netns add "${BOTTLENECK_NS}"
  ip netns add "${CLIENT_NS}"
}

function setup_bottleneck_ns {
  echo "Setting up bottleneck namespace."
  echo "Setting up link between bottleneck and NAT (the host)."
  ip link add veth1 netns "${BOTTLENECK_NS}" type veth peer name veth2
  #veth remains in the host, veth belongs to the bottleneck namespace
  ip link set dev veth2 up
  #according to arch wiki, we definitely need tso off
  #not all might be necessary though...
  ethtool -K veth2 tso off gso off gro off
  ip -netns "${BOTTLENECK_NS}" link set dev veth1 up
  ip netns exec "${BOTTLENECK_NS}" ethtool -K veth1 tso off gso off gro off
}

function setup_client_ns {
  echo "Setting up client namespace."
  echo "Setting up link between client and bottleneck."
  ip link add dev veth3 netns "${CLIENT_NS}" type veth peer name veth0 netns "${BOTTLENECK_NS}"
  ip -netns "${CLIENT_NS}" link set dev veth3 up
  ip -netns "${BOTTLENECK_NS}" link set dev veth0 up
  ip netns exec "${CLIENT_NS}" ethtool -K veth3 tso off gso off gro off
  ip netns exec "${BOTTLENECK_NS}" ethtool -K veth0 tso off gso off gro off
}

function setup_mirrored_ifaces {
  #technically we should do some more checks here, we dont need all mirrors if one of the shapings is set to NO_SHAPING
  echo "Setting up mirrored interface to shape traffic coming from the Internet."
  ip link add dev ifb1 netns "${BOTTLENECK_NS}" type ifb
  ip -netns "${BOTTLENECK_NS}" link set ifb1 up
  ip netns exec "${BOTTLENECK_NS}" ethtool -K ifb1 tso off gso off gro off
  #veth1 ingress is redirected to ifb1
  ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev veth1 handle ffff: ingress
  ip netns exec "${BOTTLENECK_NS}" tc filter add dev veth1 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb1
  echo "Setting up mirrored interfaces to shape traffic coming in from the client"
  ip link add dev ifb0 netns "${BOTTLENECK_NS}" type ifb
  ip -netns "${BOTTLENECK_NS}" link set ifb0 up
  ip netns exec "${BOTTLENECK_NS}" ethtool -K ifb0 tso off gso off gro off
  # create ingress for veth0 and redirect it to ifb0
  ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev veth0 handle ffff: ingress
  ip netns exec "${BOTTLENECK_NS}" tc filter add dev veth0 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0
}

function setup_shaping {
  #feel like this could be simplified somehow..
  #i.e. one thing could be moving the check for no_shaping before the BDP python script (calculate-buffer) into the python script
  #downlink direction
  #both netem and tbf
  #client <- veth0 (netem) <- ifb1 (tbf) <- server
  #no netem
  #client <- veth0 (tbf) <- server
  #no tbf
  #client <- veth0 (netem) <- server

  #uplink direction
  #both netem and tbf
  #client -> ifb0 (tbf) -> veth1 (netem) -> server
  #no netem
  #client -> veth1 (tbf) -> server
  #no tbf
  #client -> veth1 (netem) -> server
  echo "downlink"
  if [[ "${DELAY_FROM_INET}" = "NO_SHAPING" ]]; then
    if [[ "${DOWNSTREAM_THROUGHPUT}" != "NO_SHAPING" ]]; then
      #downlink without netem
      #down_tbf on veth0
      # tbf burst = rate in bps/250/8
      # limit is min(bdp,1500B)
      # Without inner qdisc, TBF queue is simply a bfifo
      downstream_burst=$(python3 "${bundledir}/calculate-burst.py" "${DOWNSTREAM_THROUGHPUT}")
      if [[ "${DELAY_TO_INET}" = "NO_SHAPING" ]]; then
        downstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${DOWNSTREAM_THROUGHPUT}" "1ms" "1ms")
      else
        downstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${UPSTREAM_THROUGHPUT}" "${DELAY_TO_INET}" "1ms")
      fi
      ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev veth0 root tbf rate "${DOWNSTREAM_THROUGHPUT}" burst "${downstream_burst}" limit "${downstream_buffer_limit}"
    fi
  else
    #netem will always be on veth0
    ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev veth0 root netem delay "${DELAY_FROM_INET}" limit 1000000
    if [[ "${DOWNSTREAM_THROUGHPUT}" != "NO_SHAPING" ]]; then
      #downlink with netem, down_tbf on ifb1
      downstream_burst=$(python3 "${bundledir}/calculate-burst.py" "${DOWNSTREAM_THROUGHPUT}")
      if [[ "${DELAY_TO_INET}" = "NO_SHAPING" ]]; then
        downstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${DOWNSTREAM_THROUGHPUT}" "1ms" "${DELAY_FROM_INET}")
      else
        downstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${DOWNSTREAM_THROUGHPUT}" "${DELAY_TO_INET}" "${DELAY_FROM_INET}")
      fi
      ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev ifb1 root tbf rate "${DOWNSTREAM_THROUGHPUT}" burst "${downstream_burst}" limit "${downstream_buffer_limit}"
    fi
  fi
  echo "uplink"
  if [[ "${DELAY_TO_INET}" = "NO_SHAPING" ]]; then
    if [[ "${UPSTREAM_THROUGHPUT}" != "NO_SHAPING" ]]; then
      #uplink without netem
      #up_tbf on veth1
      upstream_burst=$(python3 "${bundledir}/calculate-burst.py" "${UPSTREAM_THROUGHPUT}")
      if [[ "${DELAY_FROM_INET}" = "NO_SHAPING" ]]; then
        upstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${UPSTREAM_THROUGHPUT}" "1ms" "1ms")
      else
        upstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${UPSTREAM_THROUGHPUT}" "1ms" "${DELAY_FROM_INET}")
      fi
      ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev veth1 root tbf rate "${UPSTREAM_THROUGHPUT}" burst "${upstream_burst}" limit "${upstream_buffer_limit}"
    fi
  else
    #netem will always be on veth1
    ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev veth1 root netem delay "${DELAY_TO_INET}" limit 1000000
    if [[ "${UPSTREAM_THROUGHPUT}" != "NO_SHAPING" ]]; then
      #uplinik with netem, up_tbf on ifb0
      upstream_burst=$(python3 "${bundledir}/calculate-burst.py" "${UPSTREAM_THROUGHPUT}")
      if [[ "${DELAY_FROM_INET}" = "NO_SHAPING" ]]; then
        upstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${UPSTREAM_THROUGHPUT}" "${DELAY_TO_INET}" "1ms")
      else
        upstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${UPSTREAM_THROUGHPUT}" "${DELAY_TO_INET}" "${DELAY_FROM_INET}")
      fi
      netns exec "${BOTTLENECK_NS}" tc qdisc add dev ifb0 root tbf rate "${UPSTREAM_THROUGHPUT}" burst "${upstream_burst}" limit "${upstream_buffer_limit}"
    fi
  fi
}

function setup_bottleneck_bridge {
  #set up bridge
  #you could see this as part of the ip address setup, but separate function for now
  ip -netns "${BOTTLENECK_NS}" link add name br-client-inet type bridge
  ip -netns "${BOTTLENECK_NS}" link set br-client-inet up
  ip -netns "${BOTTLENECK_NS}" link set veth1 master br-client-inet
  ip -netns "${BOTTLENECK_NS}" link set veth0 master br-client-inet
}

function setup_ip {
  echo "setting up ip addresses"
  # add ip addresses
  ip address add 192.168.0.2/24 dev veth2
  ip -netns "${CLIENT_NS}" address add 192.168.0.3/24 dev veth3
  # set default route to internet
  ip -netns "${CLIENT_NS}" route add default via 192.168.0.2
  
  # need to set loopback up, Ookla's Speedtest CLI uses it for example
  ip -netns "${CLIENT_NS}" link set dev lo up
  
  ## shut off ipv6 completely
  ip netns exec "${BOTTLENECK_NS}" sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null
  ip netns exec "${BOTTLENECK_NS}" sysctl -w net.ipv6.conf.veth0.disable_ipv6=1 &>/dev/null
  ip netns exec "${BOTTLENECK_NS}" sysctl -w net.ipv6.conf.veth1.disable_ipv6=1 &>/dev/null
  ip netns exec "${CLIENT_NS}" sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null
  ip netns exec "${CLIENT_NS}" sysctl -w net.ipv6.conf.veth3.disable_ipv6=1 &>/dev/null
  sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null
  sysctl -w net.ipv6.conf.veth2.disable_ipv6=1 &>/dev/null
  if [[ "${NEED_MIRRORING}" = true ]]; then
    ip netns exec "${BOTTLENECK_NS}" sysctl -w net.ipv6.conf.ifb0.disable_ipv6=1 &>/dev/null
    ip netns exec "${BOTTLENECK_NS}" sysctl -w net.ipv6.conf.ifb1.disable_ipv6=1 &>/dev/null
  fi
}

function setup_dns {
  #TODO: this assumes that the host is running systemd resolved...
  if [ -d "/etc/netns" ]; then
    if [ -d "/etc/netns/${CLIENT_NS}" ]; then
      if [ -f "/etc/netns/${CLIENT_NS}/resolv.conf" ]; then
      #echo "/etc/netns/${CLIENT_NS}/resolv.conf exists!!"
        echo "nameserver 192.168.0.2" > "/etc/netns/${CLIENT_NS}/resolv.conf"
        else
        touch "/etc/netns/${CLIENT_NS}/resolv.conf"
        echo "nameserver 192.168.0.2" > "/etc/netns/${CLIENT_NS}/resolv.conf"
      fi
    else
      cd /etc/netns
      mkdir "${CLIENT_NS}"
      cd "${CLIENT_NS}"
      touch resolv.conf
      echo "nameserver 192.168.0.2" > resolv.conf
    fi
  else
    cd /etc
    mkdir "netns"
    cd netns
    mkdir "${CLIENT_NS}"
    cd "${CLIENT_NS}"
    touch resolv.conf
    echo "nameserver 192.168.0.2" > resolv.conf
  fi
  #TODO: somehow figure out the DNS situation
  #need to manually append DNSStubListenerExtra=192.168.0.2 to /etc/systemd/resolved.conf
  #to systemd-resolved to also listen on 192.168.0.2
  #however, this feature requires systemd version 247...
  #so for all older ubuntu versions we need to run our own stub resolver...
}

function setup_iptables {
  iptables-save > "${bundledir}/iptables_rules.v4"
  #https://www.gilesthomas.com/2021/03/fun-with-network-namespaces
  #set up NAT for internet access
  iptables -P FORWARD DROP
  iptables -F FORWARD
  iptables -t nat -F
  iptables -t nat -A POSTROUTING -s 192.168.0.3/24 -o "${INET_IFACE}" -j MASQUERADE
  iptables -A FORWARD -i "${INET_IFACE}" -o veth2 -j ACCEPT
  iptables -A FORWARD -o "${INET_IFACE}" -i veth2 -j ACCEPT
}

#for all veth pairs and bridges: create -> set ip addresses/assign veth ends to bridge -> set up

function create {
  #check if interface exists using exit code (but suppress command output)
  if ! ip link show "${INET_IFACE}" &>/dev/null; then
    echo "${INET_IFACE} does not exist."
    exit 22
  fi
  #check if we already set up an experiment and forgot to run destroy
  source "${bundledir}/VARS"
  if [[ "$SETUP_ID" ]]; then
    # TODO enable changing the config when already running?
    echo "already set up an experiment, exiting"
    echo "$SETUP_ID"
    exit 1
  fi
  #global variable used in create but also in setup_ip
  NEED_MIRRORING=true
  #check if we need mirroring
  #basically if at least two are set to no_shaping (one in each direction) we dont need mirroring at all
  if { [[ "${DOWNSTREAM_THROUGHPUT}" == "NO_SHAPING" ]] || [[ "${DELAY_FROM_INET}" == "NO_SHAPING" ]]; } && { [[ "${UPSTREAM_THROUGHPUT}" == "NO_SHAPING" ]] || [[ "${DELAY_TO_INET}" == "NO_SHAPING" ]]; }; then
    NEED_MIRRORING=false
  fi

  if [[ "${NEED_MIRRORING}" = true ]]; then
    load_kernel_modules
  fi
  create_namespaces
  setup_bottleneck_ns

  setup_client_ns
  if [[ "${NEED_MIRRORING}" = true ]]; then
    setup_mirrored_ifaces
  fi

  setup_shaping

  setup_bottleneck_bridge
  
  setup_ip
  
  setup_dns
  
  setup_iptables
  
  echo "sanity ping"
  ip netns exec ${CLIENT_NS} ping -c 3 192.168.0.2
  # write to vars 
  cat << EOF >> "${bundledir}/VARS"
CLIENT_NS="${CLIENT_NS}"
BOTTLENECK_NS="${BOTTLENECK_NS}"
SETUP_ID="${DOWNSTREAM_THROUGHPUT} ${UPSTREAM_THROUGHPUT} ${DELAY_FROM_INET} ${DELAY_TO_INET} ${INET_IFACE}"
NEED_MIRRORING="${NEED_MIRRORING}"
EOF
}

function destroy {
  source "${bundledir}/VARS"
  echo "deleting namespaces"
  # remove all namespaces
  ip netns pids "${CLIENT_NS}" | xargs -r kill
  ip netns del "${CLIENT_NS}" &>/dev/null
  ip netns pids "${BOTTLENECK_NS}" | xargs -r kill
  ip netns del "${BOTTLENECK_NS}" &>/dev/null
  ip link del veth2
  # remove any queuing disciplines outside the namespaces
  # tc qdisc delete dev veth2 root
  cat /dev/null > "${bundledir}/VARS"
  echo "restoring iptables"
  iptables-restore < "${bundledir}/iptables_rules.v4"
  if [[ "${NEED_MIRRORING}" = true ]]; then
    echo "unloading kernel modules ifb and act_mirred"
    modprobe -r ifb
    sleep 5
    modprobe -r act_mirred
  fi
  echo "done"
}

echo "Client will always be in separate network namespace regardless of experiment"
echo "This network namespace is called ${CLIENT_NS}; use \"source ${bundledir}/VARS\" to use in other scripts"

echo "This setup uses one network namespace and bridge between the client and the Internet"

if [[ "${COMMAND}" = "CREATE" ]]; then
  echo "Configuring setup"
  create;
elif [[ "${COMMAND}" = "DELETE" ]]; then
  echo "Destroying setup"
  destroy;
fi

exit 0