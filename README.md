# l2-network-conditions-web-perf
- currently requires systemd v247 or newer due to DNS stub resolver stuff
    - on earlier systemd versions, running `socat UDP-LISTEN:53,fork,reuseaddr,bind=192.168.0.2 UDP:127.0.0.53:53` solves the issue (probably need to apt install)
- see how well shaping works with `testing-dl-ul-rtt-with-iperf-and-irtt`
- `orchestation.sh` is the script for running experiments, requires some `.txt` files as input
- the main web performance scripts are `selenium-measure-website.py` and `lighthouse-navigation-and-paint-timings-run.js`; they both output to web-performance.db but their schemas are not compatible, so only use one of the two
