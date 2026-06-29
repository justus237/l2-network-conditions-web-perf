
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

if len(sys.argv) < 4:
    print("Usage: python3 measure-website-firefox.py <page> <msm_id> <experiment> [<front-counter-mode>::default=sliding] [<server_instances>::default=multi] [<exit-on-load>::default=false] [<ff-build>::default=mine] [<front-once-per-run>::default=false]")
    sys.exit(1)
page = str(sys.argv[1])
print(page)
msm_id = str(sys.argv[2])
# experiment label: decides the output directory
experiment = str(sys.argv[3]) #if len(sys.argv) > 3 else defence

front_counter_mode = str(sys.argv[4]) if len(sys.argv) > 4 else "sliding"

server_instances = str(sys.argv[5]) if len(sys.argv) > 5 else "multi"

# "true" -> quit right after page load; otherwise wait for the defense to finish.
exit_on_load = (str(sys.argv[6]).lower() == "true") if len(sys.argv) > 6 else False

# which Firefox build to drive: "moz" -> distro/.deb build, otherwise my build.
ff_build = str(sys.argv[7]) if len(sys.argv) > 7 else "mine"

# client-side "single FRONT defense per measurement" (the analog of the server's
# FRONT_DEFENSE_CLAIM_FILE); true only for the first-connection qcsd experiment.
# hack: if qcsd is set we also set it to true
front_single_per_run = (str(sys.argv[8]).lower() == "true") if len(sys.argv) > 8 else False
if front_counter_mode == "qcsd":
    front_single_per_run = True


base_path = "/data/website-fingerprinting/packet-captures/"+experiment+"/"



# only the Firefox binary differs between builds; the same geckodriver drives both
if ff_build == "moz":
    ff_binary = "/home/fries/firefox/149.0-from-deb/usr/bin/firefox"
else:
    ff_binary = "/home/fries/firefox-149.0/obj-ff-nightly/dist/bin/firefox"


service_names = {}
with open("websites.json", "r") as f:
    service_names = json.load(f)

full_uri = ""
if page.startswith(('http://', 'https://')):
    full_uri = page
else:
    full_uri = 'https://'+page
log_dir = base_path+msm_id+"-"+service_names[full_uri]+"/"
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


def create_driver_with_default_options():
    options = Options()
    options.add_argument("--headless")
    options.add_argument("--width=1600")
    options.add_argument("--height=1200")
    options.add_argument("-remote-allow-system-access")
    
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
    
    profile.set_preference('devtools.chrome.enabled', True)

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

    if ff_build == "moz":
        # use servers_and_hostnames to override the alt-svc mapping for testing, so that we can force QUIC on all connections
        alt_svc_mapping = []
        with open("/data/website-fingerprinting/webpage-replay/replay/"+service_names[full_uri]+"/servers-and-hostnames.txt", "r") as f:
            servers_and_hostnames = f.readline()
        servers = servers_and_hostnames.split(";")
        for server in servers:
            hostnames = server.split(",")
            for hostname in hostnames:
                alt_svc_mapping.append(hostname + ';h3=":443"')
        profile.set_preference('network.http.http3.alt-svc-mapping-for-testing', ",".join(alt_svc_mapping))
    else: #we have a custom patch to just force quic :)
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
    defense_mode = 0
    if "front-client-and-server-controlled-bidir" in experiment or "front-client-controlled-unidir" in experiment:
        if front_counter_mode == "qcsd":
            defense_mode = 1
        else:   
            defense_mode = 2
    else:
        defense_mode = 0
        #defence_seed = 0
    profile.set_preference('network.http.http3.defense.mode', defense_mode)
    # client-side single FRONT defense per measurement (analog of the server's
    # FRONT_DEFENSE_CLAIM_FILE); enabled only for the first-connection qcsd run
    profile.set_preference('network.http.http3.defense.front.single_per_run', front_single_per_run)
    #profile.set_preference('network.http.http3.defence_seed', defence_seed)


    options.profile = profile
    #https://developer.mozilla.org/en-US/docs/Web/WebDriver/Capabilities/firefoxOptions#log_object
    #Available levels are trace, debug, config, info, warn, error, and fatal. If left undefined the default is info.
    #options.log.level = "trace"
    #driver_env = os.environ.copy()
    #driver_env["MOZ_LOG"] = "timestamp,sync,nsHttp:5,nsSocketTransport:5,UDPSocket:5"
    #driver_env["MOZ_LOG_FILE"] = base_path+msm_id+"/firefox"
    #driver_env["TMPDIR"] = base_path+msm_id+"/"
    #options.binary_location="/home/fries/firefox/gecko-dev/obj-x86_64-pc-linux-gnu/dist/bin/firefox"
    options.binary_location = ff_binary
    #driver_location = "/home/fries/firefox/geckodriver"
    driver_location = "/home/fries/firefox-149.0/obj-ff-nightly/dist/host/bin/geckodriver"
    #, env=driver_env, log_output=log_dir+"geckodriver.log"
    return webdriver.Firefox(service=Service(driver_location), options=options)


def get_page_performance_metrics_and_write_logs(driver):
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
        #const gOverride = Cc["@mozilla.org/network/native-dns-override;1"].getService(Ci.nsINativeDNSResolverOverride);
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
            ip_address = "10.237.0.3" if server_instances == "single" else "10.237.0." + str(i + 3)
            hostnames = server.split(",")
            for hostname in hostnames:
                dns_override_script += f'gOverride.addIPOverride("{hostname}", "{ip_address}");\n'
        with driver.context("chrome"):
            driver.execute_script(dns_override_script)
        #print(dns_override_script)
        driver.get(full_uri)
        print(service_names[full_uri])
        perf = driver.execute_async_script(ASYNC_PERF_SCRIPT)
        with open(log_dir+'perf.json', 'w') as file:
            json.dump(perf, file)
        driver.get_screenshot_as_file(log_dir+"replay.png")
        return ""
    except selenium.common.exceptions.WebDriverException as e:
        error_str = str(e)
        print(error_str)
        driver.get_screenshot_as_file(log_dir+'ERROR.png')
        if error_str == "":
            error_str = "unknown error"
        with open(log_dir+"error.txt", 'w', encoding='utf-8') as f:
            f.write(error_str)
        return error_str


def perform_page_load():
    driver = create_driver_with_default_options()
    # for now we set this really high because the defense implementation inflates PLTs by quite a bit...
    driver.set_page_load_timeout(60)
    error = get_page_performance_metrics_and_write_logs(driver)
    # unless we're told to exit right on load, wait for the defense to finish: the
    # server and client each drop a lock file in their state dir while defending and
    # remove it when done, so we wait until both dirs are empty (capped at ~15s). The
    # state dirs come from the env the orchestration exports.
    if not exit_on_load:
        defense_client_state_dir = os.environ.get("DEFENSE_CLIENT_STATE_DIR", "")
        defense_server_state_dir = os.environ.get("DEFENSE_SERVER_STATE_DIR", "")
        for _ in range(3):
            client_busy = bool(defense_client_state_dir) and os.path.isdir(defense_client_state_dir) and len(os.listdir(defense_client_state_dir)) > 0
            server_busy = bool(defense_server_state_dir) and os.path.isdir(defense_server_state_dir) and len(os.listdir(defense_server_state_dir)) > 0
            if client_busy or server_busy:
                print("[" + experiment + "]" + "waiting for defense to finish for 5 seconds: "+(",".join(os.listdir(defense_client_state_dir)) if client_busy else "") + (" and " if client_busy and server_busy else "") + (",".join(os.listdir(defense_server_state_dir)) if server_busy else ""))
                time.sleep(5)
            else:
                break
    #driver.service.process.kill()
    driver.quit()
    if error == "":
        return 0
    else:
        return 1

exit_code = perform_page_load()
sys.exit(exit_code)
