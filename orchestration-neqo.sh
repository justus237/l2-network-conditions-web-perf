#!/bin/bash
#set -ex
if [[ $EUID -ne 0 ]]; then
	echo "$0 is not running as root. Try using sudo."
	exit 2
fi
front_seed=$1
msmID=$2
service=$3
uri=$4
#TODO: look up service_uri that is parent of uri...

echo ${uri}
echo "10Mbit 5Mbit 10ms 10ms"
echo "front defense"
./setup-shaping.sh CREATE 10Mbit 5Mbit 10ms 10ms
# getaddrinfo is not aware of a netns resolv.conf so don't even bother
#ip netns exec client-net dnsmasq --address=/#/192.168.0.2 &
#echo "nameserver 127.0.0.1" > "/etc/netns/client-net/resolv.conf"
#msmID=$(uuidgen)
shortname=$(python3 /home/fries/website-fingerprinting/website-fingerprinting-measurement/get_service_name.py "${service}")
echo ${shortname}
mkdir -p /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin
#timestamp="`date "+%Y-%m-%d_%H_%M_%S"`"
	
	#br-client-inet
ip netns exec client-net tcpdump -G 3600 -i any -w /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin/client.pcap 2> /tmp/tcpdump-client.log  &
tcpdumpclientPID=$!
ip netns exec bottleneck-net tcpdump -G 3600 -i any -w /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin/middle.pcap 2> /tmp/tcpdump-middlebox.log &
tcpdumpmiddlePID=$!
ip netns exec server-net tcpdump -G 3600 -i any -w /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin/server.pcap 2> /tmp/tcpdump-server.log &
tcpdumpserverPID=$!

ip netns exec server-net nginx -c "/data/website-fingerprinting/webpage-replay/replay/${shortname}.conf" > /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin/nginx.log &
nginxPID=$!

while ! { grep -q "start worker process" /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin/nginx.log && \
grep -q "listening on" /tmp/tcpdump-client.log && \
grep -q "listening on" /tmp/tcpdump-middlebox.log && \
grep -q "listening on" /tmp/tcpdump-server.log; };
do
  echo "waiting for nginx and tcpdumps to load"
  sleep 1
done
echo "nginx and tcpdumps finished loading"

#for key in $(jq -r 'keys[]' websites-to-hosts.json); do
#    # Get all items for this key at once
#    readarray -t items < <(jq -r ".$key[]" websites-to-hosts.json)
#    echo "${items[@]}"
#<done

if jq -e "has(\"${uri}\")" origins-to-http-resources.json; then
    readarray -t items < <(jq -r ".[\"${uri}\"][]" origins-to-http-resources.json)
    echo "${items[@]}"
else
    echo "website ${uri} not found in origins-to-http-resources.json"
fi


#sleep 5
	
#export TMPDIR=/data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}
export FRONT_SEED="${front_seed}"
export TRACE_CSV_DIR=/data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin/trace.csv
export SSLKEYLOGFILE=/data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin/sslkey.log
export RUST_LOG=neqo_bin=info,neqo_transport=trace,neqo_defense=debug
#export MOZ_LOG=neqo_transport::*:5,neqo_defense::*:5,neqo_glue::*:5
#export MOZ_LOG_FILE=/data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/firefox
#ip netns exec client-net python3 /home/fries/website-fingerprinting/website-fingerprinting-measurement/measure-website-firefox.py "${uri}" "${msmID}" "front"
export LD_LIBRARY_PATH=/home/fries/firefox/neqo/nss-3.107/dist/Debug/lib
export NSS_DIR=/home/fries/firefox/neqo/nss-3.107/nss
export REMOTE_ADDR="192.168.0.2"
#TODO: remote_addr is needed because getaddrinfo simply uses your default resolv.conf
# one way to fix this would be using bwrap (bwrap --dev-bind / / --bind ./configfiles/resolv.conf /etc/resolv.conf --bind ./configfiles/nsswitch.conf /etc/nsswitch.conf) but that creates a new mount namespace, which might cause other issues
# the arch wiki has an example for sandboxing firefox
if jq -e "has(\"${uri}\")" origins-to-http-resources.json; then
    readarray -t items < <(jq -r ".[\"${uri}\"][]" origins-to-http-resources.json)
    #echo "${items[@]}"
    ip netns exec client-net /home/fries/firefox/neqo/target/release/neqo-client "${items[@]}" -v -4 --qlog-dir /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin --output-read-data --output-dir /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin  > /tmp/neqo-bin-defense.log 2> /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin/neqo-client.log &
    neqoPID=$!
else
    echo "website ${uri} not found in origins-to-http-resources.json"
    ip netns exec client-net /home/fries/firefox/neqo/target/release/neqo-client "${uri}" -v -4 --qlog-dir /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin --output-read-data --output-dir /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin > /tmp/neqo-bin-defense.log 2> /data/website-fingerprinting/packet-captures/front/${msmID}-${shortname}/neqo-bin/neqo-client.log &
    neqoPID=$!
fi
#kinda need to adjust this... right now the client doesnt actually quit...
#while loop until the defense is done i guess? could also wait until the application is done but maybe not a good idea
while ! grep -Fxq "DEFENSE DONE" /tmp/neqo-bin-defense.log
do
  echo "waiting for defense to finish"
  sleep 1
done
echo "defense finished"
#sleep 10
kill -SIGINT $neqoPID
#wait  $neqoPID
kill -SIGINT $tcpdumpclientPID
wait $tcpdumpclientPID
kill -SIGINT $tcpdumpmiddlePID
wait $tcpdumpmiddlePID
kill -SIGINT $tcpdumpserverPID
wait $tcpdumpserverPID
kill -SIGTERM $nginxPID
wait $nginxPID
./setup-shaping.sh DELETE

