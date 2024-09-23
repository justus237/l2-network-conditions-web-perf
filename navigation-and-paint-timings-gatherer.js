/**
 * @license
 * Copyright 2020 Google LLC
 * SPDX-License-Identifier: Apache-2.0
 */

/* global document */

import {Gatherer} from 'lighthouse';


class NavigationAndPaintTimingsGatherer extends Gatherer {
  meta = {
    //see https://github.com/GoogleChrome/lighthouse/blob/main/docs/user-flows.md#the-three-modes-navigation-timespan-snapshot
    //navigation means a single page load
    supportedModes: ['navigation'],//, 'timespan', 'snapshot'],
  };

  async getArtifact(context) {
    const {driver, page} = context;
    const {executionContext} = driver;
    /*
    //code comments say to prefer evaluate over evaluateAsync for whatever reason
    //evaluate takes a function (mainFn) as an input, while evaluateAsync takes a string which is an expression
    //not sure why...
    console.log((await executionContext.evaluateAsync("JSON.stringify((() => window.performance.getEntriesByType('paint'))())")))
    console.log((await executionContext.evaluateAsync("JSON.stringify(window.performance.getEntriesByType('paint'))")))
    console.log(await executionContext.evaluate(() => JSON.stringify(performance.getEntriesByType('paint')), {args: [], useIsolation: false}))
    //basically the gatherer is run after the page load from what I can tell?
    //driver.evaluate(() => document.readyState === 'complete', {args: [], useIsolation: false});
    console.log("attempting to wait for page load")
    await page.waitForFunction("document.readyState === 'complete'")
    console.log("page should have already been loaded")*/
    const timings = await executionContext.evaluate(() => {
      let allTimings = performance.getEntriesByType('navigation')[0].toJSON();
      allTimings.timeOrigin = performance.timeOrigin;
      const paintTimings = performance.getEntriesByType('paint').map(entry => entry.toJSON());
      allTimings.firstContentfulPaint = paintTimings.filter(paintItem => paintItem.name == "first-contentful-paint")?.[0]?.startTime;
      allTimings.firstPaint = paintTimings.filter(paintItem => paintItem.name == "first-paint")?.[0]?.startTime;
      allTimings.resources = performance.getEntriesByType('resource').map(entry => entry.toJSON());
      return allTimings;
  }, {args: [], useIsolation: false});
    return {timings};
    /*
    // Inject an input field for our debugging pleasure.
    function makeInput() {
      const el = document.createElement('input');
      el.type = 'number';
      document.body.append(el);
    }
    await executionContext.evaluate(makeInput, {args: []});
    await new Promise(resolve => setTimeout(resolve, 100));

    // Prove that `driver` (Lighthouse) and `page` (Puppeteer) are talking to the same page.
    await executionContext.evaluateAsync(`document.querySelector('input').value = '1'`);
    await page.type('input', '23', {delay: 300});
    const value = await executionContext.evaluateAsync(`document.querySelector('input').value`);
    if (value !== '123') throw new Error('huh?');

    return {value};
    */
  }
}

export default NavigationAndPaintTimingsGatherer;