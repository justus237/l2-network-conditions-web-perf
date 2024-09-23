
import selenium.common.exceptions
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.support.ui import WebDriverWait
import sys
import sqlite3
from datetime import datetime
import hashlib
import uuid
#from urllib.parse import urlparse

# performance elements to extract
measurement_elements = (
    'id', 'shaping', 'uri', 'vantagePoint', 'timestamp', 'connectEnd', 'connectStart', 'domComplete',
    'domContentLoadedEventEnd', 'domContentLoadedEventStart', 'domInteractive', 'domainLookupEnd', 'domainLookupStart',
    'duration', 'encodedBodySize', 'decodedBodySize', 'transferSize', 'fetchStart', 'loadEventEnd', 'loadEventStart',
    'requestStart', 'responseEnd', 'responseStart', 'secureConnectionStart', 'startTime', 'firstPaint',
    'firstContentfulPaint', 'nextHopProtocol', 'cacheWarming', 'error', 'redirectStart', 'redirectEnd', 'redirectCount', 'timeOrigin', 'largestContentfulPaint',
    'numResourcesBeforeFCP', 'totalTransferSizeBeforeFCP', 'rawResources')

# create db
db = sqlite3.connect('web-performance.db')
cursor = db.cursor()

#argv is always? an array of strings
page = str(sys.argv[1])

shaping = str(sys.argv[2])

vp_dict = {'compute-1': 'US East', 'ap-northeast-3': 'Asia Pacific Northeast', 'af-south-1': 'Africa South',
'eu-central-1': 'Europe Central', 'ap-southeast-2': 'Asia Pacific Southeast', 'us-west-1': 'US West',
'sa-east-1': 'South America East'}
vantage_point = vp_dict.get(sys.argv[3], '')

print(page+" "+shaping+" "+vantage_point)

def create_driver_with_default_options():
    options = Options()
    options.add_argument("--no-sandbox")
    options.add_argument("--headless")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-quic")
    options.add_argument("--disable-gpu")
    options.add_argument("--disable-http-cache")
    options.add_argument('user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36')
    options.add_argument('--lang=de')
    options.add_experimental_option('prefs', {'intl.accept_languages': 'de,de_DE'})
    options.add_argument("--window-size=1920,1080")
    options.binary_location = "/home/ubuntu/chrome_latest/chrome-linux/chrome"
    return webdriver.Chrome(service=Service("/home/ubuntu/chrome_latest/chromedriver_linux64/chromedriver"), options=options)


def get_page_performance_metrics(driver, page):
    script_perf = """// Get performance and paint entries
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
resultJson.timeOrigin = performance.timeOrigin;
resultJson.largestContentfulPaint = 0;
return resultJson;"""

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
    try:
        uri = ""
        if page.startswith(('http://', 'https://')):
            uri = page
        else:
            uri = 'https://'+page
        driver.get(uri)
        perf = driver.execute_async_script(async_script_perf)
        #domain_name = urlparse(driver.current_url).netloc
        #driver.get_screenshot_as_file(domain_name+'.png')
        return perf
    except selenium.common.exceptions.WebDriverException as e:
        error_str = str(e)
        perf = {k: 0 for k in measurement_elements}
        try:
            perf = driver.execute_script(script_perf)
        except selenium.common.exceptions.WebDriverException as e_script:
            error_str = error_str + str(e_script)
        #domain_name = urlparse(driver.current_url).netloc
        #driver.get_screenshot_as_file(domain_name+'.png')
        print(perf)
        if error_str == "":
            error_str = "unknown error"
        perf['error'] = error_str
        return perf


def perform_page_load(page, cache_warming=0):
    driver = create_driver_with_default_options()
    driver.set_page_load_timeout(15)
    timestamp = datetime.now()
    performance_metrics = get_page_performance_metrics(driver, page)
    driver.quit()
    # insert page into database
    if 'error' not in performance_metrics:
        performance_metrics['error'] = ""
        insert_performance(page, performance_metrics, timestamp, cache_warming=cache_warming)
        pl_status = 0
    else:
        insert_performance(page, performance_metrics, timestamp, cache_warming=cache_warming)
        pl_status = -1
    return pl_status


def create_measurements_table():
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS measurements (
            id string,
            shaping string,
            uri string,
            vantagePoint string,
            timestamp datetime,
            connectEnd double,
            connectStart double,
            domComplete double,
            domContentLoadedEventEnd double,
            domContentLoadedEventStart double,
            domInteractive double,
            domainLookupEnd double,
            domainLookupStart double,
            duration integer,
            encodedBodySize integer,
            decodedBodySize integer,
            transferSize integer,
            fetchStart double,
            loadEventEnd double,
            loadEventStart double,
            requestStart double,
            responseEnd double,
            responseStart double,
            secureConnectionStart double,
            startTime double,
            firstPaint double,
            firstContentfulPaint double,
            nextHopProtocol string,
            cacheWarming integer,
            error string,
            redirectStart double,
            redirectEnd double,
            redirectCount integer,
            timeOrigin datetime,
            largestContentfulPaint double,
            numResourcesBeforeFCP integer,
            totalTransferSizeBeforeFCP integer,
            rawResources string,
            PRIMARY KEY (id)
        );
        """)
    db.commit()





def insert_performance(page, performance, timestamp, cache_warming=0):
    performance['shaping'] = shaping
    performance['uri'] = page
    performance['timestamp'] = timestamp
    performance['cacheWarming'] = cache_warming
    performance['vantagePoint'] = vantage_point
    # generate unique ID
    sha = hashlib.md5()
    sha_input = ('' + shaping + page + str(cache_warming) + vantage_point + timestamp.strftime("%M:%H:%d"))
    sha.update(sha_input.encode())
    uid = uuid.UUID(sha.hexdigest())
    performance['id'] = str(uid)

    # insert into database
    cursor.execute(f"""
    INSERT INTO measurements VALUES ({(len(measurement_elements) - 1) * '?,'}?);
    """, tuple([performance[m_e] for m_e in measurement_elements]))
    db.commit()


create_measurements_table()


# cache warming
print(f'{page}: cache warming')
cw_status = perform_page_load(page, 1)
if cw_status == 0:
    # performance measurement if cache warming succeeded
    print(f'{page}: measuring')
    perform_page_load(page)

db.close()
