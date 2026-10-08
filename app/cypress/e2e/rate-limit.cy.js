// Section 10 asks the UI to surface 429, 403, 404, 409 and 503, and says the
// Shiny test "simulates an httr2 that returns 429". Here there is nothing to
// simulate: the real limiter is in Redis and the app can trip it, so this
// asserts the message the API actually sends instead of one a mock was told
// to send.
//
// The limiter counts every POST /experiments against the caller's IP for the
// UTC day -- including the attempts that fail validation -- and allows three.
// The browser cannot present a different IP (Shiny reads X-Client-IP off the
// WebSocket handshake, which a page cannot set headers on), so the spec
// starts from a known counter and spends it: three real days, then the fourth
// start has to fail with the API's own words.
//
// It flushes on purpose. "Do not flush and let it trip" would depend on which
// spec ran first and how many days it happened to create.
describe("the real rate limit reaches the visitor", function () {
  this.timeout(300000);

  before(() => cy.task("redis_flush_db"));

  it("answers the fourth start with the API's 429 message", () => {
    // Three days that are allowed to succeed: the modal with the one-time
    // resume code is what proves the POST landed and the API accepted it.
    for (let i = 0; i < 3; i++) start_a_day();

    // The fourth must not reach the modal.
    visit_setup();
    cy.get("#setup-start_day", { timeout: 30000 }).should("be.visible").click();
    cy.get(".shiny-notification-error", { timeout: 30000 })
      .should("contain", "API error:")
      .and("contain", "limit of 3 experiments per day");
    cy.get(".modal").should("not.exist");
  });
});

function visit_setup() {
  cy.visit("/");
  cy.get("#setup-validate", { timeout: 30000 })
    .should("be.visible")
    .and("not.be.disabled");
  cy.get("#setup-validate").click();
}

function start_a_day() {
  visit_setup();
  cy.get("#setup-start_day", { timeout: 30000 }).should("be.visible").click();
  cy.get(".modal code", { timeout: 30000 }).should(($code) => {
    expect($code.text()).to.match(/[A-Za-z0-9_-]{8,}/);
  });
}
