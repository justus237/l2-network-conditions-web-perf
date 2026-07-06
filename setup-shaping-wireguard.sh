#!/bin/bash
#set -e
# in functions you should "|| exit 1" after commands to fail early

# WireGuard variant of setup-shaping.sh: same client, bottleneck and
# server namespaces with the same 10.237.0.x service addresses, but the client
# reaches everything through ONE WireGuard tunnel whose encrypted UDP crosses the
# shaped bottleneck -- like a consumer VPN, all connections to all servers are
# coalesced into a single tunnel flow, the tunnel overhead consumes bottleneck
# capacity, and the bridge capture (middle.pcap) shows exactly what an on-path
# adversary between client and VPN endpoint sees.

# Topology (server mode):
#
#     |    client-net     |         bottleneck-net          |         gateway-net           |  server-net-{1..n}   |
#     |                   |          netem + tbf            |   VPN termination + NAT       |                      |
#     |   -----------     |   -------------------------     |   ------------------------    |                      |
#     |   |  veth0  | -------- | veth0, ifb0, ifb1, veth1 |----- veth1;  br-servers  | -- veth-s{1..n} -- veth1 in each ns
#     |   -----------     |   -------------------------     |   ------------------------    |                      |
#       underlay 10.0.0.2      (carries the one encrypted        underlay 10.0.0.3                10.237.0.{3..n+2}
#                                    WireGuard flow)              br-servers 10.237.0.2
#       wg0 10.100.0.2 ============== WireGuard tunnel =========== wg-host 10.100.0.1
#
# NAT mode replaces gateway-net with the host itself (wg-host on the host,
# MASQUERADE towards INET_IFACE).
#
# The gateway MASQUERADEs the decrypted traffic onto br-servers, so the servers
# still see connections from 10.237.0.2 and keep their 10.237.0.{i+3} addresses --
# server binds, DNS overrides and the orchestration stay unchanged; only the client
# now talks from its tunnel address 10.100.0.2. The veth underlay across the
# bottleneck is 10.0.0.0/24. Note the wg interfaces default to MTU 1420.
#
# Because there is only ever ONE link on the far side of the bottleneck (to the
# gateway), the multi-server shaping/mirroring special cases of setup-shaping.sh do
# not exist here: shaping always sits on veth0/veth1/ifb0/ifb1.


#sudo check
##if we are not root we immediately exit
if [[ $EUID -ne 0 ]]; then
    echo "$0 is not running as root. Try using sudo."
    exit 1
fi

if ! command -v wg &>/dev/null; then
    echo "wireguard (wg) is not installed"
    exit 1
fi


#argument parsing
##check number of arguments or print help
##early exit if we just need to print help; some code duplication going on
##because we check way further down below which function to run...
COMMAND=$1
if [[ "${COMMAND}" = "CREATE" ]]; then
  if [ "$#" -ne 6 ] && [ "$#" -ne 5 ]; then
  echo "Invalid number of arguments for CREATE command $#."
  echo "CREATE usage: $0 CREATE <DL_CAPACITY> <UL_CAPACITY> <DL_DELAY_FROM_INET> <UL_DELAY_TO_INET> optional(<INET_IFACE>)"
  echo "Delays need explicit [ms] unit, capacities need explicit [kbit|Mbit] (per second) unit. No space between the number and unit."
  echo "Use NO_SHAPING to indicate that one of the shapings should not be applied."
  echo "If an interface name is provided, then we are in NAT mode and traffic will be routed to the Internet."
  echo "If no interface name is provided, a server network namespace will be created instead."
  echo "You can optionally provide an integer >=1 as the 5th argument to create a number of server namespaces."
  echo ""
  exit 7
  fi
elif [[ "${COMMAND}" =~ ^(help|HELP|--help|-h|--h|-help|--HELP|-H|--H|-HELP)$ ]]; then
  #print usage
  echo "Usage help: $0 CREATE <DL_CAPACITY> <UL_CAPACITY> <DL_DELAY_FROM_INET> <UL_DELAY_TO_INET> <INET_IFACE>"
  echo "$0 DELETE"
  echo "For CREATE: Delays need explicit [ms] unit, capacities need explicit [kbit|Mbit] (per second) unit."
  echo "No space between the number and unit. We use NO_SHAPING to indicate that one of the shapings should not be applied."
  echo "The interface name indicates whether the script should run in NAT mode with Internet connectivity or create >= 1 server network namespaces."
  echo ""
  exit 0
fi

#actually parse arguments
readonly DOWNSTREAM_THROUGHPUT=$2
readonly UPSTREAM_THROUGHPUT=$3
readonly DELAY_FROM_INET=$4
readonly DELAY_TO_INET=$5
readonly INET_IFACE=$6


### length 0 means INET_IFACE is an ethernet interface and we don't create a server namespace (we exit if the variable INET_IFACE is not a number and also not an interface)
### length 1 means INET_IFACE does not exist, is set to the empty string, or was set to "1" and we create a single server namespace
### any length > 1 declares how many server namespaces exist
SERVER_NS=()

#TODO: move this namespace naming and creating stuff down to the setup function without breaking anything
#maybe this should be -v INET_IFACE
if [[ -z "$INET_IFACE" ]]; then
  echo "INET_IFACE is not set, creating a single server namespace."
  SERVER_NS+=("server-net")
elif ip link show "${INET_IFACE}" &>/dev/null; then
  echo "${INET_IFACE} exists, script is in NAT mode."
  #check ipv4 forwarding
  #it is required to be enabled on the root host if we want to access the Internet
  if [[ $(sysctl -n net.ipv4.ip_forward) -ne 1 ]]; then
    echo "IPv4 forwarding is disabled. Enabling it!"
    sysctl -w net.ipv4.ip_forward=1
  fi
# check if it's a number
elif [[ "$INET_IFACE" =~ ^[0-9]+$ && "$INET_IFACE" -ge 1 ]]; then
  echo "Creating ${INET_IFACE} server namespaces."
  # we create a number of server namespaces
  NOF_SERVER_NAMESPACES=$INET_IFACE
  # SERVER_NS will be an array of server namespaces
  for (( i=1; i<=$NOF_SERVER_NAMESPACES; i++ )); do
    SERVER_NS+=("server-net-$i")
  done
else
  echo "invalid argument: ${INET_IFACE}"
  exit 0
fi



#setup some variables that we will use later on
CLIENT_NS="client-net"
BOTTLENECK_NS="bottleneck-net"
# the VPN endpoint; only exists in server mode (NAT mode terminates on the host)
GATEWAY_NS="gateway-net"
#get our current directory and force the user to cd into the proper directory to make the python calls work
if [[ ! -e setup-shaping-wireguard.sh ]]; then
  echo >&2 "Please cd into the bundle before running this script."
  exit 1
fi
bundledir=$PWD

# Keys reused verbatim from 2025-sandro-pischinger-bt-material/setup-shaping.sh.
# There is exactly one tunnel, so one pair per side suffices; fixed keys keep the
# throwaway testbed tunnel reproducible.
WG_HOST_PRIVKEY="mM3tBoDPQmdyBqwrKCdsD30/X+B4sK12UOFRn61Fd0Q="
WG_HOST_PUBKEY="DmXKOOwCFwsx5sfoRo456IeAPukrcH8Nos39LwgID2Y="
WG_CLIENT_PRIVKEY="GHRaT0wsDb2CAoAAZC5v7di7n/UCmgi2sSeizodCC1M="
WG_CLIENT_PUBKEY="dYwcTiyTVg2aKkuFNkYBIjbc83ozeOE7zPJmr6neczU="

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
  # the gateway and server namespaces only exist in server mode
  if [[ "${#SERVER_NS[@]}" -ne 0 ]]; then
    ip netns add "${GATEWAY_NS}"
  fi
  for server_ns in "${SERVER_NS[@]}"; do
    ip netns add "${server_ns}"
  done
}

function setup_bottleneck_ns {
  echo "Setting up bottleneck namespace."
  echo "Setting up link between bottleneck and the VPN endpoint (host in NAT mode, gateway namespace otherwise)."
  # unlike setup-shaping.sh there is always exactly ONE far-side veth pair, because
  # everything behind the bottleneck is reached through the single tunnel
  if [[ "${#SERVER_NS[@]}" -eq 0 ]]; then
    #if you directly place a veth peer in another netns then you can give them the same name, thanks benedikt
    ip link add veth1 netns "${BOTTLENECK_NS}" type veth peer name veth1
    ip link set dev veth1 up
    ip link set dev veth1 gso_max_segs 1
    ethtool -K veth1 tso off gso off gro off
    ethtool --offload veth1 rx off tx off
  else
    ip link add veth1 netns "${BOTTLENECK_NS}" type veth peer name veth1 netns "${GATEWAY_NS}"
    ip -netns "${GATEWAY_NS}" link set dev veth1 up
    ip -netns "${GATEWAY_NS}" link set dev veth1 gso_max_segs 1
    ip netns exec "${GATEWAY_NS}" ethtool -K veth1 tso off gso off gro off
    ip netns exec "${GATEWAY_NS}" ethtool --offload veth1 rx off tx off
  fi
  ip -netns "${BOTTLENECK_NS}" link set dev veth1 up
  ip -netns "${BOTTLENECK_NS}" link set dev veth1 gso_max_segs 1
  ip netns exec "${BOTTLENECK_NS}" ethtool -K veth1 tso off gso off gro off
  ip netns exec "${BOTTLENECK_NS}" ethtool --offload veth1 rx off tx off
}

function setup_client_ns {
  echo "Setting up client namespace."
  echo "Setting up link between client and bottleneck."
  ip link add dev veth0 netns "${CLIENT_NS}" type veth peer name veth0 netns "${BOTTLENECK_NS}"
  ip -netns "${CLIENT_NS}" link set dev veth0 up
  ip -netns "${CLIENT_NS}" link set dev veth0 gso_max_segs 1
  ip -netns "${BOTTLENECK_NS}" link set dev veth0 up
  ip -netns "${BOTTLENECK_NS}" link set dev veth0 gso_max_segs 1
  ip netns exec "${CLIENT_NS}" ethtool -K veth0 tso off gso off gro off
  ip netns exec "${CLIENT_NS}" ethtool --offload veth0 rx off tx off
  ip netns exec "${BOTTLENECK_NS}" ethtool -K veth0 tso off gso off gro off
  ip netns exec "${BOTTLENECK_NS}" ethtool --offload veth0 rx off tx off
}

function setup_gateway_ns {
  echo "Setting up VPN gateway namespace and its server-side network."
  # a second bridge on the plaintext side of the gateway; all servers hang off it
  # exactly like they hung off the bottleneck bridge in setup-shaping.sh
  ip -netns "${GATEWAY_NS}" link add name br-servers type bridge
  ip -netns "${GATEWAY_NS}" link set br-servers up
  for (( i=0; i<${#SERVER_NS[@]}; i++ )); do
    server_ns="${SERVER_NS[$i]}"
    ip link add "veth-s$((i + 1))" netns "${GATEWAY_NS}" type veth peer name veth1 netns "${server_ns}"
    ip -netns "${GATEWAY_NS}" link set dev "veth-s$((i + 1))" up
    ip -netns "${GATEWAY_NS}" link set dev "veth-s$((i + 1))" master br-servers
    ip -netns "${server_ns}" link set dev veth1 up
    # keep per-packet fidelity on the way into/out of the tunnel
    ip netns exec "${GATEWAY_NS}" ethtool -K "veth-s$((i + 1))" tso off gso off gro off
    ip netns exec "${server_ns}" ethtool -K veth1 tso off gso off gro off
    # the servers keep their usual addresses, so h3-replay-server's --hostAndPort
    # binds and the measure script's DNS overrides are unchanged
    ip -netns "${server_ns}" address add "10.237.0.$((i + 3))/24" dev veth1
  done
  # the gateway takes the client's old address on the server-side bridge: after the
  # MASQUERADE the servers still see connections from 10.237.0.2 like in setup-shaping.sh
  ip -netns "${GATEWAY_NS}" address add 10.237.0.2/24 dev br-servers
}

function setup_mirrored_ifaces {
  #technically we should do some more checks here, we dont need all mirrors if one of the shapings is set to NO_SHAPING
  echo "Setting up mirrored interface to shape traffic coming from the VPN endpoint."
  ip link add dev ifb1 netns "${BOTTLENECK_NS}" type ifb
  ip -netns "${BOTTLENECK_NS}" link set ifb1 up
  ip -netns "${BOTTLENECK_NS}" link set dev ifb1 gso_max_segs 1
  ip netns exec "${BOTTLENECK_NS}" ethtool -K ifb1 tso off gso off gro off
  ip netns exec "${BOTTLENECK_NS}" ethtool --offload ifb1 tx off
  #veth1 ingress is redirected to ifb1
  ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev veth1 handle ffff: ingress
  ip netns exec "${BOTTLENECK_NS}" tc filter add dev veth1 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb1

  echo "Setting up mirrored interfaces to shape traffic coming in from the client"
  ip link add dev ifb0 netns "${BOTTLENECK_NS}" type ifb
  ip -netns "${BOTTLENECK_NS}" link set ifb0 up
  ip -netns "${BOTTLENECK_NS}" link set dev ifb0 gso_max_segs 1
  ip netns exec "${BOTTLENECK_NS}" ethtool -K ifb0 tso off gso off gro off
  ip netns exec "${BOTTLENECK_NS}" ethtool --offload ifb0 tx off
  # create ingress for veth0 and redirect it to ifb0
  ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev veth0 handle ffff: ingress
  ip netns exec "${BOTTLENECK_NS}" tc filter add dev veth0 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0
}

function setup_shaping {
  #feel like this could be simplified somehow..
  #i.e. one thing could be moving the check for no_shaping before the BDP python script (calculate-buffer) into the python script
  #downlink direction
  #both netem and tbf
  #client <- veth0 (netem) <- ifb1 (tbf) <- VPN endpoint
  #no netem -- doesnt use ifb
  #client <- veth0 (tbf) <- VPN endpoint
  #no tbf -- doesnt use ifb
  #client <- veth0 (netem) <- VPN endpoint

  #uplink direction
  #both netem and tbf
  #client -> ifb0 (tbf) -> veth1 (netem) -> VPN endpoint
  #no netem -- doesnt use ifb
  #client -> veth1 (tbf) -> VPN endpoint
  #no tbf -- doesnt use ifb
  #client -> veth1 (netem) -> VPN endpoint
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
      # downlink with netem, down_tbf on ifb1
      # do buffer calculations
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
      # uplink without netem, up_tbf on veth1
      # do buffer calculations
      upstream_burst=$(python3 "${bundledir}/calculate-burst.py" "${UPSTREAM_THROUGHPUT}")
      if [[ "${DELAY_FROM_INET}" = "NO_SHAPING" ]]; then
        upstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${UPSTREAM_THROUGHPUT}" "1ms" "1ms")
      else
        upstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${UPSTREAM_THROUGHPUT}" "1ms" "${DELAY_FROM_INET}")
      fi
      ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev veth1 root tbf rate "${UPSTREAM_THROUGHPUT}" burst "${upstream_burst}" limit "${upstream_buffer_limit}"
    fi
  else
    # netem will always be on veth1
    ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev veth1 root netem delay "${DELAY_TO_INET}" limit 1000000
    if [[ "${UPSTREAM_THROUGHPUT}" != "NO_SHAPING" ]]; then
      #uplink with netem, up_tbf on ifb0
      upstream_burst=$(python3 "${bundledir}/calculate-burst.py" "${UPSTREAM_THROUGHPUT}")
      if [[ "${DELAY_FROM_INET}" = "NO_SHAPING" ]]; then
        upstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${UPSTREAM_THROUGHPUT}" "${DELAY_TO_INET}" "1ms")
      else
        upstream_buffer_limit=$(python3 "${bundledir}/calculate-buffer.py" "${UPSTREAM_THROUGHPUT}" "${DELAY_TO_INET}" "${DELAY_FROM_INET}")
      fi
      ip netns exec "${BOTTLENECK_NS}" tc qdisc add dev ifb0 root tbf rate "${UPSTREAM_THROUGHPUT}" burst "${upstream_burst}" limit "${upstream_buffer_limit}"
    fi
  fi
}

function setup_bottleneck_bridge {
  #set up bridge
  #you could see this as part of the ip address setup, but separate function for now
  ip -netns "${BOTTLENECK_NS}" link add name br-client-inet type bridge
  ip -netns "${BOTTLENECK_NS}" link set br-client-inet up
  ip -netns "${BOTTLENECK_NS}" link set veth0 master br-client-inet
  ip -netns "${BOTTLENECK_NS}" link set veth1 master br-client-inet
}

function setup_ip {
  echo "setting up ipv4 addresses and disabling ipv6"
  # add ip addresses
  # the veths across the bottleneck only carry the encrypted tunnel UDP, so they
  # form the 10.0.0.0/24 underlay; the 10.237.0.x server network lives behind the
  # gateway (setup_gateway_ns) and the tunnel addresses are set in setup_wireguard

  if [[ "${#SERVER_NS[@]}" -eq 0 ]]; then
    ip address add 10.0.0.3/24 dev veth1
  else
    ip -netns "${GATEWAY_NS}" address add 10.0.0.3/24 dev veth1
  fi
  ip -netns "${CLIENT_NS}" address add 10.0.0.2/24 dev veth0

  # no default route via the underlay: the client's default route goes through the
  # tunnel and is added in setup_wireguard

  # need to set loopback up, Ookla's Speedtest CLI uses it for example
  ip -netns "${CLIENT_NS}" link set dev lo up

  #probably set MTU of host link but should probably also save the original value
  #ip link set dev "${INET_IFACE}" mtu 1500
  #all other links should be 1500 by default

  ## shut off ipv6 completely
  ip netns exec "${BOTTLENECK_NS}" sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null
  ip netns exec "${BOTTLENECK_NS}" sysctl -w net.ipv6.conf.veth0.disable_ipv6=1 &>/dev/null
  ip netns exec "${BOTTLENECK_NS}" sysctl -w net.ipv6.conf.veth1.disable_ipv6=1 &>/dev/null
  ip netns exec "${CLIENT_NS}" sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null
  ip netns exec "${CLIENT_NS}" sysctl -w net.ipv6.conf.veth0.disable_ipv6=1 &>/dev/null
  if [[ "${#SERVER_NS[@]}" -eq 0 ]]; then
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.veth1.disable_ipv6=1 &>/dev/null
  else
    ip netns exec "${GATEWAY_NS}" sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null
    ip netns exec "${GATEWAY_NS}" sysctl -w net.ipv6.conf.veth1.disable_ipv6=1 &>/dev/null
    ip netns exec "${GATEWAY_NS}" sysctl -w net.ipv6.conf.br-servers.disable_ipv6=1 &>/dev/null
    for (( i=0; i<${#SERVER_NS[@]}; i++ )); do
      ip netns exec "${GATEWAY_NS}" sysctl -w "net.ipv6.conf.veth-s$((i + 1)).disable_ipv6=1" &>/dev/null
      ip netns exec "${SERVER_NS[$i]}" sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null
      ip netns exec "${SERVER_NS[$i]}" sysctl -w net.ipv6.conf.veth1.disable_ipv6=1 &>/dev/null
    done
  fi
  if [[ "${NEED_MIRRORING}" = true ]]; then
    ip netns exec "${BOTTLENECK_NS}" sysctl -w net.ipv6.conf.ifb0.disable_ipv6=1 &>/dev/null
    ip netns exec "${BOTTLENECK_NS}" sysctl -w net.ipv6.conf.ifb1.disable_ipv6=1 &>/dev/null
  fi
}

function setup_dns {
  # when running in NAT mode we assume that there's some kind of resolver running on the host that listens on any ip address, incl. the ones we add via veth
  # NAT mode: the resolver address moves onto the tunnel (wg-host), so append
  # DNSStubListenerExtra=10.100.0.1 to /etc/systemd/resolved.conf for this variant
  if [[ "${#SERVER_NS[@]}" -eq 0 ]]; then
    echo "using 10.100.0.1 (wg-host) on host as DNS resolver"
    resolv_conf_str="nameserver 10.100.0.1"
  else
    echo "using localhost in ${CLIENT_NS} as DNS resolver"
    resolv_conf_str="nameserver 127.0.0.1"
  fi
  # TODO: this assumes that the host is running systemd resolved...
  # TODO: figure out how you can have getaddrinfo use this resolver...
  if [ -d "/etc/netns" ]; then
    if [ -d "/etc/netns/${CLIENT_NS}" ]; then
      if [ -f "/etc/netns/${CLIENT_NS}/resolv.conf" ]; then
      #echo "/etc/netns/${CLIENT_NS}/resolv.conf exists!!"
        echo "${resolv_conf_str}" > "/etc/netns/${CLIENT_NS}/resolv.conf"
        else
        touch "/etc/netns/${CLIENT_NS}/resolv.conf"
        echo "${resolv_conf_str}" > "/etc/netns/${CLIENT_NS}/resolv.conf"
      fi
    else
      cd /etc/netns
      mkdir "${CLIENT_NS}"
      cd "${CLIENT_NS}"
      touch resolv.conf
      echo "${resolv_conf_str}" > resolv.conf
    fi
  else
    cd /etc
    mkdir "netns"
    cd netns
    mkdir "${CLIENT_NS}"
    cd "${CLIENT_NS}"
    touch resolv.conf
    echo "${resolv_conf_str}" > resolv.conf
  fi
  cd "${bundledir}"
}

function setup_iptables {
  iptables-save > "/tmp/iptables_rules.v4"
  #https://www.gilesthomas.com/2021/03/fun-with-network-namespaces
  #set up NAT for internet access
  # decrypted client traffic enters the host via wg-host instead of veth1
  iptables -P FORWARD DROP
  iptables -F FORWARD
  iptables -t nat -F
  iptables -t nat -A POSTROUTING -s 10.100.0.2/32 -o "${INET_IFACE}" -j MASQUERADE
  iptables -A FORWARD -i "${INET_IFACE}" -o wg-host -j ACCEPT
  iptables -A FORWARD -o "${INET_IFACE}" -i wg-host -j ACCEPT
}


function setup_arp {
  # [TODO]: arp may be invalidated after some time or on link down; need to figure out if this could be a problem
  # only the 10.0.0.0/24 underlay crossing the shaped bridge needs ARP pinning; the
  # tunnel is L3 and never ARPs, and the gateway's server-side network is unshaped
  # and uncaptured, so normal ARP is fine there
  # disable automatic ARP discovery first and then set up ARP manually
  ip -netns "$CLIENT_NS" link set veth0 arp off
  #get MAC address of veth0 in client namespace
  MAC_ADDR_CLIENT=$(ip -netns "${CLIENT_NS}" link show veth0 | awk '/link\/ether/ {print $2}')
  if [[ "${#SERVER_NS[@]}" -eq 0 ]]; then
    ip link set veth1 arp off
    #get MAC address of veth1 in host namespace
    MAC_ADDR_ENDPOINT=$(ip link show veth1 | awk '/link\/ether/ {print $2}')
    #set up ARP for veth1 in host namespace to reach IP of veth0 in client namespace
    ip neigh add 10.0.0.2 lladdr "${MAC_ADDR_CLIENT}" dev veth1
  else
    ip -netns "${GATEWAY_NS}" link set veth1 arp off
    #get MAC address of veth1 in gateway namespace
    MAC_ADDR_ENDPOINT=$(ip -netns "${GATEWAY_NS}" link show veth1 | awk '/link\/ether/ {print $2}')
    #set up ARP for veth1 in gateway namespace to reach IP of veth0 in client namespace
    ip -netns "${GATEWAY_NS}" neigh add 10.0.0.2 lladdr "${MAC_ADDR_CLIENT}" dev veth1
  fi
  #set up ARP for veth0 in client namespace to reach IP of veth1 at the VPN endpoint
  ip -netns "$CLIENT_NS" neigh add 10.0.0.3 lladdr "${MAC_ADDR_ENDPOINT}" dev veth0
  # NOTE that "permanent" means something completely different for the bridge command
  ip netns exec "${BOTTLENECK_NS}" bridge fdb replace "${MAC_ADDR_CLIENT}" dev veth0 master static
  ip netns exec "${BOTTLENECK_NS}" bridge fdb replace "${MAC_ADDR_ENDPOINT}" dev veth1 master static
  # need to sleep or the pings fail
  sleep 2
}

function setup_wireguard {
  echo "setting up the wireguard tunnel across the shaped bottleneck"
  # client side: wg0 is the client's default interface, like a consumer VPN
  ip -netns "${CLIENT_NS}" link add wg0 type wireguard
  ip -netns "${CLIENT_NS}" address add 10.100.0.2/24 dev wg0
  ip netns exec "${CLIENT_NS}" wg set wg0 \
    private-key <(echo "${WG_CLIENT_PRIVKEY}") \
    peer "${WG_HOST_PUBKEY}" \
    allowed-ips 0.0.0.0/0 \
    endpoint 10.0.0.3:51820
  ip -netns "${CLIENT_NS}" link set dev wg0 up
  ip netns exec "${CLIENT_NS}" sysctl -w net.ipv6.conf.wg0.disable_ipv6=1 &>/dev/null
  # everything except the underlay (which is on-link and more specific) goes
  # through the tunnel
  ip -netns "${CLIENT_NS}" route add default dev wg0

  # termination side
  if [[ "${#SERVER_NS[@]}" -eq 0 ]]; then
    # NAT mode: terminate on the host, this is the bt-material's setup_tunnel with
    # the underlay stretched across the bottleneck; setup_iptables routes onwards
    ip link add wg-host type wireguard
    ip address add 10.100.0.1/24 dev wg-host
    wg set wg-host \
      private-key <(echo "${WG_HOST_PRIVKEY}") \
      listen-port 51820 \
      peer "${WG_CLIENT_PUBKEY}" \
      allowed-ips 10.100.0.2/32
    ip link set dev wg-host up
    sysctl -w net.ipv6.conf.wg-host.disable_ipv6=1 &>/dev/null
  else
    # server mode: terminate in the gateway namespace and MASQUERADE the decrypted
    # traffic onto the server bridge, so the servers see 10.237.0.2 as before
    ip -netns "${GATEWAY_NS}" link add wg-host type wireguard
    ip -netns "${GATEWAY_NS}" address add 10.100.0.1/24 dev wg-host
    ip netns exec "${GATEWAY_NS}" wg set wg-host \
      private-key <(echo "${WG_HOST_PRIVKEY}") \
      listen-port 51820 \
      peer "${WG_CLIENT_PUBKEY}" \
      allowed-ips 10.100.0.2/32
    ip -netns "${GATEWAY_NS}" link set dev wg-host up
    ip netns exec "${GATEWAY_NS}" sysctl -w net.ipv6.conf.wg-host.disable_ipv6=1 &>/dev/null
    ip netns exec "${GATEWAY_NS}" sysctl -w net.ipv4.ip_forward=1 &>/dev/null
    ip netns exec "${GATEWAY_NS}" iptables -t nat -A POSTROUTING -s 10.100.0.2/32 -o br-servers -j MASQUERADE
  fi
}

function check_tunnel {
  # one ping to the tunnel endpoint verifies connectivity AND pre-establishes the
  # wireguard handshake, so the first packet of a measurement does not pay for it
  echo "sanity pings through the tunnel"
  if ip netns exec "${CLIENT_NS}" ping -c 1 -W 3 10.100.0.1 &>/dev/null; then
    echo "tunnel to the VPN endpoint up"
  else
    echo "WARNING: no tunnel connectivity to the VPN endpoint (10.100.0.1)!"
  fi
  # in server mode also check end-to-end through the gateway NAT to every server
  for (( i=0; i<${#SERVER_NS[@]}; i++ )); do
    if ip netns exec "${CLIENT_NS}" ping -c 1 -W 3 "10.237.0.$((i + 3))" &>/dev/null; then
      echo "server 10.237.0.$((i + 3)) reachable through the tunnel"
    else
      echo "WARNING: server 10.237.0.$((i + 3)) not reachable through the tunnel!"
    fi
  done
}

#for all veth pairs and bridges: create -> set ip addresses/assign veth ends to bridge -> set up

function create {
  #check if we already set up an experiment and forgot to run destroy
  source "/tmp/VARS"
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

  if [[ "${#SERVER_NS[@]}" -ne 0 ]]; then
    setup_gateway_ns
  fi

  setup_ip

  setup_dns

  setup_arp

  if [[ "${#SERVER_NS[@]}" -eq 0 ]]; then
    setup_iptables
  fi

  setup_wireguard

  check_tunnel

  # write to vars
  if [[ "${#SERVER_NS[@]}" -eq 0 ]]; then
  cat << EOF >> "/tmp/VARS"
CLIENT_NS="${CLIENT_NS}"
BOTTLENECK_NS="${BOTTLENECK_NS}"
SETUP_ID="${DOWNSTREAM_THROUGHPUT} ${UPSTREAM_THROUGHPUT} ${DELAY_FROM_INET} ${DELAY_TO_INET} ${INET_IFACE}"
NEED_MIRRORING="${NEED_MIRRORING}"
TUNNEL="wireguard"
EOF
else
  local IFS=$','
  cat << EOF >> "/tmp/VARS"
CLIENT_NS="${CLIENT_NS}"
BOTTLENECK_NS="${BOTTLENECK_NS}"
GATEWAY_NS="${GATEWAY_NS}"
SERVER_NS_STRING="${SERVER_NS[*]}"
SETUP_ID="${DOWNSTREAM_THROUGHPUT} ${UPSTREAM_THROUGHPUT} ${DELAY_FROM_INET} ${DELAY_TO_INET}"
NEED_MIRRORING="${NEED_MIRRORING}"
TUNNEL="wireguard"
EOF
fi
}

function delete {
  source "/tmp/VARS"
  echo "deleting namespaces"
  # remove all namespaces
  ip netns pids "${CLIENT_NS}" | xargs -r kill
  ip netns del "${CLIENT_NS}" &>/dev/null
  ip netns pids "${BOTTLENECK_NS}" | xargs -r kill
  ip netns del "${BOTTLENECK_NS}" &>/dev/null
  # read SERVER_NS array from the variable SERVER_NS_STRING
  # in case we were in NAT mode, we do not write SERVER_NS_STRING to /tmp/VARS, but due to how bash works, the array will be empty anyway
  local IFS=$','
  read -r -a SERVER_NS <<< "${SERVER_NS_STRING}"
  if [[ "${#SERVER_NS[@]}" -eq 0 ]]; then
    ip link del veth1
    # the tunnel termination on the host does not die with a namespace
    ip link del wg-host &>/dev/null
    echo "restoring iptables"
    iptables-restore < "/tmp/iptables_rules.v4"
  else
    # the gateway namespace takes wg-host, its iptables rules and the server-side
    # veths down with it
    if [[ -n "${GATEWAY_NS}" ]]; then
      ip netns pids "${GATEWAY_NS}" | xargs -r kill
      ip netns del "${GATEWAY_NS}" &>/dev/null
    fi
    # remove all server namespaces
    for server_ns in "${SERVER_NS[@]}"; do
      ip netns pids "${server_ns}" | xargs -r kill
      ip netns del "${server_ns}" &>/dev/null
    done
  fi
  # remove any queuing disciplines outside the namespaces
  # tc qdisc delete dev veth1 root
  cat /dev/null > "/tmp/VARS"
  if [[ "${NEED_MIRRORING}" = true ]]; then
    echo "NOT unloading kernel modules ifb and act_mirred"
    echo "if needed, unload with: 'modprobe -r ifb act_mirred'"
  fi
  echo "done"
}

echo "Client will always be in separate network namespace regardless of experiment"
echo "This network namespace is called ${CLIENT_NS}; use \"source /tmp/VARS\" to use in other scripts"

echo "This setup uses one network namespace and bridge between the client and the VPN endpoint"
echo "The client reaches everything through ONE WireGuard tunnel; the bridge only carries the encrypted tunnel UDP"

if [[ "${COMMAND}" = "CREATE" ]]; then
  echo "Configuring setup"
  create;
elif [[ "${COMMAND}" = "DELETE" ]]; then
  echo "Deleting setup"
  delete;
fi

exit 0
