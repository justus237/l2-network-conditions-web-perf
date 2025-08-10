#!/usr/bin/env python3
#other papers use the BDP for the burst
#https://unix.stackexchange.com/questions/100785/bucket-size-in-tbf
#burst (Bytes) = bandwidth_Mbit * 1000000/(250*8)

import sys

def remove_suffix(input_string, suffix):
    if suffix and input_string.endswith(suffix):
        return input_string[:-len(suffix)]
    return input_string

def calculate_burst(bandwidth):
	if bandwidth.endswith("Mbit"):
		bandwidth = remove_suffix(bandwidth, "Mbit")
		burst = int(int(bandwidth) * 1000000/2000)
		if burst < 3000:
			print("3000")
		else:
			print(burst)
	elif bandwidth.endswith("kbit"):
		bandwidth = remove_suffix(bandwidth, "kbit")
		burst = int(int(bandwidth) * 1000/2000)
		if burst < 3000:
			print("3000")
		else:
			print(burst)
	else:
		# default value
		print("3000")
if __name__ == "__main__":
   calculate_burst(sys.argv[1])