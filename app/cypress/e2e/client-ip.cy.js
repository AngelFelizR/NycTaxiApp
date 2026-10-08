// Section 5.4: the API counts rate limits by the address in X-Client-IP, and
// it only accepts that header together with a valid X-Internal-Key. The value
// Shiny forwards is the one it saw (app/R/state.R, client_ip()).
//
// The subtlety is that a browser cannot put a header on a WebSocket, and that
// is where Shiny reads it from -- so against the app directly, every session
// is seen as 127.0.0.1 and this test would compare the socket address with
// itself. dev/e2e-proxy.js stands where Nginx stands in production and puts a
// documentation address (203.0.113.9, TEST-NET-3) on the wire, which makes
// the two answers distinguishable: the API must count that address and must
// not count the socket it actually accepted the connection on.
//
// The assertion lives in Redis, not in a mock's memory: the counter key is
// exp:ip:<sha256(IP_HASH_SALT || ip)><date>, derived by the API itself.
describe("the app forwards the client IP it saw", function () {
  this.timeout(300000);

  before(() => cy.task("redis_flush_db"));

  it("counts the proxied address and not the socket", () => {
    start_a_day();

    cy.task("rate_limit_key", "203.0.113.9").then(({ key, counter }) => {
      expect(counter, `the API counted ${key}`).to.be.at.least(1);
    });
    cy.task("rate_limit_key", "127.0.0.1").then(({ key, counter }) => {
      expect(
        counter,
        `the socket address must not be the one the API used (${key})`,
      ).to.eq(0);
    });
  });
});

function start_a_day() {
  cy.visit("/");
  cy.get("#setup-validate", { timeout: 30000 })
    .should("be.visible")
    .and("not.be.disabled");
  cy.get("#setup-validate").click();
  cy.get("#setup-start_day", { timeout: 30000 }).should("be.visible").click();
  cy.get(".modal code", { timeout: 30000 }).should(($code) => {
    expect($code.text()).to.match(/[A-Za-z0-9_-]{8,}/);
  });
}
