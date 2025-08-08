import sys
import json
if __name__ == "__main__":
    service_names = {}
    with open("websites.json", "r") as f:
        service_names = json.load(f)
    print(service_names[sys.argv[1]])
