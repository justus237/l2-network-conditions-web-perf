import lighthouse from 'lighthouse';
import * as chromeLauncher from 'chrome-launcher';
import config from './navigation-and-paint-timings-config.js';
import sqlite3 from 'sqlite3';
import crypto from 'crypto';
//--from command line
//id, shaping,measured_uri,
//--from this script
//measurement_timestamp, script_error, cache_warming
//--from lighthouse result metadata
//requested_uri, main_document_uri, final_displayed_uri, fetch_time, runtime_error, runtime_warnings
//--from navigation and paint timings audit
//responseStatus, connectEnd, connectStart, domComplete, domContentLoadedEventEnd, domContentLoadedEventStart, domInteractive, domainLookupEnd,
//domainLookupStart, duration, encodedBodySize, decodedBodySize, transferSize, fetchStart, loadEventEnd, loadEventStart, requestStart, responseEnd,
//responseStart, secureConnectionStart, startTime, nextHopProtocol, firstInterimResponseStart, redirectStart, redirectEnd, redirectCount, timeOrigin,
//firstContentfulPaint, firstPaint
//from lighthouse first contentful paint audit
//lh_fcp_value, lh_fcp_unit
//from lighthouse largest contentful paint audit
//lh_lcp_value, lh_fcp_unit
//from lighthouse speed index audit
//lh_si_value, lh_si_unit
//from lighthouse cumulative layout shift audit
//lh_cls_value, lh_cls_unit

const informationRepresentingPrimaryKey = ["id"]
const informationFromCLI = ["shaping", "measured_uri"]
const informationFromThisScript = ["measurement_timestamp", "script_error", "cache_warming"]
const informationFromLighthouseResult = ["requested_uri", "main_document_uri", "final_displayed_uri", "fetch_time", "runtime_error", "runtime_warnings"]
const informationFromNavigationAndPaintTimings = ['startTime', 'duration',
  'nextHopProtocol', 'redirectStart', 'redirectEnd', 'fetchStart', 'domainLookupStart',
  'domainLookupEnd', 'connectStart', 'secureConnectionStart', 'connectEnd', 'requestStart', 'responseStart', 'firstInterimResponseStart',
  'responseEnd', 'transferSize', 'encodedBodySize', 'decodedBodySize', 'responseStatus',
  'domInteractive', 'domContentLoadedEventStart', 'domContentLoadedEventEnd', 'domComplete', 'loadEventStart', 'loadEventEnd',
  'redirectCount', 'firstContentfulPaint', 'firstPaint', 'timeOrigin']
const informationFromLighthouseFCP = ["lh_fcp_value", "lh_fcp_unit"]
const informationFromLighthouseLCP = ["lh_lcp_value", "lh_lcp_unit"]
const informationFromLighthouseSI = ["lh_si_value", "lh_si_unit"]
const informationFromLighthouseCLS = ["lh_cls_value", "lh_cls_unit"]
const informationFromLighthouseTBT = ["lh_tbt_value", "lh_tbt_unit"]
const informationFromLighthouseTTI = ["lh_tti_value", "lh_tti_unit"]
const informationFromLighthouseBT = ["lh_bt_value", "lh_bt_unit"]
const informationFromLighthouseRTT = ["lh_rtt_value", "lh_rtt_unit"]
const informationFromLighthouseSBL = ["lh_sbl_value", "lh_sbl_unit"]

const informationFromResourceTimings = ['connectEnd', 'connectStart',
  'decodedBodySize',
  'domainLookupEnd', 'domainLookupStart',
  'duration',
  'encodedBodySize',
  'fetchStart',
  'initiatorType',
  'name',
  'nextHopProtocol',
  'requestStart', 'responseEnd', 'responseStart',
  'secureConnectionStart',
  'startTime',
  'transferSize']

const dbSetup = () => {
  return new Promise((resolve, reject) => {
    db.run(`CREATE TABLE IF NOT EXISTS measurements (
    -- informationFromCLI
    id string,
    shaping string,
    measured_uri string,
    
    -- informationFromThisScript
    measurement_timestamp string,
    script_error string,
    cache_warming integer,
    
    -- informationFromLighthouseResult
    requested_uri string,
    main_document_uri string,
    final_displayed_uri string,
    fetch_time string,
    runtime_error string,
    runtime_warnings string,
    
    -- informationFromNavigationAndPaintTimings
    startTime double,
    duration integer,
    nextHopProtocol string,
    redirectStart double,
    redirectEnd double,
    fetchStart double,
    domainLookupStart double,
    domainLookupEnd double,
    connectStart double,
    secureConnectionStart double,
    connectEnd double,
    requestStart double,
    responseStart double,
    firstInterimResponseStart double,
    responseEnd double,
    transferSize integer,
    encodedBodySize integer,
    decodedBodySize integer,
    responseStatus integer,
    domInteractive double,
    domContentLoadedEventStart double,
    domContentLoadedEventEnd double,
    domComplete double,
    loadEventStart double,
    loadEventEnd double,
    redirectCount integer,
    firstContentfulPaint double,
    firstPaint double,
    timeOrigin datetime,
    
    -- informationFromLighthouseFCP
    lh_fcp_value double,
    lh_fcp_unit string,
    
    -- informationFromLighthouseLCP
    lh_lcp_value double,
    lh_lcp_unit string,
    
    -- informationFromLighthouseSI
    lh_si_value double,
    lh_si_unit string,
    
    -- informationFromLighthouseCLS
    lh_cls_value double,
    lh_cls_unit string,

    -- informationFromLighthouseTBT
    lh_tbt_value double,
    lh_tbt_unit string,

    -- informationFromLighthouseTTI
    lh_tti_value double,
    lh_tti_unit string,

    -- informationFromLighthouseBT
    lh_bt_value double,
    lh_bt_unit string,

    -- informationFromLighthouseRTT
    lh_rtt_value double,
    lh_rtt_unit string,

    -- informationFromLighthouseSBL
    lh_sbl_value double,
    lh_sbl_unit string

    -- Primary Key
    -- PRIMARY KEY (id)
);`, (err) => {
      if (err) reject(err);
      else resolve();
    });
  });
};

const dbSetupResources = () => {
  return new Promise((resolve, reject) => {
    db.run(`CREATE TABLE IF NOT EXISTS resources (
            msm_id string,
            msm_cache_warming integer,
            connectEnd double,
            connectStart double,
            decodedBodySize integer,
            domainLookupEnd double,
            domainLookupStart double,
            duration float,
            encodedBodySize integer, 
            fetchStart double,
            initiatorType string,
            name string,
            nextHopProtocol string,
            requestStart double,
            responseEnd double,
            responseStart double,
            secureConnectionStart double,
            startTime double,
            transferSize integer
            --FOREIGN KEY (msm_id) REFERENCES measurements(msm_id)
        );`, (err) => {
      if (err) reject(err);
      else resolve();
    });
  });
};



const [,, shaping, uri] = process.argv;
if (!shaping || !uri) {
  console.error('Usage: node navigation-and-paint-timings-run.js <shaping> <uri>');
  process.exit(1);
}
//generate UUID now rather than later I guess?
const uuid = crypto.randomUUID();
//console.log(uuid)

// SQLite database setup
const db = new sqlite3.Database('./web-performance.db', (err) => {
  if (err) {
    console.error('Error opening database:', err.message);
    process.exit(1);
  }
});

const loadWebsite = (async (uri) => {
  //we generate a timestamp here but also one further below because figuring out where we errored is annoying and probably pointless
  let measurementTimestamp = new Date().toISOString();
  //not sure we need the try catch, since lighthouse doesnt throw an error if the page load times out, only prints warnings to std err
  try {
    /*options.add_argument("--no-sandbox")
    options.add_argument("--headless")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
    options.add_argument("--disable-http-cache")
    options.add_argument('user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36')
    options.add_argument('--lang=de')
    options.add_experimental_option('prefs', {'intl.accept_languages': 'de,de_DE'})
    options.add_argument("--window-size=1920,1080")*/
    //locale can be set in lighthouse, window size not but the viewport, user agent can be set in lighthouse as well
    //--disable-dev-shm-usage shuld probably be set, because we dont care about tmp
    //no sandbox seems standard even in the examples but maybe try without
    //disable http cache seems very old, why did we add it?
    //potentially add --user-data-dir=/tmp/chrome-u/ and remove the directory
    //for some reason, the network rtt is always higher for the cache warming run
    //which would indicate we are caching somewhere..?
    //sadly there's no flag for DNS configuration
    //
    const chrome = await chromeLauncher.launch({
      chromeFlags: ['--headless', '--disable-gpu', '--no-sandbox', '--lang=de', '--disable-dev-shm-usage', '--disable-http-cache', '--disable-quic'],
      //chromePath: "/Users/justus/Downloads/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
      chromePath: "/home/ubuntu/chrome_latest/chrome-linux/chrome"
    });
    //console.log(chrome.port)
    //LH.Flags also allows specifying configPath but it didn't seem to load?
    //LH.Flags shares some options with LH.Config through LH.SharedFlagsSettings
    //not sure which one will take precedent... probably Config since it is the second argument to lighthouse()
    //flags takes precedence over any settings defined in the config file
    const flags = {
      //--LH.Flags
      port: chrome.port,
      //----hostname
      logLevel: 'info', //keep this at info because we will probably save command line output
      //----configPath
      //----plugins
      //--LH.SharedFlagsSettings
      output: 'json',
      locale:'de',//de or en-US
      maxWaitForFcp: 30*1000,
      maxWaitForLoad: 30*1000,
      //----blockedUrlPatterns
      //----additionalTraceCategories
      //auditMode: true,
      //----gatherMode
      //----disableStorageReset
      clearStorageTypes: ['all'],
      //----debugNavigation
      skipAboutBlank: true, //this should probably be set
      usePassiveGathering: true, //this should probably be set
      formFactor: 'mobile',
      /*screenEmulation: {
        mobile: false,
        width: 1920,
        height: 1080,
        deviceScaleFactor: 1,
        disabled: false,
      },*/
      //basically the default user agent of the browser (NOT of lighthouse) 
      //and also NOT headless
      //emulatedUserAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36',
      throttlingMethod: 'provided',
      /*throttlingMethod: 'devtools',
      throttling: {
        cpuSlowdownMultiplier: 1,
        requestLatencyMs: 0,
        downloadThroughputKbps: 0,
        uploadThroughputKbps: 0,
      },*/
      onlyAudits: [
        //'first-meaningful-paint',
        'first-contentful-paint',
        'largest-contentful-paint',
        'speed-index',
        'cumulative-layout-shift',
        'navigation-and-paint-timings',
        'total-blocking-time',
        'interactive',
        //'redirects',
        'bootup-time',
        'network-rtt',
        'network-server-latency',
        //'uses-rel-preconnect'
      ],
      //onlyCategories: ['performance'], //probably dont need this if we do onlyAudits, seems related to the output
      //----skipAudits
      extraHeaders: {'Accept-Language': 'de-DE'},
      //----channel //node, cli, devtools?
      //----precomputedLanternData
      //nonSimulatedSettingsOverrides -> this value is always set to 5250 if youre not using "simulate" throttlingMethod ...
      //comment out https://github.com/GoogleChrome/lighthouse/blob/d29a447/core/config/config.js#L234
      // shouldnt override these because then TTI cannot be calculated, see https://github.com/GoogleChrome/lighthouse/issues/10410
      pauseAfterFcpMs: 5250, //default 1000 i.e. 1s
      pauseAfterLoadMs: 5250, //default 1000 i.e. 1s
      networkQuietThresholdMs: 5250, //i dont understand this one
      cpuQuietThresholdMs: 5250,
      //blankPage:, replaces 'about:blank'
      disableFullPageScreenshot: true,
      //----ignoreStatusCode
    };
    measurementTimestamp = new Date().toISOString();
    const {lhr} = await lighthouse(uri, flags, config);

    // Output the relevant metrics to the console
    //console.log('Lighthouse audit completed.');
    //numericValue and numericUnit seem most relevant...
    //console.log(runnerResult.lhr.audits)
    //console.log(lhr.audits)
    //copy just to be safe...
    //let performanceResults = JSON.parse(JSON.stringify(lhr.audit['navigation-and-paint-timings'].numericValue))
    //console.log(performanceResults)


    //TODO: insert into sqlite db, including pageLoadIsCacheWarmup
    lhr.measurementTimestamp = measurementTimestamp;
    chrome.kill();
    return lhr;
  } catch (error) {
    //console.error('Error running Lighthouse audit:', error);
    return {error, measurementTimestamp}
  }
});

//this function is rather dumb, all the correctness checks are happening in main
//this should probably be changed :)
/*const insertMeasurement = async (resultObject) => {
  return new Promise((resolve, reject) => {
    const placeholders = Object.keys(data).map(() => '?').join(',');
    const sql = `INSERT INTO measurements (${Object.keys(data).join(',')}) VALUES (${placeholders})`;
    db.run(sql, Object.values(data), function(err) {
      if (err) reject(err);
      else resolve();
    });
  });
};*/

const insertMeasurement = async (resultMap) => {
  return new Promise((resolve, reject) => {
    // Get the keys and values from the Map in insertion order
    const keys = Array.from(resultMap.keys());
    const values = Array.from(resultMap.values());

    // Create the placeholders for the SQL query
    const placeholders = keys.map(() => '?').join(',');

    // Construct the SQL query using the keys
    const sql = `INSERT INTO measurements (${keys.join(',')}) VALUES (${placeholders})`;

    // Execute the SQL query with the values
    db.run(sql, values, function(err) {
      if (err) reject(err);
      else resolve();
    });
  });
};

const convertLHRToMapForInsertion = async (lhr, cacheWarming) => {
  const measurementResult = new Map()
  if (lhr.hasOwnProperty("error")) {
    //this means we generated the lhr object after lighthouse threw an exception
    //the type definition for LHResult does not have error as a property
    // informationRepresentingPrimaryKey
    measurementResult.set("id", uuid);
    // informationFromCLI
    measurementResult.set("shaping", shaping);
    measurementResult.set("measured_uri", uri);
    // informationFromThisScript
    measurementResult.set("measurement_timestamp", lhr.measurementTimestamp);
    measurementResult.set("script_error", lhr.error);
    measurementResult.set("cache_warming", cacheWarming);
    //insert dummy values for everything else
    //default value is 0; should probably be -1
    // informationFromLighthouseResult
    for (const propertyName of informationFromLighthouseResult) {
      //these are all strings so this works
      measurementResult.set(propertyName, "")
    }
    for (const propertyName of informationFromNavigationAndPaintTimings) {
      //hope it does this conversion properly...
      if (propertyName === "nextHopProtocol") {
        measurementResult.set(propertyName, "")
      } else {
        //probably some timing or datetime
        measurementResult.set(propertyName, 0)
      }
      
    }
    //just do these manually for now I guess
    //At some point I need some kind of universal schema thing
    //likely json schema..
    measurementResult.set("lh_fcp_value", 0)
    measurementResult.set("lh_fcp_unit", "")

    measurementResult.set("lh_lcp_value", 0)
    measurementResult.set("lh_lcp_unit", "")

    measurementResult.set("lh_si_value", 0)
    measurementResult.set("lh_si_unit", "")

    measurementResult.set("lh_cls_value", 0)
    measurementResult.set("lh_cls_unit", "")

    measurementResult.set("lh_tbt_value", 0)
    measurementResult.set("lh_tbt_unit", "")

    measurementResult.set("lh_tti_value", 0)
    measurementResult.set("lh_tti_unit", "")

    measurementResult.set("lh_bt_value", 0)
    measurementResult.set("lh_bt_unit", "")

    measurementResult.set("lh_rtt_value", 0)
    measurementResult.set("lh_rtt_unit", "")

    measurementResult.set("lh_sbl_value", 0)
    measurementResult.set("lh_sbl_unit", "")

    //measurementResult.set("redirects", "")

    //measurementResult.set("preconnect_usage", "")
    //measurementResult.set("error", )
    return measurementResult;
  }
  else {
    // informationRepresentingPrimaryKey
    measurementResult.set("id", uuid);
    // informationFromCLI
    measurementResult.set("shaping", shaping);
    measurementResult.set("measured_uri", uri);
    // informationFromThisScript
    measurementResult.set("measurement_timestamp", lhr.measurementTimestamp);
    measurementResult.set("script_error", "");
    measurementResult.set("cache_warming", cacheWarming);
    //insert dummy values for everything else
    //default value is 0; should probably be -1
    // informationFromLighthouseResult
    // renamed the property names so have to insert manually
    // I hate that javascript and python use different naming schemes..
    measurementResult.set("requested_uri", lhr.requestedUrl);
    measurementResult.set("main_document_uri", lhr.mainDocumentUrl);
    measurementResult.set("final_displayed_uri", lhr.finalDisplayedUrl);
    measurementResult.set("fetch_time", lhr.fetchTime);
    if (typeof(lhr.runtimeError) === "undefined") {
      measurementResult.set("runtime_error", "");
    } else {
      measurementResult.set("runtime_error", JSON.stringify(lhr.runtimeError));
    }

    if (typeof(lhr.runWarnings) === "undefined") {
      measurementResult.set("runtime_warnings", "");
    } else {
      measurementResult.set("runtime_warnings", lhr.runWarnings.join(" AND "));
    }
    
    const navPaintTimings = lhr.audits['navigation-and-paint-timings'].numericValue;
    //console.log(navPaintTimings);
    for (const propertyName of informationFromNavigationAndPaintTimings) {
      if (navPaintTimings && navPaintTimings.hasOwnProperty(propertyName)) {
        measurementResult.set(propertyName, navPaintTimings[propertyName]);
      } else {
        //this should never happen...
        measurementResult.set(propertyName, undefined);
      }
      
    }
    //just do these manually for now I guess
    //At some point I need some kind of universal schema thing
    //likely json schema..
    measurementResult.set("lh_fcp_value", lhr.audits['first-contentful-paint'].numericValue)
    measurementResult.set("lh_fcp_unit", lhr.audits['first-contentful-paint'].numericUnit)

    measurementResult.set("lh_lcp_value", lhr.audits['largest-contentful-paint'].numericValue)
    measurementResult.set("lh_lcp_unit", lhr.audits['largest-contentful-paint'].numericUnit)

    measurementResult.set("lh_si_value", lhr.audits['speed-index'].numericValue)
    measurementResult.set("lh_si_unit", lhr.audits['speed-index'].numericUnit)

    measurementResult.set("lh_cls_value", lhr.audits['cumulative-layout-shift'].numericValue)
    measurementResult.set("lh_cls_unit", lhr.audits['cumulative-layout-shift'].numericUnit)

    measurementResult.set("lh_tbt_value", lhr.audits['total-blocking-time'].numericValue)
    measurementResult.set("lh_tbt_unit", lhr.audits['total-blocking-time'].numericUnit)

    measurementResult.set("lh_tti_value", lhr.audits['interactive'].numericValue)
    measurementResult.set("lh_tti_unit", lhr.audits['interactive'].numericUnit)

    measurementResult.set("lh_bt_value", lhr.audits['bootup-time'].numericValue)
    measurementResult.set("lh_bt_unit", lhr.audits['bootup-time'].numericUnit)

    measurementResult.set("lh_rtt_value", lhr.audits['network-rtt'].numericValue)
    measurementResult.set("lh_rtt_unit", lhr.audits['network-rtt'].numericUnit)

    measurementResult.set("lh_sbl_value", lhr.audits['network-server-latency'].numericValue)
    measurementResult.set("lh_sbl_unit", lhr.audits['network-server-latency'].numericUnit)

    //measurementResult.set("redirects", JSON.stringify(lhr.audits['redirects']))

    //measurementResult.set("preconnect_usage", JSON.stringify(lhr.audits['uses-rel-preconnect']))
    //measurementResult.set("error", )
    return measurementResult;
  }
}

const insertResources = async (arrayOfResources) => {
  return new Promise((resolve, reject) => {
    db.serialize(() => {
      // Start a transaction to improve performance for multiple inserts
      db.run("BEGIN TRANSACTION");

      // Iterate over the array of resources (each resource is a Map)
      for (let resource of arrayOfResources) {
        const keys = Array.from(resource.keys());
        const values = Array.from(resource.values());

        // Create the placeholders for the SQL query
        const placeholders = keys.map(() => '?').join(',');

        // Construct the SQL query using the keys
        const sql = `INSERT INTO resources (${keys.join(',')}) VALUES (${placeholders})`;

        // Execute the SQL query with the values
        db.run(sql, values, function(err) {
          if (err) {
            db.run("ROLLBACK");
            reject(err);
            return;
          }
        });
      }

      // Commit the transaction once all inserts are done
      db.run("COMMIT", (err) => {
        if (err) {
          reject(err);
        } else {
          resolve();
        }
      });
    });
  });
};


const convertResourcesToMapForInsertion = async (resources, cacheWarming) => {
  if (typeof(resources) === "undefined") {
    return []
  }
  let newResources = [];
  for (const resource of resources) {
    const newResource = new Map();
    // informationRepresentingPrimaryKey
    newResource.set("msm_id", uuid);
    newResource.set("msm_cache_warming", cacheWarming);
    //console.log(navPaintTimings);
    for (const propertyName of informationFromResourceTimings) {
      if (resource.hasOwnProperty(propertyName)) {
        //initiatorType string, name string, nextHopProtocol string,
        newResource.set(propertyName, resource[propertyName]);
      } else {
        newResource.set(propertyName, undefined);
      }
    }
    newResources.push(newResource);
  }
  return newResources;
}

const main = async () => {
  try {
    await dbSetup();
    await dbSetupResources();
    console.log("Connected to sqlite db")
    const currTime = new Date().toISOString();
    console.log(`Measuring ${uri} under ${shaping}; <${uuid}> at ${currTime}`)
    console.log("Cache warming");
    let lighthouseResult = await loadWebsite(uri);
    console.log("Inserting cache warming into db");
    //we want to write the cache warming measurement to the database as well
    //in the previous version we used the cache warming in case the actual measurement timed out
    //which is probably reasonable but you could argue that it is unclean...
    let resultForInsert = await convertLHRToMapForInsertion(lighthouseResult, 1);
    await insertMeasurement(resultForInsert);
    let resourcesForInsert = await convertResourcesToMapForInsertion(lighthouseResult.audits['navigation-and-paint-timings']?.numericValue?.resources, 1);
    await insertResources(resourcesForInsert);
    if (lighthouseResult.hasOwnProperty("error")) {
      console.log("Cache warming was erronous, exiting")
      return;
    } else if (typeof(lighthouseResult.runtimeError) === "object"){// && lighthouseResult.runtimeError.code === "NO_FCP"){
      console.log(`Got error ${lighthouseResult.runtimeError.code}, exiting`)
      return;
    } else if (lighthouseResult.runWarnings.length > 0) {
      console.log("Got some runtime warning, exiting")
      console.log(lighthouseResult.runWarnings.join(";\n"))
      return;
    }


    console.log("Actual measurement");
    lighthouseResult = await loadWebsite(uri);
    console.log("Inserting actual measurement into db")
    resultForInsert = await convertLHRToMapForInsertion(lighthouseResult, 0);
    await insertMeasurement(resultForInsert);
    resourcesForInsert = await convertResourcesToMapForInsertion(lighthouseResult.audits['navigation-and-paint-timings']?.numericValue?.resources, 0);
    await insertResources(resourcesForInsert);
    console.log("Finished overall measurement (cache warming + actual)")
  } catch (error) {
    console.error('An error occurred:', error);
  } finally {
    console.log("Closing db")
    db.close((err) => {
      if (err) {
        console.error('Error closing database:', err.message);
      }
    });
  }
};
//I used to do this differently (anonymous main that is called directly); how is this different?
main().catch(console.error);