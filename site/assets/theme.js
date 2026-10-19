// Light/dark switch: starts from the system appearance, remembers a manual choice when storage is available.
(function () {
  var root = document.documentElement;
  var KEY = "stacknest-theme";

  function stored() {
    try { return localStorage.getItem(KEY); } catch (e) { return null; }
  }
  function store(value) {
    try { localStorage.setItem(KEY, value); } catch (e) { /* private mode: keep it for this page only */ }
  }
  function systemTheme() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  }

  var saved = stored();
  root.setAttribute("data-theme", saved === "light" || saved === "dark" ? saved : systemTheme());

  function label(button) {
    var light = root.getAttribute("data-theme") === "light";
    button.setAttribute("aria-label", light ? button.dataset.toDark : button.dataset.toLight);
    button.setAttribute("aria-pressed", light ? "true" : "false");
  }

  document.addEventListener("DOMContentLoaded", function () {
    var button = document.querySelector(".theme-toggle");
    if (!button) return;
    label(button);
    button.addEventListener("click", function () {
      var next = root.getAttribute("data-theme") === "light" ? "dark" : "light";
      root.setAttribute("data-theme", next);
      store(next);
      label(button);
    });
  });

  // Follow the system while the visitor has not chosen.
  if (!saved && window.matchMedia) {
    var query = window.matchMedia("(prefers-color-scheme: light)");
    var follow = function () {
      if (stored()) return;
      root.setAttribute("data-theme", query.matches ? "light" : "dark");
      var button = document.querySelector(".theme-toggle");
      if (button) label(button);
    };
    if (query.addEventListener) query.addEventListener("change", follow);
  }
})();
