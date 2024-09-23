/**
 * @license
 * Copyright 2020 Google LLC
 * SPDX-License-Identifier: Apache-2.0
 */

import {Audit} from 'lighthouse';

class NavigationAndPaintTimingsAudit extends Audit {
  static get meta() {
    return {
      id: 'navigation-and-paint-timings',
      title: 'W3C navigation and paint timings',
      failureTitle: 'Unable to invoke W3C navigation or paint timings API in the browser.',
      description: 'W3C navigation and paint timings from within the browser',

      // The name of the custom gatherer class that provides input to this audit.
      requiredArtifacts: ['NavigationAndPaintTimingsGatherer'],
    };
  }

  static audit(artifacts) {
    //timings is an object
    const allTimings = artifacts.NavigationAndPaintTimingsGatherer.timings;
    //const success = value === '123';
    if (allTimings === undefined) {
      return {
        score: 0,
        numericValue: {},
        numericUnit: "millisecond",
        displayValue: 'Navigation and timings not available.',
      };
    }
    return {
      score: 1, // Example threshold of 3 seconds
      numericValue: allTimings,
      numericUnit: 'millisecond',
      displayValue: `Navigation and paint timings available, see numeric value.`,
    };
  }
}

export default NavigationAndPaintTimingsAudit;