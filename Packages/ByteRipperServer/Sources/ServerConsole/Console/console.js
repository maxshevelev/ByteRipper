// ByteRipper Server — the console. No framework and no build step: the page
// is drawn with DOM calls, text always through textContent, and everything it
// shows comes from /admin/api/*, polled every two seconds while the tab is
// visible (Design/SERVER_HEADLESS_PLAN.md §8).
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

  async function copy(text, what) {
    try {
      await navigator.clipboard.writeText(text);
      toast(`Copied ${what}`, "ok");
    } catch {
      toast("The browser did not allow copying; select the text instead.", "error");
    }
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

  function dialog({ icon: iconName, tone = "", title, text, body, actions }) {
    const el = h("dialog", {});
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
  };

  const PAGES = {
    "/admin/documents": { title: "Documents", subtitle: "The firmware images the local MCP serves.", icon: "chip", endpoint: "/admin/api/documents", mount: mountDocuments },
    "/admin/activity": { title: "Activity", subtitle: "Who is connected now. Nothing is written down.", icon: "activity", endpoint: "/admin/api/activity", mount: mountActivity },
    "/admin/tokens": { title: "Tokens", subtitle: "Who may reach this server, and with which rights.", icon: "key", endpoint: "/admin/api/tokens", mount: mountTokens },
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
    if (document.hidden) { stopPolling(); setLive("paused"); } else { poll(); }
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
    const page = PAGES[path];
    const name = state.session.name || "admin";
    const nav = h("nav", { class: "nav" }, Object.entries(PAGES).map(([target, info]) =>
      h("a", { href: target, class: target === path ? "active" : "", onclick: (event) => { event.preventDefault(); go(target); } },
        icon(info.icon), h("span", { class: "nav-label", text: info.title }))));
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
    state.page = { endpoint: page.endpoint, view, content, first: true };
    poll();
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
    if (state.page === page && !document.hidden) state.timer = setTimeout(poll, POLL_MS);
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

    // Adding: from a path or by upload.
    const path = h("input", { class: "field mono", placeholder: "/Volumes/Dumps/board.bin", spellcheck: "false" });
    const displayName = h("input", { class: "field", placeholder: "Name (optional)" });
    const roots = h("div", { class: "chips" });
    const openButton = h("button", { class: "btn primary", type: "submit" }, icon("folder", 16), "Open");
    const byPath = h("form", { class: "form", onsubmit: async (event) => {
      event.preventDefault();
      if (!path.value.trim()) { path.focus(); return; }
      openButton.disabled = true;
      const result = await act(() => call("POST", "/admin/api/documents", { path: path.value, name: displayName.value || undefined }),
        (made) => `Opened as ${made.id}`);
      openButton.disabled = false;
      if (result) { path.value = ""; displayName.value = ""; }
    } },
      h("div", {}, h("label", { class: "label", text: "Path on the server" }),
        h("div", { class: "row wrap" }, h("div", { class: "grow" }, path), h("div", { class: "name-field" }, displayName), openButton)),
      h("div", {}, h("div", { class: "label", text: "Dump roots — a path must lie under one" }), roots));

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
      h("button", { type: "button", "data-tab": "path", class: "on", onclick: () => showTab("path") }, "From a path"),
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

      fill(roots, data.roots.length
        ? data.roots.map((r) => h("button", { type: "button", class: `chip ${r.present ? "" : "absent"}`,
          title: r.present ? "Put this root in the path" : "This root is not there — not mounted, or mistyped",
          onclick: () => { path.value = r.path.replace(/\/?$/, "/"); path.focus(); } },
          icon(r.present ? "folder" : "alert", 13), h("span", { class: "clip", text: r.path })))
        : h("span", { class: "muted", text: "No --dump-roots: only uploads can be opened." }));

      list.head.querySelector(".sub").textContent = docs.length
        ? `${docs.length - missing} served${missing ? ` · ${missing} missing` : ""} · ids last across restarts`
        : "ids last across restarts and are never given to another file";
      if (!docs.length) {
        fill(list.body, empty("chip", "No dumps yet", "Open one from a dump root, or upload one. An agent sees it in `documents` at once."));
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
    const agents = card("Agents", "connections to the local MCP socket");
    const clients = card("REST clients", "requests per token since the server started; the console's own are not counted");
    const root = h("div", { class: "stack" }, agents.root, clients.root);

    function update(data) {
      if (!data.mcp.length) {
        fill(agents.body, empty("bot", "No agent is connected",
          "An agent on this machine reaches the server through the relay; give its MCP client this command:",
          h("div", { class: "row" }, h("div", { class: "grow" }, copyLine("byteripper-server relay", "the command")))));
      } else {
        fill(agents.body, h("div", { class: "agents" }, data.mcp.map(agentCard)));
      }
      if (!data.rest.length) {
        fill(clients.body, empty("globe", "No REST requests yet", "The app and the scripts show up here, one row per token, when they reach the store or Ghidra."));
      } else {
        fill(clients.body, h("div", { class: "table-wrap" }, h("table", {},
          h("thead", {}, h("tr", {},
            h("th", { text: "Token" }), h("th", { class: "num", text: "Requests" }), h("th", { class: "num", text: "Refused" }),
            h("th", { text: "Last request" }), h("th", { text: "Last seen" }))),
          h("tbody", {}, data.rest.map((row) => h("tr", {},
            h("td", {}, h("div", { class: "row" },
              h("div", { class: "doc-icon" }, icon(row.token ? "key" : "alert", 16)),
              h("div", {}, h("div", { class: "doc-title", text: row.name }), row.token ? h("div", { class: "doc-path", text: row.token }) : null))),
            h("td", { class: "num", text: row.requests }),
            h("td", { class: `num ${row.refused ? "danger-text" : ""}`, text: row.refused }),
            h("td", {}, h("div", { class: "row" }, h("code", { text: row.last }), statusPill(row.last_status))),
            h("td", { class: "muted", text: ago(row.last_seen) })))))));
      }
    }
    return { root, update };
  }

  function statusPill(code) {
    const kind = code >= 500 ? "danger" : code === 401 || code === 403 ? "danger" : code >= 400 ? "warn" : "ok";
    return h("span", { class: `pill ${kind}`, text: String(code) });
  }

  function agentCard(row) {
    const end = row.finished ? Date.parse(row.finished) : Date.now();
    const pill = !row.open
      ? h("span", { class: "pill plain", text: "Ended" })
      : row.spoke ? h("span", { class: "pill ok", text: "Live" }) : h("span", { class: "pill warn", title: "Connected, has said nothing yet", text: "Silent" });
    return h("div", { class: `agent ${row.open ? "" : "ended"}` },
      h("div", { class: "agent-head" },
        h("div", { class: "agent-badge" }, icon("bot", 18)),
        h("div", {}, h("div", { class: "agent-title", text: `Connection ${row.number}` }),
          h("div", { class: "agent-sub", text: row.client || "client not known" })),
        pill),
      h("div", { class: "agent-stats" },
        h("div", { class: "agent-stat" }, h("b", { text: row.calls }), h("span", { text: "calls" })),
        h("div", { class: "agent-stat" }, h("b", { class: row.errors ? "danger-text" : "", text: row.errors }), h("span", { text: "errors" })),
        h("div", { class: "agent-stat" }, h("b", { text: duration((end - Date.parse(row.started)) / 1000) }), h("span", { text: row.open ? "connected" : "lasted" }))),
      h("div", { class: "agent-last" },
        row.last_tool ? h("span", {}, "Last ", h("code", { text: row.last_tool })) : h("span", { text: "No call yet" }),
        h("span", { text: row.last_call ? ago(row.last_call) : ago(row.started) })));
  }

  // ---------- Tokens ----------

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
        h("div", {}, h("div", { class: "label", text: "An agent's MCP command" }), copyLine(`byteripper-server relay --mcp-socket ${data.socket}`, "the command")),
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
