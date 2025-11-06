from pathlib import Path
import sys
defense_types = ["undefended", "front-client-controlled-bidir", "front-client-and-server-controlled-bidir", "front-client-controlled-unidir"]

base_path = "/data/website-fingerprinting/packet-captures/"

if len(sys.argv) > 1:
    base_path = sys.argv[1]

for defense_subdir in Path(base_path).iterdir():
    if defense_subdir.is_dir() and defense_subdir.name in defense_types:
        print(f"Processing defense type: {defense_subdir.name}")
        for measurement_dir in defense_subdir.iterdir():
            if measurement_dir.is_dir():
                replay_screenshot = measurement_dir / "replay.png"
                if replay_screenshot.is_file():
                    replay_screenshot.unlink()