// ByteRipper Server — the console. No framework and no build step: the page
// is drawn with DOM calls, text always through textContent, and everything it
// shows comes from /admin/api/*, polled while the tab is visible
// (Design/SERVER_HEADLESS_PLAN.md §8). Activity is asked every second — it is
// the page that shows what a tool is doing right now — and the rest every two.
"use strict";

(() => {
  const POLL_MS = 2000;

  // ---------- DOM ----------

  function h(tag, props, ...children) {
    const el = document.createElement(tag);
    for (const [key, value] of Object.entries(props || {})) {
      if (value === undefined || value === null || value === false) continue;
      if (key === "class") el.className = value;
      else if (key === "text") el.textContent = value;
      else if (key.startsWith("on")) el.addEventListener(key.slice(2), value);
      else if (key === "value") el.value = value;
      else el.setAttribute(key, value === true ? "" : value);
    }
    append(el, children);
    return el;
  }

  function append(el, children) {
    for (const child of [children].flat(Infinity)) {
      if (child === undefined || child === null || child === false) continue;
      el.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return el;
  }

  function fill(el, ...children) {
    el.replaceChildren();
    return append(el, children);
  }

  const ICONS = {
    file: "M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z M14 3v5h5",
    chip: "M7 7h10v10H7z M9 3v4 M15 3v4 M9 17v4 M15 17v4 M3 9h4 M3 15h4 M17 9h4 M17 15h4",
    activity: "M3 12h4l3-8 4 16 3-8h4",
    key: "M7.5 21a4.5 4.5 0 1 0 0-9 4.5 4.5 0 0 0 0 9z M10.7 13.3 21 3 M18 6l2.5 2.5 M15.5 8.5 18 11",
    gauge: "M12 14l4-4 M3.5 18a9 9 0 1 1 17 0",
    logout: "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4 M16 17l5-5-5-5 M21 12H9",
    upload: "M12 16V4 M7 9l5-5 5 5 M4 16v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3",
    folder: "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z",
    refresh: "M21 12a9 9 0 1 1-2.64-6.36 M21 3v6h-6",
    x: "M18 6 6 18 M6 6l12 12",
    trash: "M3 6h18 M8 6V4h8v2 M6 6l1 14h10l1-14 M10 11v6 M14 11v6",
    up: "M12 19V5 M5 12l7-7 7 7",
    down: "M12 5v14 M19 12l-7 7-7-7",
    copy: "M9 9h11v11H9z M5 15H4V4h11v1",
    check: "M20 6 9 17l-5-5",
    alert: "M12 9v4 M12 17h.01 M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z",
    eye: "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z",
    eyeOff: "M3 3l18 18 M10.6 5.1A10 10 0 0 1 12 5c6.5 0 10 7 10 7a17 17 0 0 1-3.2 4.2 M6.6 6.6A17 17 0 0 0 2 12s3.5 7 10 7a9.8 9.8 0 0 0 5.4-1.6 M9.9 9.9a3 3 0 0 0 4.2 4.2",
    plus: "M12 5v14 M5 12h14",
    ban: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M5.6 5.6l12.8 12.8",
    bot: "M5 8h14v11H5z M12 8V4 M9 13h.01 M15 13h.01 M9 16h6",
    globe: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M3 12h18 M12 3a14 14 0 0 1 0 18 M12 3a14 14 0 0 0 0 18",
    server: "M4 4h16v6H4z M4 14h16v6H4z M8 7h.01 M8 17h.01",
    clock: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M12 7v5l3 2",
    users: "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z M22 21v-2a4 4 0 0 0-3-3.9 M16 3.1a4 4 0 0 1 0 7.8",
    plug: "M9 2v6 M15 2v6 M6 8h12v4a6 6 0 0 1-12 0z M12 18v4",
    layers: "M12 2 2 7l10 5 10-5z M2 17l10 5 10-5 M2 12l10 5 10-5",
    database: "M12 8c5 0 9-1.3 9-3s-4-3-9-3-9 1.3-9 3 4 3 9 3z M3 5v14c0 1.7 4 3 9 3s9-1.3 9-3V5 M3 12c0 1.7 4 3 9 3s9-1.3 9-3",
    terminal: "M4 17l6-6-6-6 M12 19h8",
    search: "M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16z M21 21l-4.3-4.3",
    // SF Symbols' exclamationmark.magnifyingglass: a review's findings.
    // slider.horizontal.2.arrow.trianglehead.counterclockwise: two sliders in a
    // counterclockwise arrow — a proposal to change a shared definition.
    proposals: "M3.6 12a8.4 8.4 0 1 0 2.46-5.94 M6.06 2.9v3.16h3.16 M8 9.5h1.6 M12.6 9.5H16 M9.6 9.5a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0-3 0 M8 14.5h3.4 M14.4 14.5H16 M11.4 14.5a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0-3 0",
    reviewFindings: "M10.5 18a7.5 7.5 0 1 0 0-15 7.5 7.5 0 0 0 0 15z M21 21l-5.2-5.2 M10.5 6.8v4.4 M10.5 14.2h.01",
    pause: "M8 5v14 M16 5v14",
    play: "M7 4l13 8-13 8z",
    scroll: "M8 6h13 M8 12h13 M8 18h9 M3 6h.01 M3 12h.01 M3 18h.01",
    braces: "M8 3H7a2 2 0 0 0-2 2v5a2 2 0 0 1-2 2 2 2 0 0 1 2 2v5a2 2 0 0 0 2 2h1 M16 3h1a2 2 0 0 1 2 2v5a2 2 0 0 0 2 2 2 2 0 0 0-2 2v5a2 2 0 0 1-2 2h-1",
    list: "M8 6h13 M8 12h13 M8 18h13 M3 6h.01 M3 12h.01 M3 18h.01",
    arrowRight: "M5 12h14 M13 5l7 7-7 7",
    sliders: "M4 21v-7 M4 10V3 M12 21v-9 M12 8V3 M20 21v-5 M20 12V3 M1 14h6 M9 8h6 M17 16h6",
    link: "M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7 M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7",
  };

  function icon(name, size = 18) {
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("width", size);
    svg.setAttribute("height", size);
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "1.9");
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("aria-hidden", "true");
    for (const d of ICONS[name].split(" M").map((part, index) => (index ? "M" + part : part))) {
      const path = document.createElementNS(ns, "path");
      path.setAttribute("d", d);
      svg.append(path);
    }
    return svg;
  }

  function iconButton(name, title, onclick, extra = "") {
    return h("button", { class: `icon-btn ${extra}`, title, "aria-label": title, type: "button", onclick }, icon(name, 17));
  }

  // ---------- Formatting ----------

  function bytes(n) {
    if (n === undefined || n === null) return "—";
    if (n < 1024) return `${n} B`;
    const units = ["KiB", "MiB", "GiB", "TiB"];
    let value = n / 1024;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
    return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
  }

  function ago(iso) {
    if (!iso) return "never";
    const seconds = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 1000));
    if (seconds < 5) return "just now";
    if (seconds < 60) return `${seconds} s ago`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)} h ago`;
    return when(iso);
  }

  function when(iso) {
    return new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  }

  function duration(seconds) {
    seconds = Math.max(0, Math.round(seconds));
    const d = Math.floor(seconds / 86400);
    const hh = Math.floor((seconds % 86400) / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    if (d) return `${d} d ${hh} h`;
    if (hh) return `${hh} h ${m} min`;
    if (m) return `${m} min`;
    return `${seconds} s`;
  }

  // A path shown from its end (the file's name is what matters): the marks
  // keep its slashes where they are under right-to-left clipping.
  function tail(path) {
    return `\u200E${path}\u200E`;
  }

  function plural(n, one, many) {
    return `${n} ${n === 1 ? one : many}`;
  }

  // ---------- Talking to the server ----------

  class ApiError extends Error {
    constructor(message, status) {
      super(message);
      this.status = status;
    }
  }

  function csrf() {
    const found = document.cookie.split(";").map((c) => c.trim()).find((c) => c.startsWith("br_csrf="));
    return found ? found.slice("br_csrf=".length) : "";
  }

  async function call(method, path, body) {
    const headers = { Accept: "application/json" };
    if (method !== "GET") headers["X-CSRF-Token"] = csrf();
    let payload;
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
      payload = JSON.stringify(body);
    }
    let response;
    try {
      response = await fetch(path, { method, headers, body: payload, credentials: "same-origin", cache: "no-store" });
    } catch {
      throw new ApiError("The server cannot be reached.", 0);
    }
    let data = null;
    try { data = await response.json(); } catch { /* an empty answer */ }
    if (response.status === 401 && path !== "/admin/login") {
      signedOut();
      throw new ApiError("Signed out.", 401);
    }
    if (!response.ok) throw new ApiError((data && data.error) || response.statusText, response.status);
    return data;
  }

  // An upload goes by XMLHttpRequest, which reports its progress.
  function upload(file, name, onProgress) {
    return new Promise((resolve, reject) => {
      const request = new XMLHttpRequest();
      request.open("POST", `/admin/api/uploads?name=${encodeURIComponent(name)}`);
      request.setRequestHeader("X-CSRF-Token", csrf());
      request.setRequestHeader("Content-Type", "application/octet-stream");
      request.upload.onprogress = (event) => { if (event.lengthComputable) onProgress(event.loaded / event.total); };
      request.onload = () => {
        let data = null;
        try { data = JSON.parse(request.responseText); } catch { /* none */ }
        if (request.status === 401) { signedOut(); reject(new ApiError("Signed out.", 401)); return; }
        if (request.status >= 200 && request.status < 300) resolve(data);
        else reject(new ApiError((data && data.error) || request.statusText, request.status));
      };
      request.onerror = () => reject(new ApiError("The upload did not reach the server.", 0));
      request.send(file);
    });
  }

  // The clipboard API lives only in a secure context — https, or a loopback
  // address. The console is opened on a LAN or tailnet name over plain HTTP,
  // which is not one; there the old gesture — a selection and execCommand —
  // is the only clipboard the page has.
  async function copy(text, what) {
    let copied = false;
    if (window.isSecureContext && navigator.clipboard) {
      try {
        await navigator.clipboard.writeText(text);
        copied = true;
      } catch { /* the selection below may still work */ }
    }
    if (!copied) copied = copyBySelection(text);
    if (copied) toast(`Copied ${what}`, "ok");
    else toast("The browser did not allow copying; select the text instead.", "error");
  }

  function copyBySelection(text) {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.top = "-1000px";
    area.style.opacity = "0";
    document.body.append(area);
    const selection = document.getSelection();
    const previous = selection && selection.rangeCount ? selection.getRangeAt(0) : null;
    area.select();
    area.setSelectionRange(0, text.length);
    let copied = false;
    try { copied = document.execCommand("copy"); } catch { copied = false; }
    area.remove();
    if (previous && selection) {
      selection.removeAllRanges();
      selection.addRange(previous);
    }
    return copied;
  }

  // ---------- Toasts and dialogs ----------

  function toast(message, kind = "ok") {
    const el = h("div", { class: `toast ${kind}` }, icon(kind === "ok" ? "check" : "alert", 17), h("div", { text: message }));
    document.getElementById("toasts").append(el);
    setTimeout(() => {
      el.classList.add("leaving");
      setTimeout(() => el.remove(), 250);
    }, kind === "ok" ? 2600 : 5200);
  }

  function dialog({ icon: iconName, tone = "", title, text, body, actions, wide = false }) {
    const el = h("dialog", wide ? { class: "wide" } : {});
    const close = (value) => { el.close(); el.remove(); return value; };
    let resolveResult;
    const result = new Promise((resolve) => { resolveResult = resolve; });
    el.addEventListener("cancel", () => resolveResult(close(null)));
    append(el, [
      h("div", { class: "dialog-head" },
        h("div", { class: `dialog-icon ${tone}` }, icon(iconName, 20)),
        h("div", {}, h("h3", { text: title }), text ? h("p", { text }) : null)),
      body ? h("div", { class: "dialog-body" }, body) : null,
      h("div", { class: "dialog-foot" },
        actions.map((action) => h("button", {
          class: `btn ${action.kind || ""}`,
          type: "button",
          autofocus: action.focus,
          onclick: async () => {
            if (action.run) {
              const outcome = await action.run();
              if (outcome === false) return;
              resolveResult(close(outcome === undefined ? action.value : outcome));
            } else {
              resolveResult(close(action.value));
            }
          },
        }, action.label))),
    ]);
    document.body.append(el);
    el.showModal();
    return result;
  }

  function confirmAction({ title, text, label, danger = true, iconName = "alert" }) {
    return dialog({
      icon: iconName,
      tone: danger ? "danger" : "",
      title,
      text,
      actions: [
        { label: "Cancel", kind: "ghost", value: false },
        { label, kind: danger ? "danger" : "primary", value: true, focus: true },
      ],
    });
  }

  function showSecret({ title, name, secret, preset, signedOutAfter }) {
    const usage = preset === "app"
      ? "Paste it into ByteRipper ▸ Settings ▸ Code Analysis on the Mac that uses this server."
      : preset === "admin"
        ? "It signs in to this console and opens every route."
        : "A client sends it as Authorization: Bearer <secret>.";
    return dialog({
      icon: "key",
      tone: "ok",
      title,
      text: `The secret of “${name}”.`,
      body: h("div", {},
        h("div", { class: "secret" }, h("span", { text: secret }),
          iconButton("copy", "Copy the secret", () => copy(secret, "the secret"))),
        h("div", { class: "notice" }, icon("alert", 16),
          h("div", { text: "This is the only time the secret is shown: the server keeps nothing but its hash. Store it now." })),
        h("p", { class: "hint", text: usage })),
      actions: [{ label: signedOutAfter ? "Done — sign in again" : "Done", kind: "primary", value: true, focus: true }],
    });
  }

  // ---------- State and routing ----------

  const state = {
    session: null,
    page: null,
    timer: null,
    live: null,
    // The sidebar's counts: their elements by page, and the timer that asks.
    counts: {},
    countTimer: null,
    // Which request logs the operator has opened, by token: the page is drawn
    // again on every poll, and a log that shut itself would be unreadable.
    // Which reports the operator has opened, and whether resolved ones show.
    resolvedIssues: false,
    // The record shown in the detail sheet: its key, and how to draw it from
    // the rows the page last read.
    detail: null,
    ticketState: "open",
  };

  const PAGES = {
    "/admin/documents": { title: "Documents", subtitle: "The firmware images the local MCP serves.", icon: "chip", endpoint: "/admin/api/documents", count: "documents", mount: mountDocuments },
    "/admin/activity": { title: "Activity", subtitle: "Who is connected now, and what each connection is doing.", icon: "activity", endpoint: "/admin/api/activity", interval: 1000, mount: mountActivity },
    "/admin/tickets": { title: "Review Tickets", subtitle: "What verifying agents found in each module's review, and the replies.", icon: "reviewFindings", endpoint: "/admin/api/tickets", interval: 10000, count: "tickets", mount: mountTickets },
    "/admin/issues": { title: "Server Issues", subtitle: "What agents reported about the server's tools.", icon: "alert", endpoint: "/admin/api/issues?all=1", interval: 10000, count: "issues", mount: mountIssues },
    "/admin/tokens": { title: "Tokens", subtitle: "Who may reach this server, and with which rights.", icon: "key", endpoint: "/admin/api/tokens", mount: mountTokens },
    "/admin/configuration": { title: "Configuration", subtitle: "How an agent on this machine connects to the server.", icon: "sliders", endpoint: "/admin/api/configuration", interval: 15000, mount: mountConfiguration },
    "/admin/status": { title: "Status", subtitle: "The server, its roles, its limits.", icon: "gauge", endpoint: "/admin/api/status", mount: mountStatus },
  };

  function go(path, replace = false) {
    if (location.pathname + location.search !== path) {
      history[replace ? "replaceState" : "pushState"]({}, "", path);
    }
    render();
  }

  function signedOut() {
    if (location.pathname === "/admin/login") return;
    state.session = null;
    stopPolling();
    const next = location.pathname in PAGES ? `?next=${encodeURIComponent(location.pathname)}` : "";
    go(`/admin/login${next}`, true);
  }

  window.addEventListener("popstate", render);
  document.addEventListener("visibilitychange", () => {
    if (!state.page) return;
    if (document.hidden) { stopPolling(); setLive("paused"); } else { poll(); pollCounts(); }
  });

  async function render() {
    stopPolling();
    const path = location.pathname.replace(/\/+$/, "") || "/admin";
    const app = document.getElementById("app");
    if (path === "/admin/login") { state.page = null; renderLogin(app); return; }
    if (!state.session) {
      fill(app, h("div", { class: "loading" }, h("div", { class: "spinner" })));
      try {
        state.session = await call("GET", "/admin/api/session");
      } catch (error) {
        if (error.status !== 401) fill(app, h("div", { class: "loading", text: error.message }));
        return;
      }
    }
    if (!(path in PAGES)) { go("/admin/documents", true); return; }
    renderShell(app, path);
  }

  // ---------- Sign-in ----------

  function renderLogin(app) {
    const input = h("input", { class: "field mono", type: "password", id: "token", autocomplete: "current-password",
      placeholder: "Paste the admin token", spellcheck: "false", autofocus: true });
    const toggle = iconButton("eye", "Show the token", () => {
      const shown = input.type === "text";
      input.type = shown ? "password" : "text";
      toggle.replaceChildren(icon(shown ? "eye" : "eyeOff", 17));
    });
    const error = h("div", {});
    const button = h("button", { class: "btn primary wide", type: "submit" }, "Sign in");
    const form = h("form", { class: "form", onsubmit: async (event) => {
      event.preventDefault();
      const token = input.value.trim();
      if (!token) { input.focus(); return; }
      button.disabled = true;
      fill(button, h("span", { class: "spinner" }), "Signing in…");
      fill(error);
      try {
        await call("POST", "/admin/login", { token });
        state.session = null;
        const next = new URLSearchParams(location.search).get("next");
        go(next && next in PAGES ? next : "/admin/documents", true);
      } catch (failure) {
        fill(error, h("div", { class: "error", text: failure.status === 403
          ? "That token is not an admin token. Only an admin token signs in to the console."
          : failure.message }));
        button.disabled = false;
        fill(button, "Sign in");
        input.select();
      }
    } },
      h("div", {}, h("label", { class: "label", for: "token", text: "Admin token" }),
        h("div", { class: "reveal" }, input, toggle)),
      error,
      button);
    fill(app, h("div", { class: "login" },
      h("div", { class: "login-card" },
        h("img", { class: "login-logo", src: "/admin/assets/icon.png", alt: "" }),
        h("h1", { text: "ByteRipper Server" }),
        h("p", { class: "lead", text: "Sign in to the console with an admin token." }),
        form,
        h("div", { class: "login-foot" }, "No admin token yet? Make one on the server:",
          h("code", { text: "byteripper-server token add --name admin --rights admin" })))));
    input.focus();
  }

  // ---------- The shell ----------

  function renderShell(app, path) {
    closeLog();
    closeDetail();
    const page = PAGES[path];
    const name = state.session.name || "admin";
    state.counts = {};
    const nav = h("nav", { class: "nav" }, Object.entries(PAGES).map(([target, info]) =>
      h("a", { href: target, class: target === path ? "active" : "", onclick: (event) => { event.preventDefault(); go(target); } },
        icon(info.icon), h("span", { class: "nav-label", text: info.title }),
        info.count ? (state.counts[info.count] = h("span", { class: "count" })) : null)));
    const live = h("span", { class: "live" }, h("span", { class: "dot" }), h("span", { text: "Live" }));
    const actions = h("div", { class: "topbar-actions" });
    const content = h("div", { class: "stack" }, h("div", { class: "loading" }, h("div", { class: "spinner" })));
    fill(app, h("div", { class: "shell" },
      h("aside", { class: "sidebar" },
        h("div", { class: "brand" },
          h("img", { src: "/admin/assets/icon.png", alt: "" }),
          h("div", { class: "brand-text" }, h("div", { class: "brand-name", text: "ByteRipper" }), h("div", { class: "brand-sub", text: "Server console" }))),
        nav,
        h("div", { class: "sidebar-foot" },
          h("div", { class: "who" },
            h("div", { class: "avatar", text: name.slice(0, 1).toUpperCase() }),
            h("div", { class: "who-text" }, h("div", { class: "who-name", text: name }), h("div", { class: "who-role", text: "admin token" }))),
          h("button", { class: "btn ghost small", type: "button", onclick: signOut }, icon("logout", 16), h("span", { class: "who-text", text: "Sign out" })))),
      h("main", { class: "main" },
        h("div", { class: "topbar" },
          h("div", {}, h("h1", { text: page.title }), h("p", { text: page.subtitle })),
          h("div", { class: "topbar-actions" }, actions, live)),
        content)));
    document.title = `${page.title} · ByteRipper Server`;
    state.live = live;
    const view = page.mount(actions);
    state.page = { endpoint: page.endpoint, view, content, first: true, interval: page.interval || POLL_MS };
    poll();
    pollCounts();
  }

  // The sidebar's counts, asked every ten seconds on any page: the documents
  // open (and, dimmed, those whose file is missing), the reports not yet
  // resolved, and the review tickets not yet closed — open (a remark
  // waits) and settled (every remark verified, the close still to do). A count
  // whose endpoint does not answer — no Ghidra role — stays empty.
  async function pollCounts() {
    clearTimeout(state.countTimer);
    state.countTimer = null;
    const counts = state.counts;
    const [status, issues, tickets] = await Promise.allSettled([
      call("GET", "/admin/api/status"), call("GET", "/admin/api/issues"), call("GET", "/admin/api/tickets")]);
    if (state.counts !== counts) return;
    const show = (key, value, hot, extra) => {
      const el = counts[key];
      if (!el) return;
      el.className = `count${hot && value > 0 ? " hot" : ""}`;
      fill(el, value === null ? "" : String(value),
        extra ? h("span", { class: "count-extra", title: `${extra} missing on disk`, text: ` +${extra}` }) : null);
    };
    const docs = status.status === "fulfilled" && status.value && status.value.documents;
    show("documents", docs ? docs.open : null, false, docs && docs.missing ? docs.missing : 0);
    show("issues", issues.status === "fulfilled" && Array.isArray(issues.value)
      ? issues.value.filter((issue) => !issue.resolved).length : null, true);
    const board = tickets.status === "fulfilled" && Array.isArray(tickets.value) ? tickets.value : null;
    const waiting = board ? board.filter((ticket) => ticket.state === "open").length : 0;
    const settled = board ? board.filter((ticket) => ticket.state === "settled").length : 0;
    show("tickets", board ? waiting + settled : null, true);
    if (counts.tickets) counts.tickets.title = board ? `${waiting} open, ${settled} settled` : "";
    if (state.counts === counts && state.session && !document.hidden) state.countTimer = setTimeout(pollCounts, 10000);
  }

  async function signOut() {
    try { await call("POST", "/admin/logout"); } catch { /* signed out either way */ }
    state.session = null;
    stopPolling();
    go("/admin/login", true);
  }

  function setLive(mode) {
    if (!state.live) return;
    state.live.className = `live ${mode === "live" ? "" : mode}`;
    state.live.lastChild.textContent = mode === "live" ? "Live" : mode === "paused" ? "Paused" : "Reconnecting…";
  }

  function stopPolling() {
    clearTimeout(state.timer);
    state.timer = null;
    clearTimeout(state.countTimer);
    state.countTimer = null;
  }

  // Asks the page's endpoint now, and again in two seconds.
  async function poll() {
    stopPolling();
    const page = state.page;
    if (!page) return;
    try {
      const data = await call("GET", page.endpoint);
      if (state.page !== page) return;
      if (page.first) { fill(page.content, page.view.root); page.first = false; }
      page.view.update(data);
      setLive("live");
    } catch (error) {
      if (error.status === 401 || state.page !== page) return;
      setLive("down");
    }
    if (state.page === page && !document.hidden) state.timer = setTimeout(poll, page.interval || POLL_MS);
  }

  function refresh() { if (state.page) poll(); }

  // ---------- Pieces ----------

  function tile(iconName, label) {
    const value = h("div", { class: "tile-value" });
    const foot = h("div", { class: "tile-foot" });
    const bar = h("span", {});
    const meter = h("div", { class: "meter" }, bar);
    const root = h("div", { class: "tile" }, h("div", { class: "tile-label" }, icon(iconName, 15), label), value, foot);
    return {
      root,
      set(main, unit, footText, share) {
        fill(value, main, unit ? h("small", { text: unit }) : null);
        fill(foot, footText || "");
        if (share === undefined) { meter.remove(); return; }
        if (!meter.isConnected) root.insertBefore(meter, foot);
        bar.style.width = `${Math.min(100, Math.round(share * 100))}%`;
        meter.className = `meter ${share >= 1 ? "full" : share >= 0.8 ? "warn" : ""}`;
      },
    };
  }

  function card(title, sub, ...rest) {
    const body = h("div", { class: "card-body flush" });
    const head = h("div", { class: "card-head" }, h("h2", {}, title, sub ? h("span", { class: "sub", text: sub }) : null));
    return { root: h("section", { class: "card" }, head, ...rest, body), body, head };
  }

  function empty(iconName, title, text, ...more) {
    return h("div", { class: "empty" }, h("div", { class: "empty-icon" }, icon(iconName, 26)),
      h("h3", { text: title }), h("p", { text }), ...more);
  }

  function copyLine(text, what) {
    return h("div", { class: "copyline" }, h("span", { text, title: text }), iconButton("copy", `Copy ${what}`, () => copy(text, what)));
  }

  async function act(run, done) {
    try {
      const result = await run();
      if (done) toast(typeof done === "function" ? done(result) : done, "ok");
      refresh();
      return result;
    } catch (error) {
      if (error.status !== 401) toast(error.message, "error");
      return undefined;
    }
  }

  // ---------- Documents ----------

  function mountDocuments() {
    const openTile = tile("chip", "Open");
    const bytesTile = tile("layers", "Snapshots");
    const missingTile = tile("alert", "Missing");
    const rootsTile = tile("folder", "Dump roots");

    // Adding: picked in the dump roots, or uploaded.
    const browser = fileBrowser();
    const byPath = browser.root;

    const fileInput = h("input", { type: "file", hidden: true });
    const limitText = h("span", {});
    const progress = h("div", {});
    const drop = h("div", { class: "drop", tabindex: "0", role: "button", onclick: () => fileInput.click(),
      onkeydown: (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); fileInput.click(); } } },
      h("div", { class: "drop-icon" }, icon("upload", 22)),
      h("div", {}, h("strong", { text: "Drop a dump here" }), " or click to choose one"),
      h("div", { class: "hint" }, "Kept in Uploads under its SHA-256 and opened at once · ", limitText));
    let uploading = false;
    async function send(file) {
      if (!file || uploading) return;
      uploading = true;
      const bar = h("span", {});
      const percent = h("span", { text: "0%" });
      fill(progress, h("div", { class: "progress" },
        h("div", { class: "progress-label" }, h("span", { text: `Uploading ${file.name} · ${bytes(file.size)}` }), percent),
        h("div", { class: "meter" }, bar)));
      try {
        const made = await upload(file, file.name, (share) => {
          bar.style.width = `${Math.round(share * 100)}%`;
          percent.textContent = `${Math.round(share * 100)}%`;
        });
        toast(`${file.name} is ${made.id}`, "ok");
        refresh();
      } catch (error) {
        if (error.status !== 401) toast(error.message, "error");
      } finally {
        uploading = false;
        fill(progress);
        fileInput.value = "";
      }
    }
    fileInput.addEventListener("change", () => send(fileInput.files[0]));
    drop.addEventListener("dragover", (event) => { event.preventDefault(); drop.classList.add("over"); });
    drop.addEventListener("dragleave", () => drop.classList.remove("over"));
    drop.addEventListener("drop", (event) => {
      event.preventDefault();
      drop.classList.remove("over");
      send(event.dataTransfer.files[0]);
    });
    const byUpload = h("div", {}, drop, fileInput, progress);
    byUpload.hidden = true;

    const tabs = h("div", { class: "seg" });
    const showTab = (which) => {
      byPath.hidden = which !== "path";
      byUpload.hidden = which !== "upload";
      [...tabs.children].forEach((button) => button.classList.toggle("on", button.dataset.tab === which));
    };
    append(tabs, [
      h("button", { type: "button", "data-tab": "path", class: "on", onclick: () => showTab("path") }, "Dump roots"),
      h("button", { type: "button", "data-tab": "upload", onclick: () => showTab("upload") }, "Upload"),
    ]);
    const adding = h("section", { class: "card" },
      h("div", { class: "card-head" }, h("h2", {}, "Add a dump", h("span", { class: "sub", text: "only the operator changes the set" })), tabs),
      h("div", { class: "card-body" }, byPath, byUpload));

    const list = card("Documents", "ids last across restarts and are never given to another file");

    const root = h("div", { class: "stack" },
      h("div", { class: "grid tiles" }, openTile.root, bytesTile.root, missingTile.root, rootsTile.root),
      adding,
      list.root);

    function update(data) {
      const docs = data.documents;
      const missing = docs.filter((doc) => doc.state === "missing").length;
      openTile.set(String(data.used.documents), `/ ${data.limits.documents}`, "documents served now",
        data.used.documents / data.limits.documents);
      bytesTile.set(bytes(data.used.bytes), `/ ${bytes(data.limits.open_bytes)}`, "held in memory, read whole at open",
        data.used.bytes / data.limits.open_bytes);
      missingTile.set(String(missing), null, missing ? "ids held, nothing served" : "every row is served");
      const present = data.roots.filter((r) => r.present).length;
      rootsTile.set(String(present), `/ ${data.roots.length}`, data.roots.length ? "present now" : "none: uploads only");
      limitText.textContent = `at most ${bytes(data.limits.upload_bytes)}`;

      // The browser marks the files already held: read again when the set
      // changes, not at every poll.
      browser.documentsChanged(docs.map((doc) => `${doc.id}:${doc.state}`).join(","));

      list.head.querySelector(".sub").textContent = docs.length
        ? `${docs.length - missing} served${missing ? ` · ${missing} missing` : ""} · ids last across restarts`
        : "ids last across restarts and are never given to another file";
      if (!docs.length) {
        fill(list.body, empty("chip", "No dumps yet", "Open one from a dump root, or upload one. An agent sees it in its documents at once."));
        return;
      }
      const rows = docs.map((doc, index) => documentRow(doc, index, docs));
      fill(list.body, h("div", { class: "table-wrap" }, h("table", {},
        h("thead", {}, h("tr", {},
          h("th", { text: "Order" }), h("th", { text: "Document" }), h("th", { text: "Id" }),
          h("th", { class: "num", text: "Size" }), h("th", { class: "num", text: "Version" }),
          h("th", { text: "State" }), h("th", {}))),
        h("tbody", {}, rows))));
    }
    return { root, update };
  }

  // The folders under --dump-roots: the roots at the top, a folder's folders
  // and files below, a file opened with a click. Nothing outside the roots
  // is listed; the server checks every step again.
  function fileBrowser() {
    const STORE = "byteripper.console.folder";
    let listing = null;
    let current = null;
    let documents = null;
    let query = "";
    const crumbs = h("nav", { class: "crumbs", "aria-label": "Folder" });
    const filter = h("input", { class: "field filter", type: "search", placeholder: "Filter this folder", spellcheck: "false",
      oninput: () => { query = filter.value.trim().toLowerCase(); draw(); } });
    const list = h("div", { class: "browser-list" });
    const foot = h("div", { class: "browser-foot" });
    const root = h("div", { class: "browser" },
      h("div", { class: "browser-bar" }, crumbs,
        iconButton("refresh", "Read the folder again", () => load(current, true)), filter),
      list, foot);

    function remember(path) {
      try { if (path) localStorage.setItem(STORE, path); else localStorage.removeItem(STORE); } catch { /* no storage */ }
    }

    async function load(path, keepFilter = false) {
      try {
        listing = await call("GET", `/admin/api/browse${path ? `?path=${encodeURIComponent(path)}` : ""}`);
      } catch (error) {
        if (error.status === 401) return;
        // A folder that went, or a root narrowed since: back to the top.
        if (path) { remember(null); return load(null); }
        fill(list, empty("alert", "The roots cannot be read", error.message));
        return;
      }
      current = listing.path || null;
      remember(current);
      if (!keepFilter) { filter.value = ""; query = ""; }
      draw();
    }

    function crumb(label, path, title) {
      return h("button", { class: "crumb", type: "button", title: title || label, onclick: () => load(path) }, label);
    }

    function draw() {
      const parts = [crumb("Dump roots", null)];
      if (listing.root) {
        const rootName = listing.root.split("/").filter(Boolean).pop() || "/";
        parts.push(h("span", { class: "crumb-sep", text: "›" }), crumb(rootName, listing.root, listing.root));
        const rest = listing.path.slice(listing.root.length).split("/").filter(Boolean);
        rest.forEach((segment, index) => {
          const path = `${listing.root}/${rest.slice(0, index + 1).join("/")}`;
          parts.push(h("span", { class: "crumb-sep", text: "›" }), crumb(segment, path, path));
        });
      }
      fill(crumbs, parts);
      filter.hidden = !listing.path;

      const entries = listing.entries.filter((e) => !query || e.name.toLowerCase().includes(query));
      const rows = [];
      if (listing.path) {
        rows.push(h("button", { class: "entry folder up", type: "button", onclick: () => load(listing.parent || null) },
          h("span", { class: "entry-icon" }, icon("up", 16)),
          h("span", { class: "entry-name", text: listing.parent ? "Up" : "Dump roots" }),
          h("span", {}), h("span", {}), h("span", {})));
      }
      for (const entry of entries) rows.push(entryRow(entry));
      if (!listing.entries.length) {
        fill(list, ...rows, listing.path
          ? h("div", { class: "browser-empty", text: "Nothing to open here: no folders and no files." })
          : empty("folder", "No dump roots", "Start the server with --dump-roots <folder> to browse it here. Uploads work without one."));
      } else if (!entries.length) {
        fill(list, ...rows, h("div", { class: "browser-empty", text: `Nothing here matches “${filter.value}”.` }));
      } else {
        fill(list, rows);
      }
      const folders = listing.entries.filter((e) => e.kind === "folder").length;
      const files = listing.entries.filter((e) => e.kind === "file").length;
      fill(foot, listing.path
        ? `${plural(folders, "folder", "folders")} · ${plural(files, "file", "files")}${listing.truncated ? " · the first 2000 only" : ""}`
        : "A file opens under its own name; its id lasts across restarts.");
    }

    function entryRow(entry) {
      const off = Boolean(entry.unavailable);
      const meta = (text) => h("span", { class: "entry-meta", text });
      if (entry.kind !== "file") {
        return h("button", { class: `entry folder ${off ? "off" : ""}`, type: "button", disabled: off,
          title: off ? entry.unavailable : entry.path, onclick: () => load(entry.path) },
          h("span", { class: "entry-icon" }, icon(entry.kind === "root" ? (off ? "alert" : "database") : "folder", 16)),
          h("span", { class: `entry-name ${entry.kind === "root" ? "mono" : ""}` }, entry.name,
            off ? h("small", { class: "entry-why", text: entry.unavailable }) : null),
          meta(""),
          meta(entry.modified ? ago(entry.modified) : ""),
          h("span", { class: "entry-go" }, off ? null : icon("down", 14)));
      }
      let action;
      if (off) {
        action = null;
      } else if (entry.document && entry.state === "open") {
        action = h("span", { class: "pill accent", title: "Already served under this id", text: `${entry.document} · open` });
      } else {
        action = h("button", { class: "btn primary small", type: "button", onclick: () => open(entry) },
          entry.document ? `Reopen ${entry.document}` : "Open");
      }
      return h("div", { class: `entry file ${off ? "off" : ""}`, title: entry.path,
        ondblclick: () => { if (!off && !(entry.document && entry.state === "open")) open(entry); } },
        h("span", { class: "entry-icon" }, icon("chip", 16)),
        h("span", { class: "entry-name" }, entry.name,
          off ? h("small", { class: "entry-why", text: entry.unavailable }) : null),
        meta(bytes(entry.size)),
        meta(entry.modified ? ago(entry.modified) : ""),
        h("span", { class: "entry-action" }, action));
    }

    async function open(entry) {
      const made = await act(() => call("POST", "/admin/api/documents", { path: entry.path }),
        (result) => `${entry.name} is ${result.id}`);
      if (made) load(current, true);
    }

    let saved = null;
    try { saved = localStorage.getItem(STORE); } catch { /* no storage */ }
    load(saved);

    return {
      root,
      documentsChanged(fingerprint) {
        if (documents !== null && documents !== fingerprint && listing) load(current, true);
        documents = fingerprint;
      },
    };
  }

  function documentRow(doc, index, docs) {
    const missing = doc.state === "missing";
    const move = (delta) => {
      const ids = docs.map((d) => d.id);
      const [moved] = ids.splice(index, 1);
      ids.splice(index + delta, 0, moved);
      act(() => call("PUT", "/admin/api/documents/order", { ids }));
    };
    let stateCell;
    if (missing) stateCell = h("span", { class: "pill danger", text: "Missing" });
    else if (doc.disk === "changed") stateCell = h("span", { class: "pill warn", title: "The file on disk is no longer the one read; Reopen reads it again", text: "Changed on disk" });
    else if (doc.disk === "gone") stateCell = h("span", { class: "pill danger", title: "The file is not on disk; the snapshot goes on answering", text: "Gone from disk" });
    else stateCell = h("span", { class: "pill ok", text: "Served" });

    const actions = [
      iconButton("refresh", missing ? "Reopen — check the roots and the limits again" : "Reopen — read the file again",
        () => act(() => call("POST", `/admin/api/documents/${doc.id}/reopen`), `${doc.id} read again`)),
    ];
    if (!missing) {
      actions.push(iconButton("x", "Close", async () => {
        const sure = await confirmAction({ title: `Close ${doc.name}?`, label: "Close",
          text: `${doc.id} is retired with it: an agent that still holds it is told it is not served. The file on disk is not touched.` });
        if (sure) act(() => call("POST", `/admin/api/documents/${doc.id}/close`), `${doc.id} closed`);
      }));
    } else {
      actions.push(iconButton("ban", "Forget — retire the id for good", async () => {
        const sure = await confirmAction({ title: `Forget ${doc.id}?`, label: "Forget",
          text: "The row goes and its id is retired with it, not freed. The file, if it is anywhere, is not touched." });
        if (sure) act(() => call("POST", `/admin/api/documents/${doc.id}/forget`), `${doc.id} forgotten`);
      }, "danger"));
    }
    if (doc.uploaded) {
      actions.push(iconButton("trash", "Delete the upload", async () => {
        const sure = await confirmAction({ title: `Delete ${doc.name}?`, label: "Delete", iconName: "trash",
          text: "The document is closed and its copy in Uploads is deleted from the server's disk. This cannot be undone." });
        if (sure) act(() => call("DELETE", `/admin/api/documents/${doc.id}`), `${doc.name} deleted`);
      }, "danger"));
    }

    return h("tr", {},
      h("td", {}, h("div", { class: "row" },
        h("button", { class: "icon-btn", type: "button", title: "Move up", "aria-label": "Move up", disabled: index === 0, onclick: () => move(-1) }, icon("up", 15)),
        h("button", { class: "icon-btn", type: "button", title: "Move down", "aria-label": "Move down", disabled: index === docs.length - 1, onclick: () => move(1) }, icon("down", 15)))),
      h("td", {}, h("div", { class: "doc-name" },
        h("div", { class: `doc-icon ${missing ? "missing" : doc.uploaded ? "upload" : ""}` }, icon(doc.uploaded ? "upload" : "chip", 17)),
        h("div", { class: "grow" },
          h("div", { class: "doc-title", text: doc.name }),
          h("div", { class: "doc-path", title: doc.path, text: tail(doc.uploaded ? `Uploads/${doc.sha256}` : doc.path) }),
          missing ? h("div", { class: "doc-reason", text: doc.reason }) : null))),
      h("td", {}, h("button", { class: "chip", type: "button", title: "Copy the id an agent passes as `document`", onclick: () => copy(doc.id, doc.id) }, doc.id)),
      h("td", { class: "num", text: bytes(doc.size) }),
      h("td", { class: "num" }, h("span", { class: "pill plain", text: `v${doc.version}` })),
      h("td", {}, stateCell),
      h("td", { class: "actions" }, actions));
  }

  // ---------- Activity ----------

  function mountActivity() {
    const modules = card("Modules in work", "one holder at a time writes and publishes a module in Ghidra");
    const closedLeases = h("div", {});
    const agents = card("Local agents", "connections to the local MCP socket, one row each");
    const clients = card("REST clients", "requests per token since the server started; the console's own are not counted");
    const root = h("div", { class: "stack" }, modules.root, closedLeases, agents.root, clients.root);

    function update(data) {
      // A module in work that proposes to replace shared definitions shows
      // its proposal, opened in the sheet as on the Review Tickets page.
      call("GET", "/admin/api/type-proposals").then((rows) => rows, () => []).then((proposals) => {
        for (const p of proposals) updateDetail(`proposal:${p.id}`, proposalTitle(p), () => proposalDetail(p, proposalNames(p)));
        updateLeases(modules, closedLeases, data.leases, proposals.filter((p) => p.state === "open" || p.state === "agreed"));
      });
      if (!data.mcp.length) {
        fill(agents.body, empty("bot", "No local agent is at work",
          "An agent on this machine reaches the server through the relay; it appears here with its first call.",
          h("div", { class: "empty-action" }, h("button", { class: "btn small", type: "button", onclick: () => go("/admin/configuration") },
            icon("sliders", 15), "Agent configuration"))));
      } else {
        fill(agents.body, h("table", { class: "lines" },
          h("thead", {}, h("tr", {},
            h("th", { class: "w-who", text: "Agent" }), h("th", { class: "w-state", text: "State" }),
            h("th", { class: "num w-n", text: "Calls" }), h("th", { class: "num w-n", text: "Errors" }),
            h("th", { class: "w-time", text: "Connected" }), h("th", { text: "Last call" }), h("th", { class: "w-open" }))),
          h("tbody", {}, data.mcp.map(agentLine))));
      }
      if (!data.rest.length) {
        fill(clients.body, empty("globe", "No REST requests yet", "The app and the scripts show up here, one row per token, when they reach the store or Ghidra."));
      } else {
        fill(clients.body, h("table", { class: "lines" },
          h("thead", {}, h("tr", {},
            h("th", { class: "w-who", text: "Token" }), h("th", { class: "w-state", text: "State" }),
            h("th", { class: "num w-n", text: "Requests" }), h("th", { class: "num w-n", text: "Refused" }),
            h("th", { class: "w-time", text: "Last seen" }), h("th", { text: "Last request" }), h("th", { class: "w-open" }))),
          h("tbody", {}, data.rest.map(clientLine))));
      }
      updateLog([...data.mcp.map(agentEntry), ...data.rest.map(clientEntry)]);
    }
    return { root, update };
  }

  function statusPill(code) {
    const kind = code >= 500 ? "danger" : code === 401 || code === 403 ? "danger" : code >= 400 ? "warn" : "ok";
    return h("span", { class: `pill ${kind}`, text: String(code) });
  }

  // ---------- Activity: the call log ----------

  function clockTime(iso) {
    return new Date(iso).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  }

  function elapsed(value) {
    if (value === undefined || value === null) return "";
    return value < 1000 ? `${Math.round(value)} ms` : `${(value / 1000).toFixed(1)} s`;
  }

  // The lamp of a session that is working right now: the Live indicator's
  // colour, blinking at the rate of the app's toolbar dot (`AgentActivityBadge`
  // fades to 0.15 and back every 0.5 s).
  function workingPill(text) {
    return h("span", { class: "pill ok blinking" }, h("span", { text }));
  }

  // A connection at work: Live's pill in red, saying Active, its dot blinking
  // at the rate of the app's toolbar dot (`AgentActivityBadge`). The blink's
  // phase follows the clock, so a card drawn anew every second does not
  // restart it.
  function lamp() {
    const el = h("span", { class: "pill danger blinking", title: "The agent is at work", text: "Active" });
    el.style.setProperty("--phase", `-${Date.now() % 1000}ms`);
    return el;
  }

  function connectionState(row) {
    if (row.active) return lamp();
    return h("span", { class: "pill ok", text: "Live" });
  }

  // A connection by its number and the agent behind it — the Claude Code
  // session's own name — or "Connection" when the client gives none; the
  // client process goes on the line below.
  function connectionTitle(number, agent) {
    return `#${number} ${agent || "Connection"}`;
  }

  // ---------- Activity: one line per local agent and per REST token ----------

  // Who, in a cell: an icon, the name, and below it what the name stands
  // for, each cut short with an ellipsis rather than widening the table.
  function whoCell(iconName, title, sub) {
    return h("td", {}, h("div", { class: "line-who" },
      h("div", { class: "doc-icon" }, icon(iconName, 16)),
      h("div", { class: "line-who-text" },
        h("div", { class: "line-who-title", title, text: title }),
        h("div", { class: "line-who-sub", title: sub, text: sub }))));
  }

  // The last command, in at most two lines; the whole of it is the tooltip.
  function lastCell(text, when, pill) {
    if (!text) return h("td", { class: "muted", text: "—" });
    return h("td", {}, h("div", { class: "last" },
      h("code", { class: "last-text", title: text, text }),
      h("div", { class: "last-meta" }, pill, h("span", { class: "muted", text: when }))));
  }

  function openButton(entry) {
    const count = entry.log.length;
    return h("td", { class: "actions" },
      h("button", { class: "btn small", type: "button", disabled: !count, onclick: () => openLog(entry) },
        icon("scroll", 15), "Open log", count ? h("span", { class: "count-badge", text: String(count) }) : null));
  }

  function agentLine(row) {
    const entry = agentEntry(row);
    const last = entry.log[entry.log.length - 1];
    const summary = last ? [last.tool, argumentSummary(last.arguments)].filter(Boolean).join(" · ") : "";
    return h("tr", { class: row.active ? "at-work" : "" },
      whoCell("bot", entry.title, entry.sub),
      h("td", {}, connectionState(row)),
      h("td", { class: "num", text: row.calls }),
      h("td", { class: `num ${row.errors ? "danger-text" : ""}`, text: row.errors }),
      h("td", { class: "muted", text: duration((Date.now() - Date.parse(row.started)) / 1000) }),
      lastCell(summary, last ? clockTime(last.started) : "", last ? outcomePill(last) : null),
      openButton(entry));
  }

  function clientLine(row) {
    const entry = clientEntry(row);
    return h("tr", {},
      whoCell(row.token ? "key" : "alert", entry.title, entry.sub),
      h("td", {}, entry.working ? workingPill("in flight") : h("span", { class: "pill plain", text: "Idle" })),
      h("td", { class: "num", text: row.requests }),
      h("td", { class: `num ${row.refused ? "danger-text" : ""}`, text: row.refused }),
      h("td", { class: "muted", text: ago(row.last_seen) }),
      lastCell(row.last, "", statusPill(row.last_status)),
      openButton(entry));
  }

  // What the log panel shows, the same for both: a key that survives the
  // next refresh, the head, the counts, and the calls — a REST request made
  // to read as a call, its route the "tool" and its path the arguments.
  function agentEntry(row) {
    return {
      key: `mcp:${row.number}`, kind: "agent", row, icon: "bot",
      title: connectionTitle(row.number, row.agent), sub: row.client || "client not known",
      log: row.log || [], noun: "call",
    };
  }

  function clientEntry(row) {
    const log = (row.log || []).map(requestCall);
    return {
      key: `rest:${row.token || "*"}`, kind: "rest", row, icon: row.token ? "key" : "alert",
      title: row.name, sub: row.token || "requests without an accepted token",
      log, noun: "request", working: log.some((r) => r.running),
    };
  }

  // A route by its shape: a SHA-256, a UUID or a number in the path becomes
  // a placeholder, so the filter offers "GET /ghidra/v1/live/:sha", not one
  // entry per module.
  function route(path) {
    return (path || "").split("?")[0].split("/").map((part) =>
      /^[0-9a-f]{32,}$/i.test(part) ? ":sha"
        : /^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(part) ? ":id"
          : /^(0x)?[0-9a-f]{5,}$/i.test(part) && /\d/.test(part) ? ":n" : part).join("/");
  }

  function requestCall(request) {
    const status = request.status || 0;
    return {
      id: request.id, rest: true, started: request.started, finished: request.finished,
      running: request.running, duration_ms: request.duration_ms, status, peer: request.peer,
      tool: `${request.method} ${route(request.path)}`, arguments: request.path,
      outcome: request.running ? "running" : status >= 400 ? "error" : "answered",
      detail: status >= 400 ? `HTTP ${status}` : null,
      request: { method: request.method, path: request.path, status: status || null, peer: request.peer || null },
    };
  }

  // ---------- The log panel ----------

  // A connection's calls in a panel from the right, like a browser's network
  // view: the list, newest first, a search, filters, Live tail — off, the list
  // holds still to be read and counts what came since — and a selected call's
  // arguments, answer and error below it.
  const log = {
    key: null, row: null, frozen: null, selected: null,
    query: "", outcome: "all", tool: "", tail: true, root: null, parts: null,
  };

  function buildLog() {
    const search = h("input", { class: "field", type: "search", placeholder: "Search tools and arguments", spellcheck: "false",
      oninput: () => { log.query = search.value.trim().toLowerCase(); drawLog(); } });
    const outcomes = h("div", { class: "seg" }, [["all", "All"], ["errors", "Errors"], ["running", "Running"]].map(([id, label]) =>
      h("button", { type: "button", "data-outcome": id, class: id === "all" ? "on" : "",
        onclick: () => { log.outcome = id; drawLog(); } }, label)));
    const tools = h("select", { class: "field select", "aria-label": "Tool",
      onchange: () => { log.tool = tools.value; drawLog(); } });
    const tail = h("button", { class: "btn small tail on", type: "button", onclick: () => setTail(!log.tail) });
    const head = h("div", { class: "drawer-head" });
    const stats = h("div", { class: "drawer-stats" });
    const banner = h("div", { class: "drawer-banner" });
    const list = h("div", { class: "drawer-list", role: "listbox", "aria-label": "Calls", tabindex: "0",
      onkeydown: (event) => {
        if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
        event.preventDefault();
        const calls = visibleCalls();
        const at = calls.findIndex((c) => c.id === log.selected);
        const next = calls[Math.max(0, Math.min(calls.length - 1, at + (event.key === "ArrowDown" ? 1 : -1)))];
        if (next) { log.selected = next.id; drawLog(); }
      } });
    const detail = h("div", { class: "drawer-detail" });
    const panel = h("aside", { class: "drawer", role: "dialog", "aria-label": "Activity log" },
      head, stats,
      h("div", { class: "drawer-tools" },
        h("div", { class: "search" }, icon("search", 15), search), outcomes, tools, tail),
      banner, list, detail);
    const backdrop = h("div", { class: "drawer-backdrop", onclick: closeLog });
    document.body.append(backdrop, panel);
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && log.key !== null && !document.querySelector("dialog[open]")) closeLog();
    });
    log.root = { panel, backdrop };
    log.parts = { search, outcomes, tools, tail, head, stats, banner, list, detail };
  }

  function openLog(entry) {
    if (!log.root) buildLog();
    Object.assign(log, { key: entry.key, row: entry, frozen: null, selected: null, query: "", outcome: "all", tool: "", tail: true });
    log.parts.search.value = "";
    setTail(true);
    log.root.panel.classList.add("open");
    log.root.backdrop.classList.add("open");
    drawLog();
    setTimeout(() => log.parts.list.focus(), 50);
  }

  function closeLog() {
    if (!log.root || log.key === null) return;
    log.key = null;
    log.root.panel.classList.remove("open");
    log.root.backdrop.classList.remove("open");
  }

  function setTail(on) {
    log.tail = on;
    log.frozen = on ? null : (log.row ? (log.row.log || []).slice() : []);
    const button = log.parts.tail;
    button.classList.toggle("on", on);
    fill(button, icon(on ? "pause" : "play", 14), on ? "Live tail" : "Paused");
    button.title = on ? "New calls come in as they happen; pause to read" : "The list holds still; resume to see the calls since";
    drawLog();
  }

  function updateLog(entries) {
    if (log.key === null) return;
    const entry = entries.find((e) => e.key === log.key);
    if (entry) log.row = entry;
    else if (log.row) log.row = Object.assign({}, log.row, { gone: true, row: Object.assign({}, log.row.row, { open: false, active: false }) });
    drawLog();
  }

  function visibleCalls() {
    const all = (log.tail ? (log.row.log || []) : log.frozen).slice().reverse();
    return all.filter((call) => {
      if (log.outcome === "errors" && !(call.outcome === "error" || call.outcome === "over bound")) return false;
      if (log.outcome === "running" && !call.running) return false;
      if (log.tool && call.tool !== log.tool) return false;
      if (log.query && !`${call.tool} ${call.arguments || ""} ${call.detail || ""}`.toLowerCase().includes(log.query)) return false;
      return true;
    });
  }

  // The few arguments that say what a call was about, in a line.
  function argumentSummary(text) {
    if (!text) return "";
    let value;
    try { value = JSON.parse(text); } catch { return text; }
    if (!value || typeof value !== "object") return String(value);
    const first = ["document", "node", "module", "function", "address", "offset", "what", "text", "hex", "name", "search"];
    const keys = Object.keys(value).sort((a, b) => {
      const x = first.indexOf(a); const y = first.indexOf(b);
      return (x < 0 ? 99 : x) - (y < 0 ? 99 : y);
    });
    return keys.slice(0, 4).map((key) => {
      let shown = typeof value[key] === "string" ? value[key] : JSON.stringify(value[key]);
      if (shown.length > 28) shown = `${shown.slice(0, 27)}…`;
      return `${key} ${shown}`;
    }).join(" · ") + (keys.length > 4 ? " · …" : "");
  }

  function outcomePill(call) {
    if (call.rest && !call.running) return statusPill(call.status);
    if (call.running) return h("span", { class: "pill ok blinking", text: "running" });
    const kind = call.outcome === "answered" ? "ok" : call.outcome === "cancelled" ? "plain" : "danger";
    return h("span", { class: `pill ${kind}`, text: call.outcome });
  }

  function drawLog() {
    if (log.key === null || !log.row) return;
    const entry = log.row;
    const row = entry.row;
    const parts = log.parts;
    const end = Date.now();
    const rest = entry.kind === "rest";
    fill(parts.head,
      h("div", { class: "agent-badge" }, icon(entry.icon, 18)),
      h("div", { class: "grow" }, h("div", { class: "agent-title", text: entry.title }),
        h("div", { class: "agent-sub", text: entry.sub })),
      rest ? (entry.working ? workingPill("in flight") : h("span", { class: "pill plain", text: "Idle" })) : connectionState(row),
      iconButton("x", "Close the log", closeLog));
    fill(parts.stats, rest ? [
      h("span", {}, h("b", { text: row.requests }), " requests"),
      h("span", {}, h("b", { class: row.refused ? "danger-text" : "", text: row.refused }), " refused"),
      h("span", {}, "last seen ", h("b", { text: ago(row.last_seen) })),
      h("span", { class: "muted", text: "the last 50 requests are kept, in memory only" }),
    ] : [
      h("span", {}, h("b", { text: row.calls }), " calls"),
      h("span", {}, h("b", { class: row.errors ? "danger-text" : "", text: row.errors }), " errors"),
      h("span", {}, h("b", { text: duration((end - Date.parse(row.started)) / 1000) }), " connected"),
      h("span", { class: "muted", text: "the last 50 calls are kept, in memory only" }),
    ]);
    parts.search.placeholder = rest ? "Search routes and paths" : "Search tools and arguments";

    [...parts.outcomes.children].forEach((b) => b.classList.toggle("on", b.dataset.outcome === log.outcome));
    const toolNames = [...new Set(entry.log.map((c) => c.tool))].sort();
    const options = [h("option", { value: "", text: rest ? "All routes" : "All tools" }), ...toolNames.map((t) => h("option", { value: t, text: t }))];
    if (parts.tools.options.length !== options.length || [...parts.tools.options].some((o, i) => o.value !== options[i].value)) {
      fill(parts.tools, options);
    }
    parts.tools.value = toolNames.includes(log.tool) ? log.tool : "";

    const since = log.tail ? 0 : Math.max(0, entry.log.filter((c) => !log.frozen.some((f) => f.id === c.id)).length);
    fill(parts.banner, !log.tail
      ? h("div", { class: "paused" }, icon("pause", 14),
        since ? `${since} new ${entry.noun}${since === 1 ? "" : "s"} since you paused` : "Paused: the list holds still",
        h("button", { class: "btn small", type: "button", onclick: () => setTail(true) }, icon("play", 13), "Resume"))
      : null);

    const calls = visibleCalls();
    const longest = Math.max(1, ...calls.map((c) => c.duration_ms || 0));
    if (!calls.find((c) => c.id === log.selected)) log.selected = calls.length ? calls[0].id : null;
    const scroll = parts.list.scrollTop;
    fill(parts.list,
      h("div", { class: "drawer-row drawer-columns" },
        h("span", { text: "Time" }), h("span", { text: rest ? "Route" : "Tool" }), h("span", { text: rest ? "Path" : "Arguments" }),
        h("span", { class: "num", text: "Duration" }), h("span", { class: "num", text: rest ? "" : "Answer" }), h("span", { text: "" })),
      calls.length ? calls.map((call) => h("div", {
        class: `drawer-row ${call.id === log.selected ? "selected" : ""} ${call.running ? "running" : ""}`,
        role: "option", "aria-selected": call.id === log.selected ? "true" : "false",
        onclick: () => { log.selected = call.id; drawLog(); },
      },
        h("span", { class: "log-time", text: clockTime(call.started) }),
        h("code", { class: "log-name", title: call.tool, text: call.tool }),
        h("span", { class: "drawer-args", title: call.arguments || "", text: rest ? call.arguments : argumentSummary(call.arguments) }),
        h("span", { class: "drawer-ms" },
          h("span", { class: "ms-bar" }, call.running ? null : (() => {
            const bar = h("span", {});
            bar.style.width = `${Math.max(3, Math.round(((call.duration_ms || 0) / longest) * 100))}%`;
            return bar;
          })()),
          h("span", { text: call.running ? "…" : elapsed(call.duration_ms) })),
        h("span", { class: "num muted", text: call.answer_bytes !== undefined ? bytes(call.answer_bytes) : "" }),
        outcomePill(call)))
        : h("div", { class: "browser-empty", text: entry.log.length ? `No ${entry.noun} matches.` : `No ${entry.noun} yet.` }));
    parts.list.scrollTop = scroll;

    const call = calls.find((c) => c.id === log.selected);
    if (!call) { fill(parts.detail); parts.detail.hidden = true; return; }
    parts.detail.hidden = false;
    let pretty = call.arguments || "{}";
    if (rest) pretty = JSON.stringify(call.request, null, 2);
    else try { pretty = JSON.stringify(JSON.parse(pretty), null, 2); } catch { /* cut short: shown as it is */ }
    fill(parts.detail,
      h("div", { class: "detail-head" },
        h("code", { class: "detail-tool", text: call.tool }), outcomePill(call),
        h("span", { class: "muted small", text: `${clockTime(call.started)} · ${call.running ? "running" : elapsed(call.duration_ms)}${call.answer_bytes !== undefined ? ` · ${bytes(call.answer_bytes)} answered` : ""}` })),
      call.detail ? h("div", { class: "detail-error" }, icon("alert", 15), h("span", { text: call.detail })) : null,
      h("div", { class: "codeblock" },
        h("div", { class: "codebar" }, h("span", { class: "codebar-title" }, icon("braces", 14), rest ? "Request" : "Arguments"),
          h("button", { class: "btn small", type: "button", onclick: () => copy(pretty, rest ? "the request" : "the arguments") }, icon("copy", 14), "Copy")),
        h("pre", { class: "code", text: pretty })));
  }

  // ---------- Tokens ----------

  // ---------- The detail sheet ----------

  // A record's whole detail — a report, a ticket, a proposal — in a large
  // sheet over the content area, opened by a click on its row. The page's
  // poll draws it again from the rows it reads, so it stays live; Esc, the
  // close button or a click beside it closes it.
  let detailRoot = null;

  function openDetail(key, title, build) {
    state.detail = { key, title, build };
    if (!detailRoot) {
      const body = h("div", { class: "sheet-body" });
      const heading = h("h3", {});
      const panel = h("div", { class: "sheet", role: "dialog", "aria-modal": "true" },
        h("div", { class: "sheet-head" }, heading, h("span", { class: "grow" }),
          iconButton("x", "Close", closeDetail)),
        body);
      detailRoot = h("div", { class: "sheet-backdrop", onclick: (event) => { if (event.target === detailRoot) closeDetail(); } }, panel);
      detailRoot.heading = heading;
      detailRoot.body = body;
      document.body.append(detailRoot);
      placeDetail();
    }
    drawDetail(true);
    markDetailRows();
  }

  function drawDetail(top) {
    if (!detailRoot || !state.detail) return;
    const body = detailRoot.body;
    const scroll = top ? 0 : body.scrollTop;
    detailRoot.heading.textContent = state.detail.title;
    fill(body, state.detail.build());
    body.scrollTop = scroll;
  }

  // A page drew its rows again: the open record is drawn from them, if it is
  // still among them.
  function updateDetail(key, title, build) {
    if (!state.detail || state.detail.key !== key) return;
    state.detail = { key, title, build };
    drawDetail(false);
  }

  function closeDetail() {
    state.detail = null;
    if (detailRoot) { detailRoot.remove(); detailRoot = null; }
    markDetailRows();
  }

  // The sheet covers the content area, not the sidebar.
  function placeDetail() {
    if (!detailRoot) return;
    const main = document.querySelector("main.main");
    detailRoot.style.left = `${main ? main.getBoundingClientRect().left : 0}px`;
  }

  function markDetailRows() {
    for (const row of document.querySelectorAll("tr[data-detail]")) {
      row.classList.toggle("selected", !!state.detail && row.dataset.detail === state.detail.key);
    }
  }

  // A row that opens its record: a click anywhere on it but on a control.
  function detailRow(key, title, build, props, ...cells) {
    if (state.detail && state.detail.key === key) queueMicrotask(() => updateDetail(key, title, build));
    const row = h("tr", { ...props, class: `${props.class || ""} opens${state.detail && state.detail.key === key ? " selected" : ""}`,
      "data-detail": key,
      onclick: (event) => {
        if (event.target.closest("button, a, input, select, label")) return;
        openDetail(key, title, build);
      } }, ...cells);
    return row;
  }

  window.addEventListener("resize", placeDetail);
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && detailRoot && !document.querySelector("dialog[open]")) closeDetail();
  });

  // ---------- Issues ----------

  function mountIssues(actions) {
    const toggle = h("label", { class: "check" },
      h("input", { type: "checkbox", checked: state.resolvedIssues, onchange: (e) => { state.resolvedIssues = e.target.checked; refresh(); } }),
      "Show resolved");
    append(actions, toggle);
    const open = card("Reports", "newest first");
    const root = h("div", { class: "stack" }, open.root);

    function update(issues) {
      const shown = issues.filter((issue) => state.resolvedIssues || !issue.resolved);
      for (const issue of issues) updateDetail(`issue:${issue.id}`, `Report on ${issue.tool}`, () => issueDetail(issue));
      fill(open.body, shown.length ? issueList(shown)
        : empty("check", "No open report", "An agent reports a problem with a tool through ghidra_report_issue; it is listed here."));
    }
    return { root, update };
  }

  function issueList(issues) {
    return h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {},
        h("th", { text: "Reported" }), h("th", { text: "By" }), h("th", { text: "Tool" }), h("th", { text: "Expected" }), h("th", {}))),
      h("tbody", {}, issues.map((issue) => {
        return detailRow(`issue:${issue.id}`, `Report on ${issue.tool}`, () => issueDetail(issue), { class: issue.resolved ? "dim" : "" },
          h("td", { class: "muted", title: when(issue.at), text: ago(issue.at) }),
          h("td", { text: issue.reporter }),
          h("td", {}, h("code", { text: issue.tool })),
          h("td", { text: issue.expected.length > 140 ? issue.expected.slice(0, 140) + "…" : issue.expected }),
          h("td", { class: "actions" },
            issue.resolved ? h("span", { class: "pill", title: `${issue.resolved.by}, ${when(issue.resolved.at)}`, text: "Resolved" })
              : iconButton("check", "Mark resolved", () => resolveIssue(issue))));
      }))));
  }

  function issueDetail(issue) {
    const part = (label, text) => text ? h("div", { class: "issue-part" }, h("h4", { text: label }), h("pre", { class: "code", text })) : null;
    return h("div", { class: "stack" },
      h("div", { class: "sheet-status" },
        h("span", { class: `pill ${issue.resolved ? "ok" : "danger"}`, text: issue.resolved ? "resolved" : "open" }),
        h("span", { class: "muted", text: `Reported by ${issue.reporter}, ${when(issue.at)}` }),
        h("span", { class: "grow" }),
        decisionButton(issue.resolved ? "Resolved" : "Mark resolved", "check", "", !!issue.resolved, !!issue.resolved,
          () => resolveIssue(issue))),
      issue.module ? h("div", { class: "muted", text: `Module ${issue.module}` }) : null,
      part("Arguments", issue.arguments), part("Answer", issue.answer), part("Expected", issue.expected),
      part("Note", issue.note),
      issue.resolved ? part(`Resolved by ${issue.resolved.by}, ${when(issue.resolved.at)}`, issue.resolved.note || "—") : null);
  }

  async function resolveIssue(issue) {
    const note = h("input", { class: "field", placeholder: "The answer the reporter reads: what was fixed and in which build, or why nothing changes", autocomplete: "off" });
    const done = await dialog({
      icon: "check", tone: "ok", title: `Resolve the report on ${issue.tool}?`,
      text: "It leaves the open list; the reporter reads the answer with ghidra_issues. An answer is required.",
      body: note,
      actions: [{ label: "Cancel", kind: "ghost", value: false }, { label: "Resolve", kind: "primary", value: true, focus: true }],
    });
    if (!done) return;
    await act(() => call("POST", `/admin/api/issues/${issue.id}/resolve`, { note: note.value.trim() || null }), "Report resolved");
  }

  // ---------- Tickets ----------

  // The review board: one ticket per module. A row says where the module's
  // review stands; opened, it shows every remark with its thread, and the
  // administrator's say over a remark's status or the whole ticket.
  const TICKET_STATES = [["open", "Open"], ["settled", "Settled"], ["closed", "Closed"], ["all", "All"]];
  // The same switch sorts the proposals: open waits on votes, settled is
  // agreed and waits on the module's next publish, closed has ended.
  const PROPOSAL_STATES = { open: ["open"], settled: ["agreed"], closed: ["applied", "rejected", "withdrawn"] };
  const REMARK_STATUSES = ["open", "answered", "fixed", "wont_fix", "verified"];

  function mountTickets(actions) {
    const seg = h("div", { class: "seg" }, TICKET_STATES.map(([id, label]) =>
      h("button", { type: "button", "data-state": id, class: state.ticketState === id ? "on" : "",
        onclick: () => { state.ticketState = id; refresh(); } }, label)));
    append(actions, seg);
    const board = card("Review board", "one ticket per module; a verifier other than the reviewer closes it");
    const proposals = card("Shared-definition proposals", "a replacement applies once two agents other than its author agree and none objects");
    proposals.head.querySelector("h2").prepend(icon("proposals", 17));
    const root = h("div", { class: "stack" }, board.root, proposals.root);

    function update(tickets) {
      [...seg.children].forEach((b) => b.classList.toggle("on", b.dataset.state === state.ticketState));
      const shown = tickets.filter((t) => state.ticketState === "all" || t.state === state.ticketState);
      // A ticket the switch now hides — closed from the sheet — is drawn there
      // from what the server says, as one the board still lists.
      for (const ticket of tickets) updateDetail(`ticket:${ticket.module}`, ticketTitle(ticket), () => ticketDetail(ticket));
      fill(board.body, shown.length ? ticketTable(shown)
        : empty("reviewFindings", state.ticketState === "all" ? "No ticket yet" : `No ${state.ticketState} ticket`,
          "A verifying agent writes a remark on a module's review with ghidra_ticket_remark; the module's ticket is listed here."));
      call("GET", "/admin/api/type-proposals").then((rows) => {
        const shownProposals = rows.filter((p) => state.ticketState === "all"
          || PROPOSAL_STATES[state.ticketState].includes(p.state));
        for (const p of rows) updateDetail(`proposal:${p.id}`, proposalTitle(p), () => proposalDetail(p, proposalNames(p)));
        fill(proposals.body, shownProposals.length ? proposalTable(shownProposals)
          : empty("proposals", state.ticketState === "all" ? "No proposal" : `No ${state.ticketState} proposal`,
            "When a module's publish would replace a shared type or a library registry entry, its holder proposes the module's definitions with ghidra_type_propose; other agents vote here."));
      }, () => fill(proposals.body, h("div", { class: "muted", text: "This server keeps no type proposals." })));
    }
    return { root, update };
  }

  const proposalNames = (p) => p.names.filter((n) => !(n.startsWith("_") && p.names.includes(n.slice(1))));
  const proposalTitle = (p) => `Proposal of ${p.name || "a module"}`;
  // A change of the registry itself, in words: what it does to which entry or body.
  const CHANGE_WORDS = { take_out: "Take out", restore: "Restore", split: "Split off" };
  const changeText = (c) => [CHANGE_WORDS[c.action] || c.action,
    c.body ? `body ${c.body}` : null, c.id ? `${c.body ? "of" : "entry"} ${c.id}` : null,
    c.name ? `as ${c.name}` : null].filter(Boolean).join(" ");
  const ticketTitle = (ticket) => `Ticket of ${ticket.name || "a module"}`;

  function proposalPill(stateName) {
    const kind = stateName === "open" ? "warn" : stateName === "agreed" || stateName === "applied" ? "ok"
      : stateName === "rejected" ? "danger" : "plain";
    return h("span", { class: `pill ${kind}`, text: stateName });
  }

  function proposalTable(rows) {
    return h("table", { class: "lines" },
      h("thead", {}, h("tr", {},
        h("th", { class: "w-who", text: "Module" }), h("th", { text: "Types and entries" }), h("th", { class: "w-state", text: "State" }),
        h("th", { text: "Votes" }), h("th", { text: "Author" }))),
      h("tbody", {}, rows.map((p) => {
        const names = proposalNames(p);
        return detailRow(`proposal:${p.id}`, proposalTitle(p), () => proposalDetail(p, names),
          { class: p.state === "open" || p.state === "agreed" ? "" : "dim" },
          whoCell("proposals", p.name || "module", p.module),
          h("td", { class: "mono", text: p.change ? changeText(p.change)
            : names.concat(Object.values(p.entries || {}).map((e) => e.name)).join(", ") }),
          h("td", {}, proposalPill(p.state)),
          h("td", {}, h("span", { class: "ok-text", text: `${p.agrees.length}/${p.agrees_needed} agree` }),
            p.objections.length ? h("span", { class: "danger-text", text: ` · ${p.objections.length} object` }) : null),
          h("td", {}, h("div", { class: "line-who-title", title: p.author, text: p.author })));
      })));
  }

  // A line-by-line diff of two texts, as the app's code panel draws one
  // (`LineDiff` in CodeAnalysis): Myers' shortest edit script, the removed
  // lines of a change before the added ones.
  function lineDiff(oldText, newText) {
    const split = (text) => {
      if (!text) return [];
      const lines = text.replace(/\r\n/g, "\n").split("\n");
      if (text.endsWith("\n")) lines.pop();
      return lines;
    };
    const a = split(oldText), b = split(newText);
    const n = a.length, m = b.length, max = n + m;
    const pairs = [];
    if (n > 0 && m > 0) {
      let v = new Array(2 * max + 1).fill(0);
      const trace = [];
      let done = false;
      for (let d = 0; !done && d <= max; d++) {
        trace.push(v.slice());
        for (let k = -d; k <= d; k += 2) {
          const i = k + max;
          let x = (k === -d || (k !== d && v[i - 1] < v[i + 1])) ? v[i + 1] : v[i - 1] + 1;
          let y = x - k;
          while (x < n && y < m && a[x] === b[y]) { x++; y++; }
          v[i] = x;
          if (x >= n && y >= m) { done = true; break; }
        }
      }
      let x = n, y = m;
      for (let depth = trace.length - 1; depth > 0; depth--) {
        const state = trace[depth];
        const k = x - y, i = k + max;
        const pk = (k === -depth || (k !== depth && state[i - 1] < state[i + 1])) ? k + 1 : k - 1;
        const px = state[pk + max], py = px - pk;
        while (x > px && y > py) { x--; y--; pairs.push([x, y]); }
        x = px; y = py;
      }
      while (x > 0 && y > 0) { x--; y--; pairs.push([x, y]); }
      pairs.reverse();
    }
    const rows = [];
    let i = 0, j = 0, added = 0, removed = 0;
    const flush = (x, y) => {
      for (; i < x; i++) { rows.push({ kind: "removed", old: i + 1, text: a[i] }); removed++; }
      for (; j < y; j++) { rows.push({ kind: "added", new: j + 1, text: b[j] }); added++; }
    };
    for (const [x, y] of pairs) {
      flush(x, y);
      rows.push({ kind: "same", old: x + 1, new: y + 1, text: a[x] });
      i = x + 1; j = y + 1;
    }
    flush(n, m);
    return { rows, added, removed };
  }

  // The shared text against the module's, as the app's code panel compares
  // two revisions: the old line number, the new one, a mark and the line —
  // what only the shared copy has on red, what only the module offers on
  // green, the lines both hold as they are.
  function diffView(oldTitle, oldText, newTitle, newText) {
    const diff = lineDiff(oldText || "", newText || "");
    const oldWidth = String(diff.rows.reduce((top, r) => Math.max(top, r.old || 0), 0)).length;
    const newWidth = String(diff.rows.reduce((top, r) => Math.max(top, r.new || 0), 0)).length;
    const pad = (value, width) => String(value ?? "").padStart(width, " ");
    const summary = !oldText && !newText ? "empty on both sides"
      : !oldText ? `only in ${newTitle}` : !newText ? `only in ${oldTitle}`
      : diff.added || diff.removed ? `+${diff.added} −${diff.removed}` : "the same";
    return h("div", { class: "line-diff" },
      h("div", { class: "codebar-title" }, `${oldTitle} → ${newTitle}`,
        h("span", { class: "diff-count", text: summary })),
      h("pre", { class: "code diff" }, diff.rows.map((row) => {
        const mark = row.kind === "removed" ? "-" : row.kind === "added" ? "+" : " ";
        return h("div", { class: `diff-row ${row.kind}` },
          h("span", { class: "diff-gutter", text: ` ${pad(row.old, oldWidth)}  ${pad(row.new, newWidth)} ` }),
          h("span", { class: "diff-mark", text: `${mark} ` }),
          h("span", { text: row.text }));
      })));
  }

  // A decision's button: once that decision is the record's state it is
  // disabled and says so ("Agreed", "Closed"); `done` marks it as the one taken.
  function decisionButton(label, iconName, kind, disabled, done, onclick) {
    return h("button", { class: `btn small ${kind}${done ? " decided" : ""}`, type: "button", disabled, onclick },
      icon(iconName, 14), label);
  }

  function proposalDetail(p, names) {
    const live = p.state === "open" || p.state === "agreed";
    const decided = p.decided ? h("div", { class: "muted" },
      `${p.state === "withdrawn" ? "Withdrawn" : p.state === "rejected" ? "Rejected" : "Decided"} by ${p.decided.by}${p.decided.forced ? " from the console" : ""}, ${when(p.decided.at)}`,
      p.decided.note ? ` — ${p.decided.note}` : "") : null;
    const applied = p.applied ? h("div", { class: "muted",
      text: `Applied ${when(p.applied.at)}${p.applied.revision ? ` by revision ${p.applied.revision}` : ""}${p.applied.version ? `, shared types version ${p.applied.version}` : ""}` }) : null;
    const change = p.change ? h("div", { class: "type-conflict" },
      h("div", { class: "doc-title mono", text: changeText(p.change) }),
      h("div", { class: "muted", text: "A change of the registry itself: the server applies it the moment it is agreed." })) : null;
    // The decision taken reads on its own button, which no longer acts: an
    // agreed proposal can still be rejected until its publish applies it.
    const agreed = p.state === "agreed" || p.state === "applied";
    const buttons = [
      decisionButton(agreed ? "Agreed" : "Agree", "check", "", p.state !== "open", agreed, () => decideProposal(p, true)),
      decisionButton(p.state === "rejected" ? "Rejected" : "Reject", "ban", "danger", !live, p.state === "rejected",
        () => decideProposal(p, false))];
    const agrees = p.agrees || [], objections = p.objections || [];
    const status = h("div", { class: "sheet-status" },
      proposalPill(p.state),
      h("span", { class: "ok-text", text: `${agrees.length}/${p.agrees_needed} agree` }),
      h("span", { class: objections.length ? "danger-text" : "muted", text: `${objections.length} object` }),
      agrees.length ? h("span", { class: "muted", text: `agreed: ${agrees.join(", ")}` }) : null,
      objections.length ? h("span", { class: "muted", text: `objected: ${objections.join(", ")}` }) : null,
      h("span", { class: "grow" }), buttons);
    return h("div", { class: "stack" },
      status,
      h("div", { class: "row" }, h("span", { class: "muted", text: `Proposed ${when(p.at)}` })),
      decided, applied,
      h("div", { class: "remark" }, h("div", { class: "row" }, h("b", { text: p.author }), h("span", { class: "muted", text: "why" })),
        h("div", { class: "remark-text", text: p.reason })),
      change,
      names.map((name) => h("div", { class: "type-conflict" },
        h("div", { class: "doc-title mono", text: name }),
        h("div", { class: "muted", text: `Shared copy written by ${(p.origins || {})[name] ? String(p.origins[name]).slice(0, 12) : "a module not known here"}` }),
        diffView("Shared now", p.shared_c[name], `${p.name || "module"} (proposed)`, p.module_c[name]))),
      Object.entries(p.entries || {}).sort(([a], [b]) => a.localeCompare(b)).map(([id, entry]) => h("div", { class: "type-conflict" },
        h("div", { class: "doc-title mono", text: `${entry.name} · registry entry ${id}` }),
        h("div", { class: "muted", text: `Version ${entry.version ?? "?"}, the review of ${entry.held_by ? String(entry.held_by).slice(0, 12) : "a module not known here"}${entry.proposed_name && entry.proposed_name !== entry.name ? `; this module names it ${entry.proposed_name}` : ""}` }),
        (entry.fields || []).map((f) => h("div", {},
          h("div", { class: "codebar-title mono", text: f.field }),
          diffView("Entry now", f.held, `${p.name || "module"} (proposed)`, f.offered))))),
      (p.votes || []).map((vote) => h("div", { class: "reply" },
        h("div", { class: "row" }, h("b", { text: vote.agent }),
          h("span", { class: `pill ${vote.choice === "agree" ? "ok" : "danger"}`, text: vote.choice }),
          h("span", { class: "muted", text: when(vote.at) })),
        vote.text ? h("div", { class: "remark-text", text: vote.text }) : null)));
  }

  async function decideProposal(p, agree) {
    const note = h("input", { class: "field", placeholder: agree ? "Why it is agreed, whatever the votes" : "Why it is rejected", autocomplete: "off" });
    const done = await dialog({
      icon: agree ? "check" : "ban", tone: agree ? "ok" : "danger",
      title: agree ? `Agree the proposal of ${p.name || "this module"}?` : `Reject the proposal of ${p.name || "this module"}?`,
      text: p.change
        ? (agree ? `The server applies it now: ${changeText(p.change)}.` : "The proposal is closed; the registry stays as it is.")
        : agree ? "The module's next publish replaces the shared types with its definitions, as their next version, provided it still defines them as proposed."
        : "The proposal is closed; the module's publish stays refused until its types match the shared ones.",
      body: note,
      actions: [{ label: "Cancel", kind: "ghost", value: false }, { label: agree ? "Agree" : "Reject", kind: agree ? "primary" : "danger", value: true, focus: true }],
    });
    if (!done) return;
    await act(() => call("POST", `/admin/api/type-proposals/${p.id}/decide`, { agree, note: note.value.trim() || null }),
      agree ? "Proposal agreed" : "Proposal rejected");
  }

  function ticketPill(stateName) {
    const kind = stateName === "open" ? "danger" : stateName === "settled" ? "warn" : "ok";
    return h("span", { class: `pill ${kind}`, text: stateName });
  }

  function remarkPill(status) {
    const kind = status === "open" ? "danger" : status === "verified" ? "ok" : status === "wont_fix" ? "plain" : "warn";
    return h("span", { class: `pill ${kind}`, text: status.replace("_", " ") });
  }

  function lastActivity(ticket) {
    const times = [ticket.opened, ticket.closed && ticket.closed.at]
      .concat(...(ticket.remarks || []).map((r) => [r.at].concat((r.thread || []).map((x) => x.at)))).filter(Boolean);
    return times.sort().pop();
  }

  function ticketTable(tickets) {
    return h("table", { class: "lines" },
      h("thead", {}, h("tr", {},
        h("th", { class: "w-who", text: "Module" }), h("th", { class: "w-state", text: "Review" }),
        h("th", { class: "num w-n", text: "Open" }), h("th", { class: "num w-n", text: "Remarks" }),
        h("th", { text: "Reviewer" }), h("th", { class: "w-time", text: "Last" }))),
      h("tbody", {}, tickets.map((ticket) => {
        return detailRow(`ticket:${ticket.module}`, ticketTitle(ticket), () => ticketDetail(ticket),
          { class: ticket.state === "closed" ? "dim" : "" },
          whoCell("layers", ticket.name || "module", ticket.module),
          h("td", {}, ticketPill(ticket.state)),
          h("td", { class: `num ${ticket.open_remarks ? "danger-text" : ""}`, text: String(ticket.open_remarks || 0) }),
          h("td", { class: "num", text: String((ticket.remarks || []).length) }),
          h("td", {}, h("div", { class: "line-who-title", title: ticket.reviewer || "", text: ticket.reviewer || "—" })),
          h("td", { class: "muted", title: when(lastActivity(ticket)), text: ago(lastActivity(ticket)) }));
      })));
  }

  function ticketDetail(ticket) {
    const closing = ticket.closed
      ? h("div", { class: "muted" }, `Closed by ${ticket.closed.by}${ticket.closed.forced ? " (forced from the console)" : ""}, ${when(ticket.closed.at)}`,
        ticket.closed.note ? ` — ${ticket.closed.note}` : "")
      : null;
    const closed = ticket.state === "closed";
    const remarks = ticket.remarks || [];
    const status = h("div", { class: "sheet-status" },
      ticketPill(ticket.state),
      h("span", { class: ticket.open_remarks ? "danger-text" : "ok-text", text: `${ticket.open_remarks || 0} open` }),
      h("span", { class: "muted", text: `${remarks.length} ${remarks.length === 1 ? "remark" : "remarks"}` }),
      ticket.reviewer ? h("span", { class: "muted", text: `reviewer ${ticket.reviewer}` }) : null,
      h("span", { class: "grow" }),
      decisionButton(closed ? "Closed" : "Close", "check", "", closed, closed, () => forceTicket(ticket, true)),
      decisionButton("Open again", "refresh", "", !closed, false, () => forceTicket(ticket, false)));
    return h("div", { class: "stack" },
      status,
      h("div", { class: "row" }, closing || h("span", { class: "muted", text: `Opened ${when(ticket.opened)}` })),
      (ticket.remarks || []).length ? (ticket.remarks || []).map((remark) => remarkBlock(ticket, remark))
        : h("div", { class: "muted", text: "Closed with no remarks: checked and found right." }));
  }

  function remarkBlock(ticket, remark) {
    const where = [remark.function, remark.address].filter(Boolean).join(" · ");
    return h("div", { class: "remark" },
      h("div", { class: "row" },
        remarkPill(remark.status),
        h("span", { class: "pill plain", text: remark.severity }),
        h("b", { text: remark.author }),
        h("span", { class: "muted", text: `${when(remark.at)}${remark.revision ? ` · rev ${remark.revision}` : ""}${where ? ` · ${where}` : ""}` }),
        h("span", { class: "grow" }),
        iconButton("sliders", "Set this remark's status", () => forceRemark(ticket, remark))),
      h("div", { class: "remark-text", text: remark.text }),
      (remark.thread || []).map((reply) => h("div", { class: "reply" },
        h("div", { class: "row" },
          h("b", { text: reply.author }),
          reply.status ? remarkPill(reply.status) : null,
          h("span", { class: "muted", text: `${when(reply.at)}${reply.revision ? ` · rev ${reply.revision}` : ""}` })),
        reply.text ? h("div", { class: "remark-text", text: reply.text }) : null)));
  }

  async function forceRemark(ticket, remark) {
    const status = h("select", { class: "field select", "aria-label": "Status" },
      REMARK_STATUSES.map((s) => h("option", { value: s, text: s.replace("_", " "), selected: s === remark.status })));
    const note = h("input", { class: "field", placeholder: "Why, for the thread", autocomplete: "off" });
    const done = await dialog({
      icon: "sliders", title: `Set the status of ${remark.author}'s remark?`,
      text: "An administrator's say: it goes into the remark's thread, whatever the rules for agents.",
      body: h("div", { class: "stack" }, status, note),
      actions: [{ label: "Cancel", kind: "ghost", value: false }, { label: "Set", kind: "primary", value: true, focus: true }],
    });
    if (!done) return;
    await act(() => call("POST", `/admin/api/tickets/${ticket.module}/force`,
      { remark: remark.id, status: status.value, note: note.value.trim() || null }), "Status set");
  }

  async function forceTicket(ticket, close) {
    const note = h("input", { class: "field", placeholder: close ? "Why it is closed with remarks open" : "Why it is open again", autocomplete: "off" });
    const done = await dialog({
      icon: close ? "check" : "refresh", tone: close ? "ok" : "",
      title: close ? `Close the ticket of ${ticket.name || "this module"}?` : `Open the ticket of ${ticket.name || "this module"} again?`,
      text: close ? "Closed whatever its remarks hold; the agents see it was forced from the console." : "The module's review is open again until a verifier closes it.",
      body: note,
      actions: [{ label: "Cancel", kind: "ghost", value: false }, { label: close ? "Close" : "Open again", kind: "primary", value: true, focus: true }],
    });
    if (!done) return;
    await act(() => call("POST", `/admin/api/tickets/${ticket.module}/force`, { close, note: note.value.trim() || null }),
      close ? "Ticket closed" : "Ticket open again");
  }

  function mountTokens(actions) {
    let presets = {};
    let rights = [];
    append(actions, h("button", { class: "btn primary", type: "button", onclick: () => newToken(presets, rights) }, icon("plus", 16), "New token"));
    const live = card("Tokens", "secrets are kept as hashes only");
    const revoked = h("div", {});
    const root = h("div", { class: "stack" }, live.root, revoked);

    function update(data) {
      presets = data.presets;
      rights = data.rights;
      const active = data.tokens.filter((t) => !t.revoked);
      const gone = data.tokens.filter((t) => t.revoked);
      fill(live.body, active.length ? tokenTable(active) : empty("key", "No live token", "Make one with New token."));
      if (gone.length) {
        fill(revoked, h("section", { class: "card" },
          h("details", { class: "revoked" }, h("summary", { text: `Revoked (${gone.length})` }), tokenTable(gone))));
      } else {
        fill(revoked);
      }
    }
    return { root, update };
  }

  function rightTag(right) {
    const kind = right === "admin" ? "admin" : right.endsWith("write") ? "write" : right.startsWith("ghidra") ? "ghidra" : "";
    return h("span", { class: `right ${kind}`, text: right });
  }

  function tokenTable(tokens) {
    return h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {},
        h("th", { text: "Token" }), h("th", { text: "Rights" }), h("th", { text: "Created" }), h("th", { text: "Last used" }), h("th", {}))),
      h("tbody", {}, tokens.map((token) => h("tr", { class: token.revoked ? "dim" : "" },
        h("td", {}, h("div", { class: "row" },
          h("div", { class: "doc-icon" }, icon("key", 16)),
          h("div", {},
            h("div", { class: "row" }, h("span", { class: "doc-title", text: token.name }),
              token.yours ? h("span", { class: "pill accent plain", title: "You signed in with this token", text: "you" }) : null),
            h("div", { class: "doc-path", text: token.id })))),
        h("td", {}, h("div", { class: "chips" }, token.rights.map(rightTag))),
        h("td", { class: "muted", text: when(token.created) }),
        h("td", { class: "muted", text: ago(token.last_used) }),
        h("td", { class: "actions" }, token.revoked ? h("span", { class: "pill danger", text: "Revoked" }) : [
          iconButton("refresh", "Rotate — a new secret, the old one refused at once", () => rotateToken(token)),
          iconButton("ban", "Revoke", () => revokeToken(token), "danger"),
        ]))))));
  }

  async function rotateToken(token) {
    const sure = await confirmAction({
      title: `Rotate “${token.name}”?`, label: "Rotate", danger: false, iconName: "refresh",
      text: "A new secret replaces the old one at once: every client and console session still using the old one is refused from now on."
        + (token.yours ? " You signed in with this token, so you will be signed out." : ""),
    });
    if (!sure) return;
    const made = await act(() => call("POST", `/admin/api/tokens/${token.id}/rotate`));
    if (!made) return;
    const preset = token.rights.includes("admin") ? "admin" : token.rights.includes("cas.write") ? "app" : "reader";
    await showSecret({ title: "New secret", name: token.name, secret: made.secret, preset, signedOutAfter: made.signed_out });
    if (made.signed_out) signedOut();
  }

  async function revokeToken(token) {
    const sure = await confirmAction({
      title: `Revoke “${token.name}”?`, label: "Revoke", iconName: "ban",
      text: "Every request with it is refused from now on and its console sessions end. A revoked token stays listed and cannot be brought back."
        + (token.yours ? " You signed in with this token, so you will be signed out." : ""),
    });
    if (!sure) return;
    const done = await act(() => call("POST", `/admin/api/tokens/${token.id}/revoke`), `${token.name} revoked`);
    if (done && done.signed_out) signedOut();
  }

  const PRESET_NOTES = {
    reader: "Reads the analysis store. For a Mac or a script that only looks.",
    app: "Reads and writes the store and drives Ghidra: what ByteRipper on another Mac needs.",
    admin: "Everything, the console included. Keep these few.",
    custom: "Pick the rights one by one. Every token reads the store.",
  };

  function newToken(presets, rights) {
    const name = h("input", { class: "field", placeholder: "e.g. studio-mac", autocomplete: "off", spellcheck: "false" });
    const note = h("div", { class: "preset-note" });
    const checks = h("div", { class: "checks" }, rights.map((right) =>
      h("label", { class: "check" }, h("input", { type: "checkbox", value: right, checked: right === "cas.read", disabled: right === "cas.read" }), right)));
    let preset = "app";
    const seg = h("div", { class: "seg" });
    const choose = (which) => {
      preset = which;
      [...seg.children].forEach((b) => b.classList.toggle("on", b.dataset.preset === which));
      note.textContent = PRESET_NOTES[which];
      checks.hidden = which !== "custom";
      if (which !== "custom") {
        const granted = presets[which] || [];
        checks.querySelectorAll("input").forEach((box) => { box.checked = granted.includes(box.value) || box.value === "cas.read"; });
      }
    };
    append(seg, ["reader", "app", "admin", "custom"].map((which) =>
      h("button", { type: "button", "data-preset": which, onclick: () => choose(which) }, which[0].toUpperCase() + which.slice(1))));
    choose("app");
    const error = h("div", {});
    dialog({
      icon: "key",
      title: "New token",
      text: "Its secret is shown once, when it is made.",
      body: h("div", { class: "form" },
        h("div", {}, h("label", { class: "label", text: "Name" }), name, h("div", { class: "hint", text: "What the activity and the logs call whoever holds it." })),
        h("div", {}, h("div", { class: "label", text: "Rights" }), seg),
        note, checks, error),
      actions: [
        { label: "Cancel", kind: "ghost", value: null },
        { label: "Create", kind: "primary", run: async () => {
          if (!name.value.trim()) { name.focus(); return false; }
          const body = { name: name.value.trim() };
          if (preset === "custom") body.rights = [...checks.querySelectorAll("input:checked")].map((box) => box.value);
          else body.preset = preset;
          try {
            const made = await call("POST", "/admin/api/tokens", body);
            setTimeout(() => showSecret({ title: "Token created", name: made.name, secret: made.secret, preset }), 0);
            refresh();
            return made;
          } catch (failure) {
            fill(error, h("div", { class: "notice", text: failure.message }));
            return false;
          }
        } },
      ],
    });
    setTimeout(() => name.focus(), 30);
  }

  // ---------- Activity: the modules in work ----------

  function updateLeases(modules, closed, rows, proposals) {
    if (rows === null || rows === undefined) {
      modules.root.hidden = true;
      fill(closed);
      return;
    }
    modules.root.hidden = false;
    const held = rows.filter((row) => row.holder);
    const ended = rows.filter((row) => row.closed);
    fill(modules.body, held.length ? leaseTable(held, proposals || [])
      : empty("layers", "No module in work", "A holder takes a module into work before its first write; it shows here until it gives it back."));
    if (ended.length) {
      fill(closed, h("section", { class: "card" },
        h("details", { class: "revoked" }, h("summary", { text: `Leases closed, not taken again (${ended.length})` }), closedLeaseTable(ended))));
    } else {
      fill(closed);
    }
  }

  // The module by its name; its SHA-256 only on hover, where it does not
  // take the table's width.
  function moduleCell(row) {
    return h("td", {}, h("div", { class: "row", title: row.module },
      h("div", { class: "doc-icon" }, icon("layers", 16)),
      h("div", { class: "doc-title", text: row.name || row.module.slice(0, 12) })));
  }

  function leaseTable(rows, proposals) {
    return h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {},
        h("th", { text: "Module" }), h("th", { text: "Holder" }), h("th", { text: "Connection" }), h("th", { text: "In work since" }),
        h("th", { text: "Last call" }), h("th", { class: "num", text: "Writes" }), h("th", { class: "num", text: "Publishes" }),
        h("th", { text: "Last revision" }), h("th", {}))),
      h("tbody", {}, rows.map((row) => h("tr", {},
        moduleCell(row),
        h("td", { text: row.holder }),
        connectionCell(row),
        h("td", { class: "muted", text: when(row.since) }),
        h("td", {}, row.last_call
          ? h("div", {}, h("div", { class: "mono", text: row.last_call }), h("div", { class: "muted", text: ago(row.last_at) }))
          : h("span", { class: "muted", text: "—" })),
        h("td", { class: "num", text: String(row.writes || 0) }),
        h("td", { class: "num", text: String(row.publishes || 0) }),
        h("td", { class: "muted", text: row.revision ? `rev ${row.revision}` : "—" }),
        h("td", { class: "actions" },
          proposals.filter((p) => p.module === row.module).map((p) => iconButton("proposals",
            `Its proposal to replace shared definitions (${p.state}) — open it`,
            () => openDetail(`proposal:${p.id}`, proposalTitle(p), () => proposalDetail(p, proposalNames(p))))),
          iconButton("ban", "Close the lease — the holder's unpublished changes are dropped", () => closeLease(row), "danger")))))));
  }

  // Which connection works on a module the local MCP holds: every agent on
  // the socket is the one holder, so the connection says which agent it is.
  // A token's lease is its token's: nothing to add.
  function connectionCell(row) {
    const use = row.connection || row.taken_on;
    if (!use) return h("td", { class: "muted", text: "—" });
    const title = (u) => connectionTitle(u.number, u.open ? u.agent : null) + (u.open ? "" : " (closed)");
    const taken = row.taken_on && row.connection && row.taken_on.number !== row.connection.number
      ? h("div", { class: "muted", text: `taken on ${title(row.taken_on)}` }) : null;
    return h("td", {},
      h("div", { class: "agent-title", text: title(use) }),
      h("div", { class: "muted", text: use.open ? (use.client || "client not known") : "no longer connected" }),
      taken);
  }

  function closedLeaseTable(rows) {
    return h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {},
        h("th", { text: "Module" }), h("th", { text: "Holder" }), h("th", { text: "Closed by" }), h("th", { text: "Closed" }))),
      h("tbody", {}, rows.map((row) => h("tr", { class: "dim" },
        moduleCell(row),
        h("td", { text: row.closed.holder }),
        h("td", { text: row.closed.closed_by }),
        h("td", { class: "muted", text: when(row.closed.at) }))))));
  }

  async function closeLease(row) {
    const name = row.name || row.module;
    const sure = await confirmAction({
      title: `Close the lease of “${name}”?`, label: "Close", iconName: "ban",
      text: `${row.holder} has it in work since ${when(row.since)}. Its unpublished changes are dropped: the working project goes to the Trash, `
        + "and the module opens again at its last published revision. The holder is told at its next call on the module.",
    });
    if (!sure) return;
    await act(() => call("POST", `/admin/api/leases/${row.module}/close`), `${name}: lease closed`);
  }

  // ---------- Configuration ----------

  // The client the agent runs in, then where the text goes and the text: the
  // app's Settings ▸ Agents, for this server's relay.
  function mountConfiguration() {
    const STORE = "byteripper.console.client";
    const FORM = {
      shell: { icon: "terminal", kind: "Terminal command", file: "Terminal" },
      json: { icon: "braces", kind: "Configuration file", file: "JSON" },
      fields: { icon: "list", kind: "Parameters", file: "Parameters" },
    };
    let chosen = null;
    try { chosen = localStorage.getItem(STORE); } catch { /* no storage */ }
    let data = null;
    let shown = "";

    const picker = h("div", { class: "clients", role: "radiogroup", "aria-label": "Client" });
    const destination = h("p", { class: "destination" });
    const block = h("div", {});
    const connect = h("section", { class: "card" },
      h("div", { class: "card-head" }, h("h2", {}, "Connect an agent",
        h("span", { class: "sub", text: "pick the program the agent runs in" }))),
      h("div", { class: "card-body config" }, picker, destination, block,
        h("p", { class: "hint", text: "" })));
    const note = connect.querySelector(".hint");

    const flow = h("div", { class: "flow" });
    const facts = h("dl", { class: "kv" });
    const how = h("section", { class: "card" },
      h("div", { class: "card-head" }, h("h2", {}, "How it connects",
        h("span", { class: "sub", text: "local only: nothing of MCP reaches the network" }))),
      h("div", { class: "card-body config" }, flow, facts,
        h("p", { class: "hint", text: "The socket's file permissions are its only guard: any process of this user can connect to it, and through it publish to the store and drive Ghidra." })));

    const root = h("div", { class: "stack" }, connect, how);

    // A destination's paths set in code: the sentence names the file.
    function sentence(text) {
      const parts = text.split(/((?:~\/|\.)[^,]*?\.json)/);
      return parts.map((part, index) => (index % 2 ? h("code", { class: "path", text: part }) : part));
    }

    function draw() {
      const clients = data.agent.clients;
      const client = clients.find((c) => c.id === chosen) || clients[0];
      chosen = client.id;
      fill(picker, clients.map((c) => h("button", {
        class: `client ${c.id === client.id ? "on" : ""}`, type: "button", role: "radio",
        "aria-checked": c.id === client.id ? "true" : "false",
        onclick: () => { chosen = c.id; try { localStorage.setItem(STORE, c.id); } catch { /* no storage */ } draw(); },
      },
        h("span", { class: "client-icon" }, icon(FORM[c.form].icon, 18)),
        h("span", { class: "client-text" }, h("b", { text: c.title }), h("small", { text: FORM[c.form].kind })))));
      fill(destination, sentence(client.destination));

      const copyAll = h("button", { class: "btn primary small", type: "button", onclick: () => copy(client.text, client.form === "shell" ? "the command" : "the configuration") },
        icon("copy", 15), client.form === "shell" ? "Copy command" : "Copy");
      let body;
      if (client.form === "fields") {
        body = h("div", { class: "fields" }, client.fields.map((field) =>
          h("div", { class: "field-row" },
            h("span", { class: "field-name", text: field.name }),
            h("code", { class: "field-value", text: field.value }),
            iconButton("copy", `Copy ${field.name.toLowerCase()}`, () => copy(field.value, field.name.toLowerCase())))));
      } else {
        body = h("pre", { class: `code code-${client.form}` }, client.form === "shell" ? h("span", { class: "prompt", text: "$ " }) : null, client.text);
      }
      fill(block, h("div", { class: "codeblock" },
        h("div", { class: "codebar" }, h("span", { class: "codebar-title" }, icon(FORM[client.form].icon, 14), FORM[client.form].file), copyAll),
        body));
      note.textContent = `Registered as ${data.agent.server_name}, so it sits beside the ByteRipper app's own byteripper in the same client.`;
    }

    function node(iconName, title, sub) {
      return h("div", { class: "flow-node" }, h("span", { class: "flow-icon" }, icon(iconName, 18)),
        h("span", { class: "flow-text" }, h("b", { text: title }), h("small", { text: sub })));
    }

    function update(next) {
      const text = JSON.stringify(next);
      if (text === shown) return;
      shown = text;
      data = next;
      if (!data.agent) {
        fill(root, empty("plug", "No local MCP socket", "This server answers without one, so there is nothing for an agent to connect to."));
        return;
      }
      draw();
      const arrow = () => h("span", { class: "flow-arrow" }, icon("arrowRight", 16));
      fill(flow,
        node("bot", "The agent's client", "Claude Code, Claude Desktop, Cursor…"), arrow(),
        node("terminal", "relay", "started by the client, stdio"), arrow(),
        node("plug", "mcp.sock", "0600, in the server's folder"), arrow(),
        node("server", "This server", "the documents and the tools"));
      fill(facts,
        h("dt", { text: "Relay binary" }), h("dd", {}, copyLine(data.agent.binary, "the binary's path")),
        h("dt", { text: "Socket" }), h("dd", {}, copyLine(data.agent.socket, "the socket's path")),
        h("dt", { text: "Command" }), h("dd", {}, copyLine(data.agent.command, "the command")));
    }
    return { root, update };
  }

  // ---------- Status ----------

  function mountStatus() {
    const uptime = tile("clock", "Uptime");
    const memory = tile("server", "Memory");
    const documents = tile("chip", "Documents");
    const sessions = tile("users", "Console sessions");
    const server = h("dl", { class: "kv" });
    const network = h("dl", { class: "kv" });
    const roles = h("dl", { class: "kv" });
    const mcp = h("div", { class: "form" });
    const limits = h("dl", { class: "kv" });
    const section = (title, iconName, body) => h("section", { class: "card" },
      h("div", { class: "card-head" }, h("h2", {}, icon(iconName, 17), title)), h("div", { class: "card-body" }, body));
    const root = h("div", { class: "stack" },
      h("div", { class: "grid tiles" }, uptime.root, memory.root, documents.root, sessions.root),
      h("div", { class: "grid two" },
        section("Server", "server", server),
        section("Network", "globe", network),
        section("Roles", "database", roles),
        section("Local MCP", "plug", mcp),
        section("Limits", "layers", limits)));

    const kv = (dl, pairs) => fill(dl, pairs.flatMap(([key, value]) => [h("dt", { text: key }), h("dd", {}, value)]));
    const mono = (text) => h("span", { class: "mono", text });

    function update(data) {
      uptime.set(duration(data.uptime), null, `since ${when(data.started)}`);
      memory.set(data.memory !== undefined ? bytes(data.memory) : "—", null, "resident: snapshots, trees and what they decompressed");
      documents.set(String(data.documents.open), data.documents.missing ? `+ ${data.documents.missing} missing` : null,
        `${bytes(data.documents.bytes)} of ${bytes(data.limits.open_bytes)}`, data.documents.bytes / data.limits.open_bytes);
      sessions.set(String(data.sessions), null, "signed in with an admin token");
      kv(server, [
        ["Version", mono(data.version)],
        ["Process", mono(`PID ${data.pid}`)],
        ["Started", when(data.started)],
        ["Tokens", mono(data.tokens_file)],
      ]);
      kv(network, [
        ["Listening", h("div", { class: "chips" }, data.addresses.map((a) => h("span", { class: "chip", text: a })))],
        ["Console names", data.server_names.length
          ? h("div", { class: "chips" }, data.server_names.map((n) => h("span", { class: "chip", text: n })))
          : h("span", { class: "muted", text: "the listen addresses only — add more with --server-name" })],
        ["Transport", h("span", { class: "pill warn", title: "Everything that crosses a LAN is readable: prefer loopback or a tailnet", text: "plain HTTP" })],
      ]);
      kv(roles, [
        ["Store", h("div", {}, h("span", { class: "pill ok", text: "on" }), " ", mono(data.store))],
        ["Store id", data.store_id ? mono(data.store_id) : h("span", { class: "muted", text: "—" })],
        ["Ghidra", data.ghidra
          ? h("div", {}, h("span", { class: "pill ok", text: "on" }), " ", data.ghidra)
          : h("span", { class: "pill plain", text: "not a role of this server" })],
        ["Roles", h("div", { class: "chips" }, data.roles.map((r) => h("span", { class: "chip", text: r })))],
      ]);
      fill(mcp,
        h("div", {}, h("div", { class: "label", text: "Socket" }), copyLine(data.socket, "the socket's path")),
        h("div", {}, h("button", { class: "btn small", type: "button", onclick: () => go("/admin/configuration") },
          icon("sliders", 15), "Agent configuration", icon("arrowRight", 14))),
        h("p", { class: "hint", text: "The socket's file permissions are its only guard: any process of this user can connect." }));
      kv(limits, [
        ["Documents", `${data.limits.documents} open at once`],
        ["Open bytes", bytes(data.limits.open_bytes)],
        ["One upload", bytes(data.limits.upload_bytes)],
      ]);
    }
    return { root, update };
  }

  render();
})();
