
import selenium.common.exceptions
from selenium import webdriver
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.firefox.service import Service
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.firefox.firefox_profile import FirefoxProfile
#from selenium.webdriver.common.desired_capabilities import DesiredCapabilities
import subprocess
import sys
import sqlite3
from datetime import datetime
import hashlib
import json
import time
import subprocess
from urllib.parse import urlparse
import os
import random
from pathlib import Path

page = str(sys.argv[1])
print(page)
msm_id = str(sys.argv[2])
defence = str(sys.argv[3])
base_path = "/data/website-fingerprinting/packet-captures/"
if len(sys.argv) > 4:
    base_path = sys.argv[4]
    if not base_path.endswith("/"):
        base_path += "/"

base_path_defense = base_path +defence+"/"

service_names = {}
with open("websites.json", "r") as f:
    service_names = json.load(f)

full_uri = ""
if page.startswith(('http://', 'https://')):
    full_uri = page
else:
    full_uri = 'https://'+page
log_dir = base_path_defense+msm_id+"-"+service_names[full_uri]+"/"
#os.makedirs(log_dir, exist_ok=True)

ASYNC_PERF_SCRIPT = """
const return_to_selenium = arguments[0];
const navigationEntries = performance.getEntriesByType("navigation");
const paintEntries = performance.getEntriesByType("paint");
let result = {};
result.navigation = navigationEntries[0].toJSON();
result.paint = paintEntries.map((timingItem) => timingItem.toJSON());
result.timeOrigin = performance.timeOrigin;
//technically the resource timings are also buffered, but the initial value should be large enough?
const resources = performance.getEntriesByType('resource');
result.resource = resources.map((timingItem) => timingItem.toJSON());
new PerformanceObserver((entryList) => {
    result.largestContentfulPaint = entryList.getEntries().map((timingItem) => timingItem.toJSON());
    return_to_selenium(result);
}).observe({type: 'largest-contentful-paint', buffered: true});
"""


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




def create_driver_with_default_options():
    options = Options()
    options.add_argument("--headless")
    options.add_argument("--width=1600")
    options.add_argument("--height=1200")
    
    profile = FirefoxProfile()
    # https://support.mozilla.org/en-US/kb/how-stop-firefox-making-automatic-connections
    profile.set_preference('datareporting.healthreport.uploadEnabled', False)
    profile.set_preference('datareporting.policy.dataSubmissionEnabled', False)
    profile.set_preference('messaging-system.rsexperimentloader.enabled', False)
    profile.set_preference('app.shield.optoutstudies.enabled', False)
    profile.set_preference('app.normandy.enabled', False)
    profile.set_preference('browser.search.geoip.url', '')
    profile.set_preference('browser.startup.homepage_override.mstone', 'ignore')
    profile.set_preference('extensions.getAddons.cache.enabled', False)
    profile.set_preference('media.gmp-gmpopenh264.enabled', False)
    profile.set_preference('network.captive-portal-service.enabled', False)
    profile.set_preference('network.connectivity-service.enabled', False)
    
    profile.set_preference('services.settings.server', 'http://localhost')

    profile.set_preference('browser.cache.disk.enable', False)
    profile.set_preference('browser.cache.memory.enable', False)
    profile.set_preference('browser.cache.offline.enable', False)
    profile.set_preference('network.cookie.cookieBehavior', 2)
    profile.set_preference("network.http.use-cache", False)
    profile.set_preference("dom.disable_beforeunload", True)
    #you need to have $TMPDIR set, otherwise this won't work
    profile.set_preference('network.http.http3.enable_qlog', True)
    profile.set_preference('network.dns.forceResolve', '')
    profile.set_preference('network.dns.disableIPv6', True)

    profile.set_preference('network.http.http3.alt-svc-mapping-for-testing', '*;h3=":443"')
    #from network_bench.py
    profile.set_preference('network.http.http3.force-use-alt-svc-mapping-for-testing', True)
    profile.set_preference('network.http.http3.disable_when_third_party_roots_found', False)
    profile.set_preference('network.stricttransportsecurity.preloadlist', False)
    #network.http.http3.block_loopback_ipv6_addr
    #only native dns, disables DoH
    profile.set_preference('network.trr.mode', 5)
    # !!! this one should be the only preference  we need !!!
    profile.set_preference('network.http.http3.force-quic-on-all-connections', True)
    if defence in ["front-client-controlled-bidir"]:
        use_defence = 1
        #defence_seed = random.getrandbits(32)
    elif defence in ["front-client-and-server-controlled-bidir", "front-client-controlled-unidir"]:
        use_defence = 2
    else:
        use_defence = 0
        #defence_seed = 0
    profile.set_preference('network.http.http3.defense', use_defence)
    #profile.set_preference('network.http.http3.defence_seed', defence_seed)


    options.profile = profile
    #https://developer.mozilla.org/en-US/docs/Web/WebDriver/Capabilities/firefoxOptions#log_object
    #Available levels are trace, debug, config, info, warn, error, and fatal. If left undefined the default is info.
    options.log.level = "trace"
    #driver_env = os.environ.copy()
    #driver_env["MOZ_LOG"] = "timestamp,sync,nsHttp:5,nsSocketTransport:5,UDPSocket:5"
    #driver_env["MOZ_LOG_FILE"] = base_path_defense+msm_id+"/firefox"
    #driver_env["TMPDIR"] = base_path_defense+msm_id+"/"
    #options.binary_location="/home/fries/firefox/gecko-dev/obj-x86_64-pc-linux-gnu/dist/bin/firefox"
    options.binary_location="/home/fries/firefox-135.0.1/obj-ff-nightly/dist/bin/firefox"
    #driver_location = "/home/fries/firefox/geckodriver"
    driver_location = "/home/fries/firefox-135.0.1/target/release/geckodriver"
    #, env=driver_env
    return webdriver.Firefox(service=Service(driver_location), options=options)


async_script_perf = """
  var return_to_selenium = arguments[0];
  const perfEntries = performance.getEntriesByType("navigation");
  const paintEntries = performance.getEntriesByType("paint");
  const entry = perfEntries[0];
  let resultJson = entry.toJSON();
  resultJson.firstContentfulPaint = paintEntries.filter(paintItem => paintItem.name == "first-contentful-paint")?.[0]?.startTime;
  resultJson.firstPaint = paintEntries.filter(paintItem => paintItem.name == "first-paint")?.[0]?.startTime;
  if (!resultJson.firstContentfulPaint) {
    resultJson.firstContentfulPaint = 0;
  }
  if (!resultJson.firstPaint) {
    resultJson.firstPaint = 0;
  }
  const resources = performance.getEntriesByType('resource');
  if (resultJson.firstContentfulPaint != 0) {
    const resourcesBeforeFCP = resources.filter(resource => resource.responseEnd <= resultJson.firstContentfulPaint);
    resultJson.numResourcesBeforeFCP = resourcesBeforeFCP.length;
    resultJson.totalTransferSizeBeforeFCP = resourcesBeforeFCP.reduce((total, resource) => total + resource.transferSize, 0);
  } else {
    resultJson.numResourcesBeforeFCP = -1;
    resultJson.totalTransferSizeBeforeFCP = -1;
  }
  resultJson.rawResources = JSON.stringify(resources);
  
  resultJson.timeOrigin = performance.timeOrigin;
  //this returns the LCP as of the page load time :)
  new PerformanceObserver((entryList) => {
    let lcpEntry = entryList.getEntries().at(-1)
    //resultJson.largestContentfulPaint = {elementOuterHTML: lcpEntry.element.outerHTML, startTime: lcpEntry.startTime, size: lcpEntry.size, url: lcpEntry.url};
    resultJson.largestContentfulPaint = lcpEntry.startTime;
    return_to_selenium(resultJson);
  }).observe({type: 'largest-contentful-paint', buffered: true});
"""

def get_page_performance_metrics_and_write_logs(driver):
    # technically this could just be a global variable
    current_measurement = dict()
    current_measurement['id'] = msm_id
    current_measurement['shaping'] = "10Mbit 5Mbit 10ms 10ms"
    current_measurement['service_uri'] = full_uri
    current_measurement['defense'] = defence
    current_measurement['error'] = ""
    current_measurement['unfinished_defenses'] = -1
    current_measurement['rough_timestamp'] = time.time()
    try:
        print(full_uri)
        #https://stackoverflow.com/questions/63699473/is-the-firefox-web-console-accessible-in-headless-mode/63708393#63708393
        #have to use the string for whatever reason instead of driver.CONTEXT_CHROME
        # h3_reset_script = '''
        # Services.obs.notifyObservers(null, "net:cancel-all-connections");
        # Services.obs.notifyObservers(null, "network:reset-http3-excluded-list");
        # '''
        # with driver.context("chrome"):
        #     driver.execute_script(h3_reset_script)
        # from https://bugzilla.mozilla.org/show_bug.cgi?id=1523367#c13
        # another way of doing this is using bubblewrap to override using mount namespaces
        # dns_script = '''
        #const gOverride = Cc["@mozilla.org/network/native-dns-override;1"].getService(
        #  Ci.nsINativeDNSResolverOverride
        #);
        #gOverride.addIPOverride("example.com", "1.1.1.1");
        #gOverride.addIPOverride("example.org", "::1:2:3");
        #gOverride.addIPOverride("example.net", "N/A"); // NO IPs
        #'''
        # read the servers-and-hostnames.txt that the orchestration script also used
        # this enables us to add IP overrides for the domains
        # the file is a single line, servers are separated by semicolons, while origins within a server are separated by commas
        with open("/data/website-fingerprinting/webpage-replay/replay/"+service_names[full_uri]+"/servers-and-hostnames.txt", "r") as f:
            servers_and_hostnames = f.readline()
        servers = servers_and_hostnames.split(";")
        dns_override_script = '''const gOverride = Cc["@mozilla.org/network/native-dns-override;1"].getService(Ci.nsINativeDNSResolverOverride);
        '''
        for i, server in enumerate(servers):
            ip_address = "10.237.0." + str(i + 3)
            hostnames = server.split(",")
            for hostname in hostnames:
                dns_override_script += f'gOverride.addIPOverride("{hostname}", "{ip_address}");\n'
        with driver.context("chrome"):
            driver.execute_script(dns_override_script)
        #print(dns_override_script)
        driver.get(full_uri)
        print(service_names[full_uri])
        perf = driver.execute_async_script(ASYNC_PERF_SCRIPT)
        #with open(log_dir+'perf.json', 'w') as file:
        #    json.dump(perf, file)
        if 'navigation' in perf:
                navigation_data = perf['navigation']
                navigation_data['service_uri'] = page
                nav_sql, nav_values = create_insert_statement("navigation", navigation_schema, navigation_data)
                c.execute(nav_sql, nav_values)
                #conn.commit()
        if 'largestContentfulPaint' in perf:
            lcp_data = perf['largestContentfulPaint']
            # this is always a list but might only have one entry
            # for LCP, we only store the last entry, since that is the latest LCP candidate
            if isinstance(lcp_data, list) and len(lcp_data) > 0:
                lcp_entry = lcp_data[-1]
                lcp_entry['service_uri'] = page
                lcp_sql, lcp_values = create_insert_statement("lcp", lcp_schema, lcp_entry)
                c.execute(lcp_sql, lcp_values)
                #conn.commit()
            else:
                print(f"Largest Contentful Paint data is not a list or is empty for website {page}", file=sys.stderr)
        if 'paint' in perf:
            paint_data = perf['paint']
            for paint_entry in paint_data:
                if paint_entry.get('name', '') == 'first-contentful-paint':
                    fcp_entry = paint_entry
                    fcp_entry['service_uri'] = page
                    fcp_sql, fcp_values = create_insert_statement("fcp", fcp_schema, fcp_entry)
                    c.execute(fcp_sql, fcp_values)
                    #conn.commit()
                    break
        if 'resource' in perf:
            resources_data = perf['resource']
            for resource_entry in resources_data:
                resource_entry['service_uri'] = page
                res_sql, res_values = create_insert_statement("resources", resources_schema, resource_entry)
                c.execute(res_sql, res_values)
            #conn.commit()
        driver.get_screenshot_as_file(log_dir+"replay.png")
        return current_measurement
    except selenium.common.exceptions.WebDriverException as e:
        error_str = str(e)
        print(error_str)
        driver.get_screenshot_as_file(log_dir+'ERROR.png')
        if error_str == "":
            error_str = "unknown error"
        with open(log_dir+"error.txt", 'w', encoding='utf-8') as f:
            f.write(error_str)
        current_measurement['error'] = error_str
        return current_measurement


def perform_page_load():
    driver = create_driver_with_default_options()
    # for now we set this really high because the defense implementation inflates PLTs by quite a bit...
    driver.set_page_load_timeout(60)
    current_measurement = get_page_performance_metrics_and_write_logs(driver)
    log_file=log_dir+"firefox.moz_log"
    defense_state_dir = log_dir+"defense-state/"
    if defence in ["front-client-controlled-bidir", "front-client-controlled-unidir", "front-client-and-server-controlled-bidir"] and os.path.exists(defense_state_dir):
        # wait until the directory "/data/website-fingerprinting/packet-captures/$DEFENSE/${msmID}-${shortname}/defense-state/" is empty or 15 seconds have passed
        for i in range(3):
            if len(os.listdir(defense_state_dir)) > 0:
                print("waiting for defense to finish for 5 seconds")
                time.sleep(5)
            else:
                break
        # while True:
        #     try:
        #         with open(log_file, 'r') as f:
        #             lines = f.readlines()
        #             # Check if any line exactly matches "DEFENSE DONE"
        #             if any("DEFENSE DONE" in line  for line in lines):
        #                 break
        #     except FileNotFoundError:
        #         # File doesn't exist yet, continue waiting
        #         pass
        
    driver.quit()
    if defence in ["front-client-controlled-bidir", "front-client-controlled-unidir", "front-client-and-server-controlled-bidir"] and os.path.exists(defense_state_dir):
        unfinished_files = list(defense_state_dir.iterdir())
        current_measurement['unfinished_defenses'] = len(unfinished_files)
    msm_sql, msm_values = create_insert_statement("measurement", measurement_schema, current_measurement)
    c.execute(msm_sql, msm_values)
    conn.commit()
    if current_measurement.get("error", "") == "":
        return 0
    else:
        return 1

exit_code = perform_page_load()
sys.exit(exit_code)
