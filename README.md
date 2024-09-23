# l2-network-conditions-web-perf
- currently requires systemd v247 or newer due to DNS stub resolver stuff
- see how well shaping works with `testing-dl-ul-rtt-with-iperf-and-irtt`
- `orchestation.sh` is the script for running experiments, requires some `.txt` files as input
- the main web performance scripts are `selenium-measure-website.py` and `lighthouse-navigation-and-paint-timings-run.js`; they both output to web-performance.db but their schemas are not compatible, so only use one of the two
