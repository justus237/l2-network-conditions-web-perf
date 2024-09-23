#!/usr/bin/env python3
#basically the BDP -- this is porbably not all that realstic
#buffer (Bytes) = bandwidth_Mbit * RTT_ms * 1000 / 8

import sys
def calculate_buffer(bandwidth, delay1, delay2):
	#rtt = delay1+delay2
	if bandwidth.endswith("Mbit"):
		bandwidth = int(bandwidth.removesuffix("Mbit"))
		delay1 = int(delay1.removesuffix("ms"))
		delay2 = int(delay2.removesuffix("ms"))
		rtt = delay1+delay2
		buffer_bytes = int(rtt * bandwidth * 1000 / 8)
		if buffer_bytes < 1500:
			print("1500")
		else:
			print(buffer_bytes)
	elif bandwidth.endswith("kbit"):
		bandwidth = int(bandwidth.removesuffix("kbit"))
		delay1 = int(delay1.removesuffix("ms"))
		delay2 = int(delay2.removesuffix("ms"))
		rtt = delay1+delay2
		buffer_bytes = int(rtt * bandwidth / 8)
		if buffer_bytes < 1500:
			print("1500")
		else:
			print(buffer_bytes)
	else:
		# default value is MTU?
		print("1500")
if __name__ == "__main__":
   calculate_buffer(sys.argv[1], sys.argv[2], sys.argv[3])