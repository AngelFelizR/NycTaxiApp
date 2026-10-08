// The screen every other scenario starts from (section 6.1).
//
// The selector is the same one the shinytest2 flow waited on, and it is the
// honest signal: `#setup-validate` only exists once Shiny has rendered Setup,
// which requires the module, the zone list and the shared brand config to have
// all loaded. A blank page or an error boundary fails this immediately.
describe("setup screen", () => {
  it("renders and offers to validate the day", () => {
    cy.visit("/");
    cy.get("#setup-validate", { timeout: 30000 })
      .should("be.visible")
      .and("not.be.disabled");
  });

  it("renders an app, not an error boundary", () => {
    cy.visit("/");
    cy.get("body", { timeout: 30000 }).should("be.visible");
    // The failure mode we have actually seen: a dependency that cannot load
    // puts this sentence on the page instead of the form.
    cy.get("body").should("not.contain", "An error has occurred");
    cy.get("body").should("not.contain", "object 'model_state' not found");
  });
});
