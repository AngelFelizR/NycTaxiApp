// Keyboard shortcuts for the Trips screen (master doc 6.5).
//
//   -> preselect Accept, <- preselect Enter confirms the preselection,
//   ? opens the help dialog, Escape clears it.
//
// The keys only PRESELECT: a decision is sent by Enter on a preselection or
// by a direct click/tap. That is the point of the feature -- an accidental
// keypress must never accept or reject an irreversible trip.
//
// The ids arrive from the server with a custom message so they stay
// namespace-correct (module ids are prefixed, e.g. "trips-card-accept").
(function () {
  "use strict";

  var cfg = null;
  var pre = null;

  function node(which) {
    if (!cfg || !which) return null;
    return document.getElementById(cfg[which]);
  }

  function clear() {
    var b = node(pre);
    if (b) b.classList.remove("preselected");
    pre = null;
  }

  function preselect(which) {
    var b = node(which);
    if (!b) return;
    if (pre === which) { clear(); return; }
    clear();
    b.classList.add("preselected");
    pre = which;
  }

  function confirmPre() {
    var b = node(pre);
    if (!b) return;
    clear();
    b.click();
  }

  // Typing in a field must never be read as a shortcut.
  function inField(t) {
    if (!t) return false;
    var tag = (t.tagName || "").toLowerCase();
    return tag === "input" || tag === "textarea" || tag === "select" ||
      t.isContentEditable;
  }

  // Shiny binds Escape to the modal element itself, so it only fires when the
  // focus is inside -- which it is not after opening the dialog with a key.
  // Rather than poking at Bootstrap's internals we tell the server, which owns
  // the modal, to remove it.
  var escapeSeq = 0;

  function onKey(e) {
    if (!cfg || inField(e.target)) return;
    switch (e.key) {
      case "ArrowRight": preselect("accept"); e.preventDefault(); break;
      case "ArrowLeft":  preselect("reject"); e.preventDefault(); break;
      case "Enter":      confirmPre();        e.preventDefault(); break;
      case "?":
        var h = node("help");
        if (h) { h.click(); e.preventDefault(); }
        break;
      case "Escape":
        clear();
        if (cfg.escape && window.Shiny && Shiny.shinyapp) {
          Shiny.setInputValue(cfg.escape, ++escapeSeq, { priority: "event" });
        }
        e.preventDefault();
        break;
    }
  }

  // Registering twice would double-fire on a re-render, so drop any previous
  // listener before installing the new config.
  function init(config) {
    cfg = config;
    pre = null;
    document.removeEventListener("keydown", onKey);
    document.addEventListener("keydown", onKey);
  }

  if (window.Shiny) {
    Shiny.addCustomMessageHandler("taxi.shortcuts", init);
  } else {
    // The handler must exist before Shiny connects; if the runtime is not
    // there yet, install it as soon as it shows up.
    window.addEventListener("shiny:connected", function once() {
      window.removeEventListener("shiny:connected", once);
      Shiny.addCustomMessageHandler("taxi.shortcuts", init);
    });
  }
  window.TaxiShortcuts = { init: init, clear: clear };
})();
