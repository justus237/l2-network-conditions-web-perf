#!/usr/bin/env python3
#other papers use the BDP for the burst
#https://unix.stackexchange.com/questions/100785/bucket-size-in-tbf
#burst (Bytes) = bandwidth_Mbit * 1000000/(250*8)

import sys
def calculate_burst(bandwidth):
	if bandwidth.endswith("Mbit"):
		bandwidth = bandwidth.removesuffix("Mbit")
		burst = int(int(bandwidth) * 1000000/2000)
		if burst < 1500:
			print("1500")
		else:
			print(burst)
	elif bandwidth.endswith("kbit"):
		bandwidth = bandwidth.removesuffix("kbit")
		burst = int(int(bandwidth) * 1000/2000)
		if burst < 1500:
			print("1500")
		else:
			print(burst)
	else:
		# default value
		print("1500")
if __name__ == "__main__":
   calculate_burst(sys.argv[1])