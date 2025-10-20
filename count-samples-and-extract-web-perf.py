#"undefended" "front-client-controlled-bidir" "front-client-and-server-controlled-bidir"
#/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}
import sys
from pathlib import Path
import json
import sqlite3




defense_types = ["undefended", "front-client-controlled-bidir", "front-client-and-server-controlled-bidir", "front-client-controlled-unidir"]

service_names = {}
#maps from full URIs to short names
try:
    with open("websites.json", "r") as f:
        service_names = json.load(f)
except FileNotFoundError:
    print("websites.json not found, cannot proceed", file=sys.stderr)
    sys.exit(1)

base_path = "/data/website-fingerprinting/packet-captures/"

if len(sys.argv) > 1:
    base_path = sys.argv[1]

measurement_schema = {
            "id": "string",
            "shaping": "string",
            "service_uri": "string",
            "defense": "string",
            "error": "string",
            "unfinished_defenses": "integer",
            "rough_timestamp": "double"
            }
navigation_schema = {
            "msm_id": "string",
            "connectEnd": "double",
            "connectStart": "double",
            "contentType": "string",
            "decodedBodySize": "integer",
            "domComplete": "double",
            "domContentLoadedEventEnd": "double",
            "domContentLoadedEventStart": "double",
            "domInteractive": "double",
            "domainLookupEnd": "double",
            "domainLookupStart": "double",
            "duration": "integer",
            "encodedBodySize": "integer",
            "fetchStart": "double",
            "loadEventEnd": "double",
            "loadEventStart": "double",
            "name": "string",
            "nextHopProtocol": "string",
            "redirectCount": "integer",
            "redirectEnd": "double",
            "redirectStart": "double",
            "requestStart": "double",
            "responseEnd": "double",
            "responseStart": "double",
            "responseStatus": "integer",
            "secureConnectionStart": "double",
            "startTime": "double",
            "transferSize": "integer"}
#technically we only really need startTime
#also apparently the "element" field is not serialized to JSON...
lcp_schema = {
            "msm_id": "string",
            "id": "string",
            "loadTime": "double",
            "renderTime": "double",
            "size": "integer",
            "startTime": "double",
            "url": "string"
}
#first-paint would be the same but seems to be missing
fcp_schema = {
            "msm_id": "string",
            "startTime": "double",
}

resources_schema = {
            "msm_id": "string",
            "connectEnd": "double",
            "connectStart": "double",
            "contentType": "string",
            "decodedBodySize": "integer",
            "domainLookupEnd": "double",
            "domainLookupStart": "double",
            "duration": "float",
            "encodedBodySize": "integer",
            "fetchStart": "double",
            "initiatorType": "string",
            "name": "string",
            "nextHopProtocol": "string",
            "redirectEnd": "double",
            "redirectStart": "double",
            "requestStart": "double",
            "responseEnd": "double",
            "responseStart": "double",
            "responseStatus": "integer",
            "secureConnectionStart": "double",
            "startTime": "double",
            "transferSize": "integer"
}

def schema_to_sql_create_if_not_exists(table_name: str, schema: dict, key_statement: str = None):
    sql = f"CREATE TABLE IF NOT EXISTS {table_name} ("
    for column, col_type in schema.items():
        sql += f"{column} {col_type}, "
    if key_statement:
        sql += key_statement
    else:
        sql = sql.rstrip(", ")
    sql += ");"
    return sql

def create_insert_statement(table_name: str, schema: dict, data: dict):
    column_list_ordered = list(schema.keys())
    columns = ", ".join(column_list_ordered)
    placeholders = ", ".join(["?"] * len(column_list_ordered))
    sql = f"INSERT INTO {table_name} ({columns}) VALUES ({placeholders})"
    values = [data.get(col, 0) for col in column_list_ordered]
    return sql, values




#open the sqlite db in base_path/web-performance.db
db_path = Path(base_path) / "web-performance.db"
# this script should be atomic so if the file already exists, we should remove it


print(f"Using database at {db_path}")
conn = sqlite3.connect(db_path)
c = conn.cursor()
# create tables if not exist
c.execute(schema_to_sql_create_if_not_exists("measurement", measurement_schema))
c.execute(schema_to_sql_create_if_not_exists("navigation", navigation_schema))
c.execute(schema_to_sql_create_if_not_exists("lcp", lcp_schema))
c.execute(schema_to_sql_create_if_not_exists("fcp", fcp_schema))
c.execute(schema_to_sql_create_if_not_exists("resources", resources_schema))
conn.commit()

for defense_subdir in Path(base_path).iterdir():
    if defense_subdir.is_dir() and defense_subdir.name in defense_types:
        print(f"Processing defense type: {defense_subdir.name}")
        for measurement_dir in defense_subdir.iterdir():
            if measurement_dir.is_dir():
                # msmID is a uuid, while shortname is a slugified uri
                # so we have to smartly split at hyphens
                # the UUID has 4 hyphens, so we split at the 5th hyphen
                parts = measurement_dir.name.split("-", 5)
                if len(parts) == 6:
                    msmID = parts[0]+"-"+parts[1]+"-"+parts[2]+"-"+parts[3]+"-"+parts[4]
                    shortname = parts[5]
                    if not shortname in service_names.values():
                        assert False, f"Shortname {shortname} not found in service_names"
                    # use service_names to find the full URI
                    full_uri = None
                    for uri, name in service_names.items():
                        if name == shortname:
                            full_uri = uri
                            break
                    if full_uri is None:
                        assert False, f"Full URI for shortname {shortname} not found"
                    # check if the measurement already exists in the measurements table based on id, shaping, service_uri, defense
                    c.execute("SELECT COUNT(*) FROM measurement WHERE id=? AND shaping=? AND service_uri=? AND defense=?", (msmID, "10Mbit 5Mbit 10ms 10ms", full_uri, defense_subdir.name))
                    result = c.fetchone()
                    if result[0] > 0:
                        print(f"Measurement {msmID} of website {full_uri} with defense {defense_subdir.name} already exists in database, skipping", file=sys.stderr)
                        continue
                    current_measurement = dict()
                    current_measurement['id'] = msmID
                    current_measurement['shaping'] = "10Mbit 5Mbit 10ms 10ms"
                    current_measurement['service_uri'] = full_uri
                    current_measurement['defense'] = defense_subdir.name
                    current_measurement['error'] = ""
                    current_measurement['unfinished_defenses'] = -1
                    # if the defense-state directory contains files, then those files correspond to unfinished defenses of QUIC connections
                    defense_state_dir = measurement_dir / "defense-state"
                    if defense_state_dir.is_dir():
                        unfinished_files = list(defense_state_dir.iterdir())
                        current_measurement['unfinished_defenses'] = len(unfinished_files)
                    current_measurement['rough_timestamp'] = measurement_dir.stat().st_mtime
                    # independently of the perf.json existing, there might be an error file, which we need for the measurements table
                    error_file = measurement_dir / "error.txt"
                    if error_file.is_file():
                        with open(error_file, "r") as ef:
                            error_str = ef.read().strip()
                            current_measurement['error'] = error_str

                    # the web performance results are in measurement_dir/perf.json
                    perf_file = measurement_dir / "perf.json"
                    # insert into measurement table only if either error.txt or perf.json exist
                    if error_file.is_file() or perf_file.is_file():
                        msm_sql, msm_values = create_insert_statement("measurement", measurement_schema, current_measurement)
                        c.execute(msm_sql, msm_values)
                        conn.commit()
                    else:
                        print(f"Skipping measurement {msmID} of website {full_uri} because neither error.txt nor perf.json exist", file=sys.stderr)
                        continue
                    # if perf.json exists, parse it and insert into navigation, lcp, fcp, resources tables
                    if perf_file.is_file():
                        with open(perf_file, "r") as pf:
                            try:
                                perf_data = json.load(pf)
                            except json.JSONDecodeError as e:
                                print(f"Error decoding JSON in file {perf_file}: {e}", file=sys.stderr)
                        #write perf_data to sqlite db in base_path/web-performance.db
                        if 'navigation' in perf_data:
                            navigation_data = perf_data['navigation']
                            navigation_data['msm_id'] = msmID
                            nav_sql, nav_values = create_insert_statement("navigation", navigation_schema, navigation_data)
                            c.execute(nav_sql, nav_values)
                            conn.commit()
                        if 'largestContentfulPaint' in perf_data:
                            lcp_data = perf_data['largestContentfulPaint']
                            # this is always a list but might only have one entry
                            # for LCP, we only store the last entry, since that is the latest LCP candidate
                            if isinstance(lcp_data, list) and len(lcp_data) > 0:
                                lcp_entry = lcp_data[-1]
                                lcp_entry['msm_id'] = msmID
                                lcp_sql, lcp_values = create_insert_statement("lcp", lcp_schema, lcp_entry)
                                c.execute(lcp_sql, lcp_values)
                                conn.commit()
                            else:
                                print(f"Largest Contentful Paint data is not a list or is empty for measurement {msmID} of website {full_uri}", file=sys.stderr)
                        if 'paint' in perf_data:
                            paint_data = perf_data['paint']
                            for paint_entry in paint_data:
                                if paint_entry.get('name', '') == 'first-contentful-paint':
                                    fcp_entry = paint_entry
                                    fcp_entry['msm_id'] = msmID
                                    fcp_sql, fcp_values = create_insert_statement("fcp", fcp_schema, fcp_entry)
                                    c.execute(fcp_sql, fcp_values)
                                    conn.commit()
                                    break
                        if 'resource' in perf_data:
                            resources_data = perf_data['resource']
                            for resource_entry in resources_data:
                                resource_entry['msm_id'] = msmID
                                res_sql, res_values = create_insert_statement("resources", resources_schema, resource_entry)
                                c.execute(res_sql, res_values)
                            conn.commit()
    else:
        print(f"Skipping non-directory or unknown defense type: {defense_subdir}", file=sys.stderr)