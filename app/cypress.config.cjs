// Cypress configuration for the Shiny app (section 10, phase 8).
//
// The app under test is Shiny: it answers over a WebSocket and rewrites its
// own DOM, so `cy.visit()` gets a page that is only half-built. Every spec
// waits for a real selector rather than for "the page loaded", which is what
// the shinytest2 tests did with wait_for_idle() -- the DOM is the only signal
// Cypress has.
//
// `e2e/devServer` is not used: the app is R, so app/dev/e2e.sh starts it (and
// the mock API when a spec needs one) and tears it down afterwards.
// A plain object, not defineConfig(): Cypress is installed once in the image
// (layer 11) rather than in node_modules, so require("cypress") here would
// fail with "Cannot find module 'cypress'" -- the helper only wraps the
// object, it does not read it.
module.exports = {
  e2e: {
    specPattern: "cypress/e2e/**/*.cy.js",
    // Overridden by CYPRESS_BASE_URL when the port differs.
    baseUrl: "http://127.0.0.1:3838",
    supportFile: "cypress/support/e2e.js",
    // Shiny's own sockets keep Cypress's network idle detection from ever
    // settling; assert on selectors instead of on idleness.
    chromeWebSecurity: false,
    defaultCommandTimeout: 20000,
    pageLoadTimeout: 60000,
    video: false,
    screenshotOnRunFailure: true,
  },
};
