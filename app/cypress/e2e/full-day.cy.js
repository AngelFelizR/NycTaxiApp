// One visitor, one day: Setup -> the resume-code modal -> Trips -> the shift
// played out -> Results. Ported from test-shinytest2.R scenarios 4 to 10,
// which ran in one session for the same reason this is one test: the day, the
// resume code and the seed all belong to a single browser session, and a page
// reload between them would start a new one.
//
// Everything here goes to the real API (dev/e2e.sh starts it): the
// trajectories come from the parquet, the percentile from
// ReferenceDistribution.qs2, and the rate limit from Redis. That is why this
// spec resets Redis before it runs -- see cypress.config.cjs.
describe("a full day against the real API", function () {
  // An async create, a shift of real decisions and a Results render: none of
  // them fits the default timeouts, and a spec that has to be told to wait
  // less than it needs is a spec that fails on a loaded machine.
  this.timeout(600000);

  before(() => cy.task("redis_flush_db"));

  it("sets up, plays the shift and lands on Results", () => {
    cy.visit("/");
    cy.get("#setup-validate", { timeout: 30000 })
      .should("be.visible")
      .and("not.be.disabled");

    // 3.3: the advanced seed is behind a checkbox, and the badge in Results is
    // the only place the value ever shows up.
    cy.get("#setup-advanced").check();
    cy.get("#setup-seed", { timeout: 15000 }).should("be.visible").type("4242");

    // A start the model disagrees with, so both hints have something to say.
    // The form's defaults are already non-optimal (company Lyft, zone 61), but
    // the datetime they carry is one the model keeps, which hides its own hint
    // (validation_hints only shows it when the advice differs).
    cy.get("#setup-start_dt").clear().type("2024-05-12T14:00:00Z");
    cy.get("#setup-validate").click();
    cy.get("#setup-company_hint", { timeout: 30000 }).should(
      "contain",
      "Use Uber for better results",
    );
    cy.get("#setup-datetime_hint").should("contain", "2024-05-14T15:00:00Z");
    cy.get("#setup-start_day", { timeout: 45000 }).should("be.visible");

    // The day exists from here on: the modal is one-time and the URL carries
    // the experiment from then on (6.5).
    cy.get("#setup-start_day").click();
    cy.get(".modal code", { timeout: 30000 }).should(($code) => {
      expect($code.text()).to.match(/[A-Za-z0-9_-]{8,}/);
    });
    cy.get("#confirm-continue").should("exist");
    cy.url().should("include", "?exp=");
    cy.get("#confirm-continue").click();

    // 4.6: POST /experiments forks, so the day starts in `setup` and app.R
    // polls /state until the trajectories are there. Nothing else flips it.
    //
    // Callback form, not `.invoke("text").should("match")`: invoke materialises
    // the string, so the assertion retries against the value it captured and
    // never sees the clock fill -- 20 s later it fails on "" while the day is
    // perfectly fine. The callback re-runs the query and keeps this timeout.
    cy.get("#trips-current_time", { timeout: 120000 }).should(($clock) => {
      expect($clock.text(), "the simulated clock").to.match(/\d{4}-\d{2}-\d{2}/);
    });
    cy.get("#trips-card-trip_miles", { timeout: 60000 }).should("exist");
    cy.get("#trips-card-accept").should("be.visible");
    cy.get(".trips-sidebar").should("exist");
    cy.get(".pending-bar").should("exist");
    cy.get("#trips-pending_fill").then(($fill) => {
      // shinyjs sizes the bar; an empty style means the call never happened.
      expect($fill[0].style.width).to.match(/%$/);
    });
    cy.get(".kbd-footer").should("be.visible");
    cy.get("#trips-resume").should("exist");
    // 3.11: the agreement score belongs to Results, not to this screen.
    cy.get(".trips-sidebar")
      .should("contain", "Earnings so far")
      .and("contain", "Decisions")
      .and("not.contain", "Following Policy");

    // Accepting moves the simulated clock (6.5).
    cy.get("#trips-current_time")
      .invoke("text")
      .then((before) => {
        cy.get("#trips-card-accept").click();
        cy.document().should((doc) => {
          const now =
            doc.querySelector("#trips-current_time")?.textContent ?? "";
          expect(now, "the clock moved").to.not.equal(before);
        });
      });

    // A keypress must not depend on focus left over from the form above.
    cy.document().then((doc) => doc.activeElement?.blur?.());

    // The arrows preselect, Enter confirms, and neither fires by itself.
    cy.get("body").type("{rightarrow}");
    cy.get("#trips-card-accept").should("have.class", "preselected");
    cy.get("#trips-card-reject").should("not.have.class", "preselected");
    cy.get("body").type("{rightarrow}");
    cy.get("#trips-card-accept").should("not.have.class", "preselected");
    cy.get("body").type("{leftarrow}");
    cy.get("#trips-card-reject").should("have.class", "preselected");

    cy.get("#trips-current_time")
      .invoke("text")
      .then((before) => {
        cy.get("body").type("{enter}");
        cy.get(".trip-actions .preselected").should("not.exist");
        cy.document().should((doc) => {
          const now =
            doc.querySelector("#trips-current_time")?.textContent ?? "";
          expect(now, "Enter sent the decision").to.not.equal(before);
        });
      });

    // The shortcuts dialog (6.5).
    cy.get("body").type("?");
    cy.get(".modal", { timeout: 15000 }).should(
      "contain",
      "Keyboard shortcuts",
    );
    cy.get("body").type("{esc}");
    cy.get(".modal").should("not.exist");

    // An 8-hour shift with trips of ~9 simulated minutes is on the order of
    // fifty decisions; the cap is a guard against a loop that never ends, not
    // an expectation of how long a day takes.
    play_shift(150);

    cy.get(".nav-link.active").should("contain", "Results");

    // 4.6 + 3.3: a custom seed makes the result unofficial, and the badge is
    // how the visitor is told.
    cy.get(".custom-seed").should("exist");

    // The percentile is a sentence, never a seventh KPI. Its value is the
    // model's, so assert the shape of it, not a number -- and read the DOM
    // inside the assertion so a Results screen that is still painting gets
    // retried instead of compared against an empty capture.
    cy.get("#results-percentile", { timeout: 30000 }).should(($el) => {
      expect($el.text()).to.match(/\d+(st|nd|rd|th)/);
      expect($el.text()).to.contain("percentile");
    });
    cy.get("#results-percentile_note").should("contain", "single sample");

    // The six KPIs (6.5) all carry a value.
    ["earnings", "hourly", "vs_policy", "accepted", "rejected", "following"]
      .forEach((kpi) => {
        cy.get(`#results-${kpi}`).should("not.be.empty");
      });
    // Colour is not enough on its own: the comparison carries an arrow (3.11).
    cy.get("#results-vs_policy").should(($el) => {
      expect($el.text()).to.match(/▲|▼/);
    });
    cy.get("#results-exp_id").should(($el) => {
      expect($el.text()).to.match(/[0-9a-f-]{8,}/);
    });

    // The htmlwidget paints asynchronously, so wait for the canvas instead of
    // sampling it once.
    cy.get("#results-plot_history").children().should("not.have.length", 0);
    cy.get("#results-feedback").should("be.visible");

    // 6.5/7.3: the anchors ship with href="#" and the server points them at
    // the card once the day carries a share_token (6.1.1 forbids renderUI for
    // structure, so this is the same pattern as the vs-policy colour).
    cy.get("#results-share-download", { timeout: 30000 }).should(($a) => {
      expect($a.attr("data-share-ready"), "share is wired").to.eq("1");
      expect($a.attr("href")).to.match(/\/share\/[A-Za-z0-9_-]+\.png$/);
    });
    cy.get("#results-share-x").should(($a) => {
      expect($a.attr("href")).to.match(/twitter\.com\/intent\/tweet\?url=/);
    });
    cy.get("#results-share-linkedin").should(($a) => {
      expect($a.attr("href")).to.match(/linkedin\.com\/sharing\/share-offsite\//);
    });

    // 6.5 feedback: a rating is required, so sending one empty keeps the
    // dialog open; a real click on the radio inside it is what a player does.
    cy.get("#results-feedback").click();
    cy.get(".modal", { timeout: 15000 }).should("contain", "How was your day");
    cy.get("#results-feedback-send").click();
    cy.wait(1000);
    cy.get(".modal").should("exist");
    cy.get('input[name="results-feedback-rating"][value="4"]').check();
    cy.get("#results-feedback-send").click();
    cy.get(".modal", { timeout: 20000 }).should("not.exist");

    // 6.5 second email prompt: Setup never filled the field, so the button
    // has to ask instead of sending blind. An address the client rejects is
    // not even allowed to reach the API.
    cy.get("#results-share-email").click();
    cy.get(".modal", { timeout: 15000 }).should(
      "contain",
      "Where should we send your card",
    );
    cy.get("#results-share-email_addr").type("nope");
    cy.get("#results-share-send").click();
    cy.wait(1000);
    cy.get(".modal").should("exist");
    cy.get("#results-share-email_addr")
      .clear()
      .type("driver@example.com");
    cy.get("#results-share-send").click();
    cy.get(".modal", { timeout: 30000 }).should("not.exist");
  });
});

// Play until the navbar says Results. A decision either moves the clock or
// ends the shift -- the second one is a pass too, so the assertion allows
// either rather than failing on the very click that finishes the day.
//
// The wait is a predicate over both facts on purpose: the day can end in the
// tick between seeing "Trips" and reaching the accept button, and then the
// button sits behind `display: none` for good while the tab reads Results.
// Waiting for visibility alone turns that race into a 30-second timeout.
function play_shift(remaining) {
  cy.get(".nav-link.active", { timeout: 45000 }).should(($tab) => {
    const doc = $tab[0].ownerDocument;
    const over = $tab.text().trim() === "Results";
    const accept = doc.querySelector("#trips-card-accept");
    const offered = !!accept && accept.offsetParent !== null;
    expect(
      over || offered,
      `tab="${$tab.text().trim()}", offer on the table: ${offered}`,
    ).to.be.true;
  });

  cy.get(".nav-link.active").then(($tab) => {
    if ($tab.text().trim() === "Results") return;
    if (remaining <= 0) throw new Error("the shift never ended");
    cy.get("#trips-current_time")
      .invoke("text")
      .then((before) => {
        cy.get("#trips-card-accept").click();
        cy.document().should((doc) => {
          const now =
            doc.querySelector("#trips-current_time")?.textContent ?? "";
          const tab =
            doc.querySelector(".nav-link.active")?.textContent.trim() ?? "";
          expect(
            now !== before || tab === "Results",
            `clock "${now}" vs "${before}", tab "${tab}"`,
          ).to.be.true;
        });
      });
    play_shift(remaining - 1);
  });
}
