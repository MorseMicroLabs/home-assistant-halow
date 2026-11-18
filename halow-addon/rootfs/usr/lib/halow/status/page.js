(function () {
  "use strict";
  // Polls status.json (relative to this page, so it works behind Ingress) and, when the
  // status changes, reloads this page's server-rendered content in place. Every value in
  // that content was escaped by the server; nothing here builds markup from data.
  var main = document.getElementById("main");
  var conn = document.getElementById("conn");
  var last = null;
  var busy = false;

  function pageUrl() {
    return window.location.href.split("#")[0];
  }

  function swapMain(htmlText) {
    var doc = new DOMParser().parseFromString(htmlText, "text/html");
    var fresh = doc.getElementById("main");
    if (!fresh) {
      return;
    }
    while (main.firstChild) {
      main.removeChild(main.firstChild);
    }
    var nodes = Array.prototype.slice.call(fresh.childNodes);
    for (var i = 0; i < nodes.length; i++) {
      main.appendChild(document.importNode(nodes[i], true));
    }
  }

  function refresh() {
    if (busy) {
      return;
    }
    busy = true;
    fetch("status.json", { cache: "no-store", credentials: "same-origin" })
      .then(function (response) {
        if (!response.ok) {
          throw new Error("status " + response.status);
        }
        return response.text();
      })
      .then(function (text) {
        conn.hidden = true;
        if (text === last) {
          return null;
        }
        return fetch(pageUrl(), { cache: "no-store", credentials: "same-origin" })
          .then(function (response) {
            if (!response.ok) {
              throw new Error("status " + response.status);
            }
            return response.text();
          })
          .then(function (htmlText) {
            swapMain(htmlText);
            last = text;
          });
      })
      .catch(function () {
        conn.hidden = false;
      })
      .then(function () {
        busy = false;
      });
  }

  window.setInterval(refresh, @@REFRESH_MS@@);
})();
