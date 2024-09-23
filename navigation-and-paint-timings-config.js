export default {
  // 1. Run your custom tests along with all the default Lighthouse tests.
  extends: 'lighthouse:default',

  // 2. Register new artifact with custom gatherer.
  artifacts: [
    {id: 'NavigationAndPaintTimingsGatherer', gatherer: 'navigation-and-paint-timings-gatherer'},
  ],

  // 3. Add custom audit to the list of audits 'lighthouse:default' will run.
  audits: [
    'navigation-and-paint-timings',
  ],

  /*settings: {
    "locale": "de",
  },*/
  // 4. Create a new 'My site audits' section in the default report for our results.
  /*categories: {
    mysite: {
      title: 'My site audits',
      description: 'Audits for our super awesome site',
      auditRefs: [
        // When we add more custom audits, `weight` controls how they're averaged together.
        {id: 'plt-audit', weight: 1},
      ],
    },
  },*/
};