
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

page = str(sys.argv[1])
print(page)
msm_id = str(sys.argv[2])
defence = str(sys.argv[3])
base_path = "/data/website-fingerprinting/packet-captures/"+defence+"/"


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
    profile.set_preference('network.dns.forceResolve', '192.168.0.2')
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
    if defence == "front-client":
        use_defence = 1
        #defence_seed = random.getrandbits(32)
    elif defence == "front-server":
        use_defence = 2
    elif defence == "undefended" or defence == "testing":
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
    #driver_env["MOZ_LOG_FILE"] = base_path+msm_id+"/firefox"
    #driver_env["TMPDIR"] = base_path+msm_id+"/"
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
        return error_str


def perform_page_load():
    driver = create_driver_with_default_options()
    # for now we set this really high because the defense implementation inflates PLTs by quite a bit...
    driver.set_page_load_timeout(60)
    error = get_page_performance_metrics_and_write_logs(driver)
    log_file=log_dir+"firefox.moz_log"
    if "front" in defence:
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
        print("waiting for defense to finish for 15 seconds")
        time.sleep(15)
    driver.quit()
    if error == "":
        return 0
    else:
        return 1

exit_code = perform_page_load()
sys.exit(exit_code)

