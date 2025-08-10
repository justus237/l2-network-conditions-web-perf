#!/usr/bin/env python3
#basically the BDP -- this is porbably not all that realstic
#buffer (Bytes) = bandwidth_Mbit * RTT_ms * 1000 / 8

import sys

def remove_suffix(input_string, suffix):
    if suffix and input_string.endswith(suffix):
        return input_string[:-len(suffix)]
    return input_string


def calculate_buffer(bandwidth, delay1, delay2):
	#rtt = delay1+delay2
	if bandwidth.endswith("Mbit"):
		bandwidth = int(remove_suffix(bandwidth, "Mbit"))
		delay1 = int(remove_suffix(delay1, "ms"))
		delay2 = int(remove_suffix(delay2, "ms"))
		rtt = delay1+delay2
		buffer_bytes = int(rtt * bandwidth * 1000 / 8)
		if buffer_bytes < 3000:
			print("3000")
		else:
			print(buffer_bytes)
	elif bandwidth.endswith("kbit"):
		bandwidth = int(remove_suffix(bandwidth, "kbit"))
		delay1 = int(remove_suffix(delay1, "ms"))
		delay2 = int(remove_suffix(delay2, "ms"))
		rtt = delay1+delay2
		buffer_bytes = int(rtt * bandwidth / 8)
		if buffer_bytes < 3000:
			print("3000")
		else:
			print(buffer_bytes)
	else:
		# default value is MTU?
		print("3000")
if __name__ == "__main__":
   calculate_buffer(sys.argv[1], sys.argv[2], sys.argv[3])