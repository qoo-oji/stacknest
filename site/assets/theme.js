// Light/dark switch: starts from the system appearance, remembers a manual choice when storage is available.
(function () {
  var root = document.documentElement;
  var KEY = "stacknest-theme";
  // A manual choice also counts for this page when storage is unavailable (private browsing).
  var chosen = false;

  function stored() {
    try { return localStorage.getItem(KEY); } catch (e) { return null; }
  }
  function store(value) {
    try { localStorage.setItem(KEY, value); } catch (e) { /* keep the choice for this page only */ }
  }
  function systemTheme() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  }

  var saved = stored();
  if (saved === "light" || saved === "dark") {
    chosen = true;
    root.setAttribute("data-theme", saved);
  } else {
    root.setAttribute("data-theme", systemTheme());
  }

  // The label names the action the button performs; no aria-pressed, so the two never contradict.
  function label(button) {
    var light = root.getAttribute("data-theme") === "light";
    button.setAttribute("aria-label", light ? button.dataset.toDark : button.dataset.toLight);
  }

  document.addEventListener("DOMContentLoaded", function () {
    var button = document.querySelector(".theme-toggle");
    if (!button) return;
    label(button);
    button.addEventListener("click", function () {
      var next = root.getAttribute("data-theme") === "light" ? "dark" : "light";
      chosen = true;
      root.setAttribute("data-theme", next);
      store(next);
      label(button);
    });
  });

  // Follow the system while the visitor has not chosen.
  if (window.matchMedia) {
    var query = window.matchMedia("(prefers-color-scheme: light)");
    var follow = function () {
      if (chosen) return;
      root.setAttribute("data-theme", query.matches ? "light" : "dark");
      var button = document.querySelector(".theme-toggle");
      if (button) label(button);
    };
    if (query.addEventListener) query.addEventListener("change", follow);
  }
})();
