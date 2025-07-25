#!/usr/bin/env python3

# alternative: other papers use the BDP for the burst
# inspired by https://unix.stackexchange.com/questions/100785/bucket-size-in-tbf
# inspired by code from Justus Fries, modified by Benedikt Spies
# burst_bits = bandwidth_bps / sys_conf_rate_hz

import gzip
import re
import sys

def get_system_config_hz() -> float:
    config_path = "/proc/config.gz"
    with gzip.open(config_path, 'rt') as f:
        for line in f:
            if line.startswith("CONFIG_HZ="):
                value = line.strip().split('=')[1]
                return float(value)
    print("failed to read CONFIG_HZ")
    exit(1)

def calc_min_burst(bandwidth_bps: float) -> int:
    """returns bits"""
    return max(
        int(bandwidth_bps / get_system_config_hz()),
        1500 * 8 # at least one MTU sized packet
    )

bps_pattern = re.compile(r'^([\d\.]+)\s*(.*)$')

def parse_bps(str: str) -> int:
    """returns bps"""
    match = bps_pattern.match(str)
    if not match:
        print("failed to parse bps")
        exit(1)
    value = float(match.group(1))
    unit = match.group(2)
    if unit in ['Gbps', "Gbit", 'Gb/s', 'Gbit/s']:
        return value * 1E9
    elif unit in ['Mbps', "Mbit", 'Mb/s', 'Mbit/s']:
        return value * 1E6
    elif unit in ['kbps', 'kbit', 'kb/s', 'kbit/s']:
        return value * 1E3
    elif unit in ['bps', 'bit', 'b/s', 'bit/s']:
        return value
    else:
        print("failed to parse unit")
        exit(1)

if __name__ == "__main__":
   # prints burst in bits
   print(calc_min_burst(parse_bps(sys.argv[1])))