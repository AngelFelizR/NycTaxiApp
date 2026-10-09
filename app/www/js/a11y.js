// Accessibility glue for things the R side cannot express (section 12).
//
// selectize() hides the <select> it replaces but leaves it in the DOM, and
// re-points the <label for> at the -selectized input. The hidden <select>
// then has no accessible name of its own, and HTMLCS -- the runner pa11y
// uses -- walks it anyway and reports H91.Select.Name / F68 for every
// selectizeInput in the app (eight errors). Screen readers already ignore
// it: it is display:none. aria-hidden just says out loud what the CSS
// already does, and HTMLCS then skips it (verified against pa11y).
//
// The listener is jQuery's, not addEventListener's, ON PURPOSE: Shiny fires
// shiny:sessioninitialized with $(document).trigger(...), and jQuery's
// trigger() never reaches native listeners -- a native listener here is
// silently dead code (which is exactly how the first version of this file
// failed to run). shiny:sessioninitialized is the right moment: input
// bindings, including selectize, have run by then, so the style.display
// test sees the final state. Selects are never recreated after that (6.1.1
// -- no renderUI for structure), so one pass is enough.
(function () {
  "use strict";

  function hideSelectizedSelects() {
    var selects = document.querySelectorAll("select.shiny-input-select");
    for (var i = 0; i < selects.length; i++) {
      if (selects[i].style.display === "none") {
        selects[i].setAttribute("aria-hidden", "true");
      }
    }
  }

  // The dark-mode toggle is not a tab, but bslib's nav_item() puts its <li>
  // inside the same <ul role="tablist"> as the panels, and axe then reports
  // aria-required-children: the toggle's real control is a <button> in the
  // component's shadow root, and a tablist may only hold tabs (4.1.2).
  // Role="presentation" on the <li> fixes listitem but not this -- the
  // button keeps its own role. So the toggle moves out of the tablist and
  // becomes a sibling of the <ul> inside .navbar-collapse (also flex, so the
  // layout does not move: the <ul> keeps flex-grow:1 and the toggle stays
  // pinned right). Idempotent: if bslib ever stops nesting it, or the script
  // ever runs twice, the selector simply misses.
  function moveDarkModeOutOfTablist() {
    var ul = document.getElementById("nav_principal");
    if (!ul) return;
    var item = ul.querySelector(":scope > li.bslib-nav-item");
    if (!item) return;
    var holder = document.createElement("div");
    holder.className = item.className;
    while (item.firstChild) holder.appendChild(item.firstChild);
    ul.parentNode.insertBefore(holder, ul.nextSibling);
    item.parentNode.removeChild(item);
  }

  function onSessionReady() {
    hideSelectizedSelects();
    moveDarkModeOutOfTablist();
  }

  if (window.jQuery) {
    window.jQuery(document).on("shiny:sessioninitialized", onSessionReady);
  } else {
    // No jQuery (should not happen inside Shiny): fall back to a native
    // listener, which Shiny 1.x does not fire for this event -- better than
    // nothing if that ever changes.
    document.addEventListener("shiny:sessioninitialized", onSessionReady);
  }
})();
