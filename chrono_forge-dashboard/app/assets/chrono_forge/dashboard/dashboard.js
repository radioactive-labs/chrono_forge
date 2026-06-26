(function () {
  "use strict";

  // Collapsible context tree
  document.querySelectorAll("[data-collapsible] .cf-context__key").forEach(function (el) {
    el.addEventListener("click", function () { el.closest("li").classList.toggle("cf-collapsed"); });
  });

  // Auto-submit a filter control (e.g. the state select) on change.
  document.querySelectorAll("[data-autosubmit]").forEach(function (el) {
    el.addEventListener("change", function () {
      if (el.form) el.form.requestSubmit();
    });
  });

  // Whole-row navigation: a tr[data-href] opens the workflow, except when the
  // click landed on an interactive child (link/button/form/input).
  document.querySelectorAll("tr[data-href]").forEach(function (row) {
    row.addEventListener("click", function (e) {
      if (e.target.closest("a, button, input, form, summary")) return;
      window.location = row.getAttribute("data-href");
    });
  });

  // Confirm destructive actions: any form with data-confirm
  document.querySelectorAll("form[data-confirm]").forEach(function (form) {
    form.addEventListener("submit", function (e) {
      if (!window.confirm(form.getAttribute("data-confirm"))) e.preventDefault();
    });
  });

  // Polling refresh of the list/stats region
  var body = document.body, interval = parseInt(body.getAttribute("data-poll-interval") || "0", 10) * 1000;
  var region = document.querySelector("[data-poll-region]");
  if (interval > 0 && region && !body.hasAttribute("data-poll-paused")) {
    setInterval(function () {
      fetch(window.location.href, { headers: { "X-Requested-With": "XMLHttpRequest" } })
        .then(function (r) { return r.text(); })
        .then(function (html) {
          var doc = new DOMParser().parseFromString(html, "text/html");
          var fresh = doc.querySelector("[data-poll-region]");
          if (fresh) region.innerHTML = fresh.innerHTML;
        }).catch(function () {});
    }, interval);
  }
})();
