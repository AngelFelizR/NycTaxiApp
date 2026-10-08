// Shared setup. Deliberately thin: the only thing every spec needs is for
// Shiny to have finished painting, and that is expressed as a selector --
// there is no "network idle" on a page that keeps a WebSocket open.
beforeEach(() => {
  cy.viewport(1440, 900);
});

// Shiny binds its inputs on the client and the server confirms them, so an
// input is only safe to set once its element exists AND is enabled.
cy.cmd = (selector) => cy.get(selector, { timeout: 20000 });
