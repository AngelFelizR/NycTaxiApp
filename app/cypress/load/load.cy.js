// One session of a load run (section 8): a whole day played with the strategy
// dev/load_test.sh assigned, plus one what-if zone pick so N sessions also
// exercise POST /sensitivity while they run -- p95 of that endpoint is one of
// the three numbers section 8 asks for.
//
// It lives in cypress/load/ and NOT under cypress/e2e/ on purpose: the
// default specPattern is cypress/e2e/**/*.cy.js, which is what CI's
// ./dev/e2e.sh runs. A load session needs LOAD_RESULTS_FILE, its own proxy
// and its own client IP -- dev/load_test.sh provides those and points Cypress
// here with its own specPattern. Left under e2e/, the browser suite would
// start a load session with nothing around it and fail for a reason that has
// nothing to do with the suite.
//
// Nothing here measures the server. N Chromiums would measure the driver, not
// the app (ADR-0012), so the CPU/RSS numbers are sampled by dev/load_test.sh
// from the outside. What a session asserts is what only it can know:
//
//   - the day it finished is the day it started (`?exp=` vs #results-exp_id,
//     6.1.5: no session may read another's state),
//   - its Results counts are its own clicks (a decision that landed on
//     somebody else's day cannot add up),
//   - it followed its strategy: accept-all never rejects, and model-only is
//     confirmed by the server's own "% Following Policy" KPI, not by the
//     session's own bookkeeping,
//   - the percentile is a sentence and the day ended in Results.
//
// CYPRESS_STRATEGY = accept-all | model-only (default accept-all).
// CYPRESS_LOAD_ID  = the session's index, carried into the JSONL record.
// CYPRESS_CLIENT_IP = the address its own proxy puts on the wire, which is
// what the API counted when it allowed the experiment through 5.4.
describe("a session under load", function () {
  // A full day is ~50 decisions against one R process; profile 20 multiplexes
  // all of them through it. A session that has to be told to wait less than
  // the load allows is a session that fails on the interesting run.
  this.timeout(2700000);

  const strategy = Cypress.env("STRATEGY") || "accept-all";
  const loadId = String(Cypress.env("LOAD_ID") ?? "?");
  const clientIp = String(Cypress.env("CLIENT_IP") ?? "");

  it("plays its own day and reports it", function () {
    // Fail in the first second if the runner did not pass its environment:
    // a lost env prefix (a comment between the assignments and the command)
    // used to make a whole day play against the wrong proxy, with the wrong
    // strategy and with nowhere to record the result.
    expect(loadId, "CYPRESS_LOAD_ID is missing: run this spec via dev/load_test.sh")
      .to.not.eq("?");
    expect(
      ["accept-all", "model-only"],
      "CYPRESS_STRATEGY must be accept-all or model-only",
    ).to.include(strategy);

    // A shift's worth of offers, with a guard: the cap stops a loop that
    // never ends, it is not an expectation of how long a day takes.
    const s = {
      clicks: 0,
      accepted: 0,
      rejected: 0,
      model_reject_offers: 0,
      remaining: 150,
      started_at: null,
      finished_at: null,
      sensitivity: false,
    };

    // The setup waits run at 180 s: ten sessions booting at once serialize on
    // one R process, and the arrivals at either end of the ramp were still
    // waiting for the form a minute in. Patience on the RAMP is not patience
    // on the measurement -- the day itself, its waits below and the numbers
    // the report prints are untouched.
    // Defaults are enough: the form's own start is non-optimal by design, and
    // a custom seed would make every session of the run share one (the badge
    // in Results is what an edited seed costs -- 4.6).
    cy.visit("/");
    cy.get("#setup-validate", { timeout: 180000 })
      .should("be.visible")
      .and("not.be.disabled");
    cy.get("#setup-validate").click();
    cy.get("#setup-start_day", { timeout: 180000 }).should("be.visible").click();
    cy.get(".modal code", { timeout: 180000 }).should(($code) => {
      expect($code.text()).to.match(/[A-Za-z0-9_-]{8,}/);
    });
    cy.get("#confirm-continue").click();
    cy.then(() => {
      s.started_at = new Date().toISOString();
    });

    // 4.6: POST /experiments forks, so the day starts in `setup` and app.R
    // polls /state. Under load this is the slowest wait of the run, and it
    // has to outlive the SERVER's own budget: the load run raises
    // SETUP_TIMEOUT_S to 600 s (ten forks on eight cores), so the harness
    // watches 660 s -- giving up before the server does manufactures a
    // failure out of a day that was still being computed.
    cy.get("#trips-current_time", { timeout: 660000 }).should(($clock) => {
      expect($clock.text(), "the simulated clock").to.match(/\d{4}-\d{2}-\d{2}/);
    });
    cy.get("#trips-card-accept", { timeout: 300000 }).should("be.visible");

    // One what-if pick per session, so N sessions also exercise POST
    // /sensitivity concurrently -- p95 of that endpoint is one of the three
    // numbers section 8 asks for.
    //
    // The value goes through the selectize object Shiny attached to the
    // <select>, not through clicks. Measured, both dead ends: typing into
    // #<id>-selectized needs { force: true } (the input carries opacity: 0 by
    // design, which Cypress's actionability check rejects) and clicking a
    // dropdown option lands on the neighbouring picker -- the two zone
    // selects sit side by side and the session's screenshot showed the click
    // changed nothing; and setValue(v, true) is SILENT, so Shiny never hears
    // the change and no request is ever made. What works is setValue without
    // the silent flag, which is the event path a real click ends in.
    cy.get("#trips-sensitivity-pickup", { timeout: 60000 }).then(($el) => {
      const sel = $el[0].selectize;
      expect(sel, "the zone picker is initialized").to.not.equal(undefined);
      const keys = Object.keys(sel.options);
      const first = keys.find((k) => k !== "-");
      expect(
        first,
        `the zone catalogue is loaded (${keys.length} options)`,
      ).to.not.equal(undefined);
      // No second argument: `true` would be silent and Shiny would never see it.
      sel.setValue(first);
    });
    // The choice has to be on screen before the request it triggers is worth
    // waiting for: this is what proves the control accepted the value.
    cy.get("#trips-sensitivity-pickup", { timeout: 60000 }).should(($el) => {
      expect($el[0].selectize.getValue(), "the pickup zone changed").to.not.eq(
        "-",
      );
    });
    // The grid is only on screen once a result exists (plot_on), so the wait
    // below is also the retry: at profile 10, four of ten picks never
    // reached the API (the mirai queue was full) and nothing re-sends them
    // for the visitor -- who would simply choose another zone. Every
    // REPICK_MS this picks the NEXT zone, synchronously through the
    // selectize object (no cy.* inside a should callback: the retry has to
    // re-run in one pass). Any zone does: the grid is computed for whatever
    // pair the server holds, so the endpoint's cost does not depend on
    // which one.
    //
    // REPICK_MS must EXCEED the p95 of POST /sensitivity under this load or
    // the retry defeats itself: measured at profile 10, that endpoint takes
    // a median of 11 s and a p95 of ~20-29 s, so the original 10 s interval
    // invalidated every answer before it could draw -- the plot never
    // appeared and the abandoned requests piled up until POST /decisions of
    // the OTHER sessions stopped moving their clocks too. 45 s clears the
    // worst observed round-trip; REPICK_MAX stops a hopeless wait at ~6 min
    // with a diagnosable message instead of burning the full 10-min budget
    // one doomed request at a time.
    const REPICK_MS = 45000;
    const REPICK_MAX = 8;
    let last_pick = 0;
    let picks = 0;
    cy.get("#trips-sensitivity-plot", { timeout: 600000 }).should(($plot) => {
      if ($plot.is(":visible") && $plot.children().length > 0) return;
      const now = Date.now();
      if (now - last_pick >= REPICK_MS) {
        last_pick = now;
        picks += 1;
        if (picks > REPICK_MAX) {
          throw new Error(
            `the decision boundary never drew after ${REPICK_MAX} zone picks`,
          );
        }
        const el = $plot[0].ownerDocument.querySelector(
          "#trips-sensitivity-pickup",
        );
        const sel = el && el.selectize;
        if (sel) {
          const keys = Object.keys(sel.options).filter((k) => k !== "-");
          const cur = sel.getValue();
          const next = keys[(keys.indexOf(cur) + 1) % keys.length];
          if (next) sel.setValue(next);
        }
      }
      throw new Error("waiting for the decision boundary to draw");
    });
    cy.then(() => {
      s.sensitivity = true;
    });

    play_shift(s, strategy);

    cy.then(() => {
      s.finished_at = new Date().toISOString();
    });

    cy.get(".nav-link.active", { timeout: 60000 }).should(
      "contain",
      "Results",
    );

    // 6.1.5 in one assertion: the experiment Results shows has to be the one
    // this browser session created. Read inside the assertion so a Results
    // screen that is still painting is retried instead of compared against an
    // empty capture.
    cy.url().then((url) => {
      const own = new URL(url).searchParams.get("exp");
      expect(own, "the URL carries this session's day").to.match(/.+/);
      // Kept on the state object: the callback's `url` is out of scope by the
      // time load_record runs several layers down, and referencing it there
      // is what `ReferenceError: url is not defined` pointed at.
      s.exp_id = own;
      cy.get("#results-exp_id", { timeout: 60000 }).should(($el) => {
        expect($el.text().trim(), "the day Results belongs to").to.eq(own);
      });
    });

    // The six KPIs (6.5) and the percentile sentence.
    cy.get("#results-percentile", { timeout: 60000 })
      .invoke("text")
      .then((percentileText) => {
        expect(percentileText, "the percentile is a sentence").to.match(
          /\d+(st|nd|rd|th)/,
        );
        s.percentile = percentileText.trim();
      });

    cy.get("#results-accepted").invoke("text").then((acceptedText) => {
      cy.get("#results-rejected").invoke("text").then((rejectedText) => {
        cy.get("#results-following").invoke("text").then((followingText) => {
          const accepted = Number(acceptedText.trim().replace(/[^\d]/g, ""));
          const rejected = Number(rejectedText.trim().replace(/[^\d]/g, ""));
          const following = Number(followingText.trim().replace(/[^\d]/g, ""));

          // The session's own bookkeeping against the server's -- but as an
          // upper bound, not equality. A click may legitimately store
          // nothing: the run's own recovery sends a stale POST and the API
          // answers 409 "already decided with a different payload" without
          // storing, and a timed-out POST is collected by the resync rather
          // than by its own response. Measured on the 4-session profile:
          // 49 clicks, 48 stored, exactly one decision 409 in the API log.
          // Equality would fail that session for recovering correctly.
          // The bound is what still matters for 6.1.5: MORE decisions than
          // this session made would mean someone else's click landed here
          // (the distinct experiment ids check it the other way round).
          expect(
            accepted + rejected,
            "the day cannot hold more decisions than this session made",
          ).to.be.at.most(s.clicks);
          expect(s.clicks, "the shift produced decisions").to.be.greaterThan(0);

          if (strategy === "accept-all") {
            expect(rejected, "accept-all never rejects").to.eq(0);
            // And the server agrees about which offers the model would have
            // declined: when the session saw any, "% Following Policy" is
            // below 100 -- the number is computed from the stored decisions,
            // not from what the browser clicked.
            if (s.model_reject_offers > 0) {
              expect(following, "accept-all diverges from the policy").to.be.lessThan(100);
            }
          } else {
            // Model-only is confirmed by the server, not by the session:
            // pct_following_policy is computed in /finish from the stored
            // decisions and their model_recommended flags (ml_outcome.R).
            expect(following, "model-only follows the policy").to.eq(100);
          }

          cy.task("load_record", {
            load_id: loadId,
            strategy,
            client_ip: clientIp,
            exp_id: s.exp_id,
            started_at: s.started_at,
            finished_at: s.finished_at,
            clicks: s.clicks,
            accepted,
            rejected,
            following,
            model_reject_offers: s.model_reject_offers,
            sensitivity: s.sensitivity,
            percentile: s.percentile,
          });
        });
      });
    });
  });
});

// Decide until the navbar says Results. A decision either moves the clock or
// ends the shift -- the second one is a pass too, so the assertion allows
// either rather than failing on the very click that finishes the day. The
// same predicate-over-both-facts wait as full-day.cy.js, for the same race:
// the day can end in the tick between seeing "Trips" and reaching the button.
function play_shift(s, strategy) {
  cy.get(".nav-link.active", { timeout: 600000 }).should(($tab) => {
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
    if (s.remaining <= 0) throw new Error("the shift never ended");
    s.remaining -= 1;

    cy.get("#trips-card-model_text", { timeout: 120000 })
      .invoke("text")
      .then((modelText) => {
        // The card's copy is strings.R's label_model_accept/label_model_reject.
        const modelSaysAccept = modelText.indexOf("Accept trip") !== -1;
        if (!modelSaysAccept) s.model_reject_offers += 1;

        const accept = strategy === "accept-all" || modelSaysAccept;
        if (accept) s.accepted += 1;
        else s.rejected += 1;
        s.clicks += 1;

        cy.get("#trips-current_time")
          .invoke("text")
          .then((before) => {
            cy.get("#trips-card-trip_miles")
              .invoke("text")
              .then((milesBefore) => {
                cy.get(
                  accept ? "#trips-card-accept" : "#trips-card-reject",
                ).click();
                // Either the clock moved or the offer on the table is a
                // different one: comparing against the empty string would
                // pass on the very first trip and prove nothing.
                //
                // 300 s, not 120: when the POST /decisions answer is lost
                // (45 s client timeout, api_request), the resync GET is what
                // moves the clock, and at profile 10 that GET queues behind
                // the other sessions' work for minutes. The wait is the
                // recovery's budget, not a performance number -- the day's
                // own duration comes from its timestamps.
                cy.document({ timeout: 300000 }).should((doc) => {
                  const now =
                    doc.querySelector("#trips-current_time")?.textContent ?? "";
                  const miles =
                    doc.querySelector("#trips-card-trip_miles")?.textContent ??
                    "";
                  const tab =
                    doc.querySelector(".nav-link.active")?.textContent.trim() ??
                    "";
                  expect(
                    now !== before || miles !== milesBefore || tab === "Results",
                    `clock "${now}" vs "${before}", miles "${miles}" vs "${milesBefore}", tab "${tab}"`,
                  ).to.be.true;
                });
              });
          });
      });
    // The recursion goes INSIDE this callback, after the decision commands it
    // just queued -- never after the callback itself. Queued outside (as
    // `cy.then(() => play_shift(...))` was), it runs even when the branch
    // above returned because the day is over: predicate passes, callback
    // returns, recurse... 22 decisions and then ~11 000 empty iterations
    // until Mocha's 45-minute timeout, with the finished Results screen
    // sitting on the page the whole time. full-day.cy.js has it inside, and
    // that is why it stops.
    play_shift(s, strategy);
  });
}
