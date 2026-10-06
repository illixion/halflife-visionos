// LambdaVision — Manage over Wi-Fi.
//
// Talks to the headset's LibraryServer: pair with the PIN, list and manage
// games, and send folders and archives. Folder uploads diff against the
// headset's manifest first and send only what differs, into a staging area
// that survives a dropped connection; "commit" then hands it to the
// importer. 7z/RAR are unpacked here with the bundled libarchive.js,
// loaded only when one is dropped.

import { hashBlob } from "./sha256.js";

const $ = (id) => document.getElementById(id);
const CONCURRENCY = 3;
const JUNK = new Set(["__macosx", ".ds_store", "thumbs.db", "desktop.ini"]);
const CONTENT_DIRS = new Set(["models", "maps", "sound", "sprites", "gfx", "media", "resource", "events", "cl_dlls", "dlls"]);
const KIND_TEXT = {
  base: "Half-Life itself.",
  contentOnly: "Maps, models and sounds that run on Half-Life's code. Fully playable.",
  compiledIn: "Its game code is built into LambdaVision. Fully playable.",
  custom: "Ships its own game code, which can't run on Vision Pro. Its maps run on Half-Life's code, so its new weapons, enemies and features are missing.",
};
const isPhone = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);

let library = { games: [], orphanOverlays: [] };
let events = null;
let online = true;
let paired = false;

// ---------------------------------------------------------------- helpers

function bytes(n) {
  if (!n) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(u.length - 1, Math.floor(Math.log(n) / Math.log(1000)));
  const v = n / 1000 ** i;
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${u[i]}`;
}

function el(tag, props = {}, ...children) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "class") e.className = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else e[k] = v;
  }
  for (const c of children) if (c != null) e.append(c);
  return e;
}

class HTTPError extends Error {
  constructor(status, message, body) { super(message); this.status = status; this.body = body; }
}

async function api(method, path, body) {
  let res;
  try {
    res = await fetch(path, {
      method,
      credentials: "same-origin",
      headers: body ? { "Content-Type": "application/json" } : {},
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (e) {
    setOnline(false);
    throw new HTTPError(0, "Can't reach LambdaVision.");
  }
  setOnline(true);
  let data = {};
  try { data = await res.json(); } catch { /* empty */ }
  if (res.status === 401 && path !== "/api/pair") showPair();
  if (!res.ok) throw new HTTPError(res.status, data.error || `HTTP ${res.status}`, data);
  return data;
}

function addLog(text, level = "info") {
  const log = $("log");
  log.append(el("li", { class: level, textContent: text }));
  while (log.children.length > 300) log.firstChild.remove();
  log.scrollTop = log.scrollHeight;
}

// ---------------------------------------------------------------- screens

function showPair(message) {
  paired = false;
  closeEvents();
  $("pair").hidden = false;
  $("app").hidden = true;
  $("space").hidden = true;
  if (message) $("pair-error").textContent = message;
  $("pin").focus();
  uploader.pauseForAuth();
}

function showApp() {
  paired = true;
  $("pair").hidden = true;
  $("app").hidden = false;
  $("pair-error").textContent = "";
}

function setOnline(value) {
  if (online === value) return;
  online = value;
  $("offline").hidden = value;
  if (!value) scheduleReconnect();
}

let reconnectTimer = null;
function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(async () => {
    reconnectTimer = null;
    await boot();
    if (!online) scheduleReconnect();
  }, 3000);
}

async function boot() {
  let status;
  try {
    status = await api("GET", "/api/status");
  } catch (e) {
    if (e.status === 401) showPair();
    return;
  }
  showApp();
  renderStatus(status);
  await loadLibrary();
  openEvents();
  uploader.resumeAfterAuth();
}

// ---------------------------------------------------------------- pairing

$("pair-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const pin = $("pin").value.replace(/\D/g, "");
  if (pin.length !== 6) { $("pair-error").textContent = "The PIN has six digits."; return; }
  const button = e.submitter || $("pair-form").querySelector("button");
  button.disabled = true;
  try {
    await api("POST", "/api/pair", { pin });
    $("pin").value = "";
    await boot();
  } catch (err) {
    $("pair-error").textContent = err.message;
    $("pin").select();
  } finally {
    button.disabled = false;
  }
});

// ---------------------------------------------------------------- events

function openEvents() {
  if (events && events.readyState !== EventSource.CLOSED) return;
  events = new EventSource("/api/events");
  events.addEventListener("hello", (e) => {
    const d = JSON.parse(e.data);
    $("log").replaceChildren();
    for (const l of d.log) addLog(l.text, l.level);
    setImporting(d.importing);
  });
  events.addEventListener("log", (e) => { const l = JSON.parse(e.data); addLog(l.text, l.level); });
  events.addEventListener("importing", (e) => setImporting(JSON.parse(e.data).importing));
  events.addEventListener("importProgress", (e) => {
    $("import-state").textContent = `Importing… ${Math.round(JSON.parse(e.data).fraction * 100)}%`;
  });
  events.addEventListener("library", () => scheduleLibraryReload());
  events.onerror = () => {
    if (events.readyState === EventSource.CLOSED) { events = null; boot(); }
    else checkSoon();
  };
}

function closeEvents() {
  if (events) { events.close(); events = null; }
}

let checkTimer = null;
function checkSoon() {
  clearTimeout(checkTimer);
  checkTimer = setTimeout(() => api("GET", "/api/status").catch(() => {}), 1500);
}

function setImporting(on) {
  $("import-state").textContent = on ? "Importing…" : "";
  $("staged-install").disabled = on;
}

let reloadTimer = null;
function scheduleLibraryReload() {
  clearTimeout(reloadTimer);
  reloadTimer = setTimeout(async () => {
    await loadLibrary();
    try { renderStatus(await api("GET", "/api/status")); } catch { /* shown elsewhere */ }
  }, 300);
}

// ---------------------------------------------------------------- library

async function loadLibrary() {
  try { library = await api("GET", "/api/library"); } catch { return; }
  renderLibrary();
}

function renderStatus(status) {
  renderSpace(status.space);
  const staged = status.staged;
  const box = $("staged");
  if (staged.files > 0 && !uploader.running) {
    box.hidden = false;
    $("staged-text").textContent = `${staged.files} file${staged.files === 1 ? "" : "s"} (${bytes(staged.bytes)}) from an unfinished upload are waiting on the headset (${staged.gamedirs.join(", ")}). Choose the same folder again to send the rest, or install what's there.`;
  } else {
    box.hidden = true;
  }
  setImporting(status.importing);
}

function renderSpace(space) {
  if (!space || !space.total) return;
  const s = $("space");
  s.hidden = false;
  const used = 1 - space.free / space.total;
  s.replaceChildren(`${bytes(space.free)} free`, el("span", { class: "meter" }, el("span", { style: `width:${(used * 100).toFixed(1)}%` })));
  s.querySelector(".meter span").style.width = `${(used * 100).toFixed(1)}%`;
}

function renderLibrary() {
  renderSpace(library.space);
  const box = $("games");
  box.replaceChildren();
  $("games-empty").hidden = library.games.length + library.orphanOverlays.length > 0;
  const running = library.games.find((g) => g.gamedir === library.running);
  $("running").textContent = running ? `Running now: ${running.title}` : "";
  for (const g of library.games) box.append(gameCard(g));
  for (const o of library.orphanOverlays) box.append(orphanCard(o));
}

function gameCard(g) {
  const node = $("game-card").content.firstElementChild.cloneNode(true);
  node.classList.toggle("active", g.active);
  node.querySelector(".title").textContent = g.title;
  node.querySelector(".dir").textContent = [g.gamedir, ...g.overlays].join(" + ");
  const badge = node.querySelector(".badge");
  badge.textContent = g.kindLabel;
  badge.classList.add(g.kind);
  node.querySelector(".explain").textContent = KIND_TEXT[g.kind] || "";
  const facts = node.querySelector(".facts");
  if (g.active) facts.append(el("li", { class: "active-tag", textContent: "Plays next" }));
  facts.append(el("li", { textContent: bytes(g.size) }));
  facts.append(el("li", { textContent: g.hdOverlay ? "HD pack on" : "No HD pack" }));
  if (g.inUse) facts.append(el("li", { textContent: "In use by the running game" }));
  const warnings = node.querySelector(".warnings");
  for (const w of g.warnings) warnings.append(el("li", { textContent: w.text }));

  const activate = node.querySelector(".activate");
  activate.disabled = g.active;
  activate.textContent = g.active ? "Plays next" : "Play this";
  activate.addEventListener("click", async () => {
    activate.disabled = true;
    try {
      const r = await api("POST", "/api/active", { gamedir: g.gamedir });
      if (r.note) addLog(r.note, "info");
      await loadLibrary();
    } catch (e) { addLog(e.message, "error"); activate.disabled = false; }
  });
  wireDelete(node, g.gamedir, g.inUse,
    `Delete ${g.title}${g.overlays.length ? ` and ${g.overlays.join(", ")}` : ""} (${bytes(g.size)}) from the headset? This can't be undone.`);
  return node;
}

function orphanCard(o) {
  const node = $("game-card").content.firstElementChild.cloneNode(true);
  node.querySelector(".title").textContent = o.gamedir;
  node.querySelector(".dir").textContent = o.gamedir;
  const badge = node.querySelector(".badge");
  badge.textContent = "Add-on";
  const base = o.gamedir.replace(/_(hd|addon)$/i, "");
  node.querySelector(".explain").textContent = `An add-on for ${base}, which isn't installed. Upload ${base} to use it.`;
  node.querySelector(".facts").append(el("li", { textContent: bytes(o.size) }));
  node.querySelector(".activate").remove();
  wireDelete(node, o.gamedir, o.inUse, `Delete ${o.gamedir} (${bytes(o.size)}) from the headset?`);
  return node;
}

function wireDelete(node, gamedir, inUse, question) {
  const del = node.querySelector(".delete");
  const confirm = node.querySelector(".confirm");
  if (inUse) { del.disabled = true; del.title = "In use by the running game. Reopen LambdaVision to delete it."; }
  del.addEventListener("click", () => {
    confirm.hidden = false;
    confirm.querySelector("p").textContent = question;
    del.hidden = true;
  });
  confirm.querySelector(".confirm-no").addEventListener("click", () => { confirm.hidden = true; del.hidden = false; });
  confirm.querySelector(".confirm-yes").addEventListener("click", async (e) => {
    e.target.disabled = true;
    try { await api("POST", "/api/delete", { gamedir }); await loadLibrary(); }
    catch (err) { addLog(err.message, "error"); e.target.disabled = false; }
  });
}

// ---------------------------------------------------------------- picking files

const drop = $("drop");
if (isPhone) {
  $("pick-folder-label").hidden = true;
  drop.querySelector(".drop-title").textContent = "Choose a .zip, .7z or .rar";
}
drop.addEventListener("dragover", (e) => { e.preventDefault(); drop.classList.add("over"); });
drop.addEventListener("dragleave", () => drop.classList.remove("over"));
drop.addEventListener("drop", async (e) => {
  e.preventDefault();
  drop.classList.remove("over");
  const items = [...e.dataTransfer.items].map((i) => i.webkitGetAsEntry && i.webkitGetAsEntry()).filter(Boolean);
  if (items.length === 1 && items[0].isFile) {
    const file = await new Promise((res, rej) => items[0].file(res, rej));
    if (/\.(zip|7z|rar)$/i.test(file.name)) return handleArchive(file);
  }
  const entries = [];
  for (const item of items) await walkEntry(item, "", entries);
  handleTree(entries, null);
});
$("pick-folder").addEventListener("change", (e) => {
  const entries = [...e.target.files].map((f) => ({ path: f.webkitRelativePath || f.name, file: f }));
  e.target.value = "";
  handleTree(entries, null);
});
$("pick-archive").addEventListener("change", (e) => {
  const f = e.target.files[0];
  e.target.value = "";
  if (f) handleArchive(f);
});

async function walkEntry(entry, prefix, out) {
  const path = prefix ? `${prefix}/${entry.name}` : entry.name;
  if (entry.isFile) {
    out.push({ path, file: await new Promise((res, rej) => entry.file(res, rej)) });
    return;
  }
  const reader = entry.createReader();
  for (;;) {
    const batch = await new Promise((res, rej) => reader.readEntries(res, rej));
    if (!batch.length) break;
    for (const child of batch) await walkEntry(child, path, out);
  }
}

async function handleArchive(file) {
  if (/\.zip$/i.test(file.name)) return uploadZip(file);
  addLog(`Unpacking ${file.name} in the browser…`);
  let Archive;
  try {
    ({ Archive } = await import("./vendor/libarchive/libarchive.js"));
    Archive.init({ workerUrl: new URL("./vendor/libarchive/worker-bundle.js", import.meta.url).href });
  } catch (e) {
    addLog("This browser can't load the archive unpacker. Unpack it on your computer and drop the folder instead.", "error");
    return;
  }
  try {
    const archive = await Archive.open(file);
    if (await archive.hasEncryptedData()) {
      addLog("Password-protected archives aren't supported. Unpack it on your computer and drop the folder.", "error");
      return;
    }
    // libarchive.js 2.x doesn't call extractFiles' per-entry callback;
    // after extracting, getFilesArray holds Files instead of CompressedFiles.
    $("import-state").textContent = "Unpacking…";
    await archive.extractFiles();
    const entries = (await archive.getFilesArray())
      .filter((e) => e.file instanceof File)
      .map((e) => ({ path: (e.path || "") + e.file.name, file: e.file }));
    $("import-state").textContent = "";
    addLog(`Unpacked ${entries.length} files.`);
    handleTree(entries, file.name.replace(/\.(7z|rar)$/i, ""));
  } catch (e) {
    addLog(`Couldn't unpack ${file.name}: ${e.message || e}`, "error");
  }
}

// ---------------------------------------------------------------- finding game folders

function isJunk(parts) {
  return parts.some((p) => JUNK.has(p.toLowerCase()) || p.startsWith("._"));
}

// Mirrors GameImporter.findRoots: a folder holding liblist.gam/gameinfo.txt,
// or an overlay (or installed gamedir) holding game content; the shallowest
// such folders win. A root at the very top is named after the archive.
function detectRoots(entries, topName) {
  const installed = new Set(library.games.map((g) => g.gamedir.toLowerCase()));
  const files = [];
  const subdirs = new Map(); // dir path -> Set of its subfolder names, lowercased
  for (const { path, file } of entries) {
    const parts = path.replace(/\\/g, "/").split("/").filter((p) => p && p !== ".");
    if (!parts.length || parts.includes("..") || isJunk(parts)) continue;
    files.push({ parts, file });
    for (let i = 1; i < parts.length; i++) {
      const parent = parts.slice(0, i - 1).join("/");
      const dir = parts.slice(0, i).join("/");
      if (!subdirs.has(parent)) subdirs.set(parent, new Set());
      if (!subdirs.has(dir)) subdirs.set(dir, new Set());
      subdirs.get(parent).add(parts[i - 1].toLowerCase());
    }
  }
  const candidates = new Set();
  for (const { parts } of files) {
    const name = parts[parts.length - 1].toLowerCase();
    if (name === "liblist.gam" || name === "gameinfo.txt") candidates.add(parts.slice(0, -1).join("/"));
  }
  for (const [dir, subs] of subdirs) {
    if (!dir) continue;
    const base = dir.split("/").pop().toLowerCase();
    const overlay = /.+_(hd|addon)$/.test(base);
    if ((overlay || installed.has(base)) && [...subs].some((c) => CONTENT_DIRS.has(c))) candidates.add(dir);
  }
  const sorted = [...candidates].sort((a, b) => a.split("/").length - b.split("/").length || a.localeCompare(b));
  const roots = [];
  for (const c of sorted) {
    if (roots.some((r) => r.prefix === "" ? true : c === r.prefix || c.startsWith(r.prefix + "/"))) continue;
    const name = c === "" ? (topName || "") : c.split("/").pop();
    if (!name) continue;
    if (roots.some((r) => r.name.toLowerCase() === name.toLowerCase())) continue;
    roots.push({ prefix: c, name, files: [], bytes: 0 });
  }
  let outside = 0;
  for (const { parts, file } of files) {
    const path = parts.join("/");
    const root = roots.find((r) => r.prefix === "" || path.startsWith(r.prefix + "/"));
    if (!root) { outside++; continue; }
    const rel = root.prefix === "" ? path : path.slice(root.prefix.length + 1);
    root.files.push({ rel, file });
    root.bytes += file.size;
  }
  return { roots, outside, looseTop: roots.length === 0 && candidates.has("") };
}

function handleTree(entries, topName) {
  if (!entries.length) return;
  if (uploader.running) { addLog("An upload is already running.", "warning"); return; }
  const { roots, outside, looseTop } = detectRoots(entries, topName);
  if (!roots.length) {
    addLog(looseTop
      ? "Drop the game folder itself (the one holding liblist.gam), not the files inside it."
      : "No game folders found. A game folder holds a liblist.gam (like valve or gearbox).", "error");
    return;
  }
  const names = roots.map((r) => r.name.toLowerCase());
  const expansion = names.some((n) => n.startsWith("gearbox") || n.startsWith("bshift"));
  const box = $("plan-roots");
  box.replaceChildren();
  for (const r of roots) {
    const lower = r.name.toLowerCase();
    const game = library.games.find((g) => g.gamedir.toLowerCase() === lower || g.overlays.some((o) => o.toLowerCase() === lower));
    const inUse = game && game.inUse;
    let why = "";
    let checked = true;
    if (inUse) { why = "In use by the running game. Reopen LambdaVision to update it."; checked = false; }
    else if (expansion && (lower === "valve" || lower === "valve_hd")) {
      why = "Comes with the Opposing Force / Blue Shift download and is the newer 25th Anniversary build. Keep your steam_legacy Half-Life instead.";
      checked = false;
    }
    const input = el("input", { type: "checkbox", checked, disabled: !!inUse });
    input.root = r;
    box.append(el("label", {}, input, el("span", {},
      el("strong", { textContent: r.name }), ` — ${r.files.length} files, ${bytes(r.bytes)}`,
      why ? el("span", { class: "why", textContent: why }) : null)));
  }
  $("plan-note").textContent = outside ? `${outside} file${outside === 1 ? "" : "s"} outside these folders will be skipped.` : "";
  $("plan").hidden = false;
  $("plan").scrollIntoView({ behavior: "smooth", block: "nearest" });
}

$("plan-cancel").addEventListener("click", () => { $("plan").hidden = true; });
$("plan-start").addEventListener("click", () => {
  const roots = [...$("plan-roots").querySelectorAll("input:checked")].map((i) => i.root);
  if (!roots.length) return;
  $("plan").hidden = true;
  uploader.start(roots);
});

// ---------------------------------------------------------------- uploading

const uploader = {
  running: false,
  stopped: false,
  waitingForAuth: false,
  roots: null,
  xhrs: new Set(),

  start(roots) {
    this.roots = roots;
    this.run();
  },

  pauseForAuth() {
    if (!this.running) return;
    this.waitingForAuth = true;
    this.abortAll();
  },

  resumeAfterAuth() {
    if (this.waitingForAuth && this.roots) { this.waitingForAuth = false; this.run(); }
  },

  abortAll() {
    for (const x of this.xhrs) x.abort();
    this.xhrs.clear();
  },

  async run() {
    if (this.running) return;
    this.running = true;
    this.stopped = false;
    $("staged").hidden = true;
    $("progress").hidden = false;
    $("progress-stop").hidden = false;
    $("progress-resume").hidden = true;
    try {
      const todo = await this.diff();
      if (this.stopped) return;
      if (!todo) return;
      const ok = await this.send(todo);
      if (ok && !this.stopped) await this.commit();
    } catch (e) {
      if (!this.stopped) {
        $("progress-note").textContent = e.message;
        addLog(e.message, "error");
      }
    } finally {
      this.running = false;
      this.abortAll();
      if (this.stopped || this.waitingForAuth) {
        $("progress-title").textContent = this.waitingForAuth ? "Paused: enter the PIN to continue" : "Stopped";
        $("progress-stop").hidden = true;
        $("progress-resume").hidden = this.waitingForAuth;
      }
    }
  },

  async diff() {
    $("progress-title").textContent = "Comparing with the headset…";
    $("progress-note").textContent = "";
    const todo = [];
    let checked = 0;
    const total = this.roots.reduce((n, r) => n + r.files.length, 0);
    for (const root of this.roots) {
      const m = await api("GET", `/api/manifest?gamedir=${encodeURIComponent(root.name)}`);
      if (m.inUse) { addLog(`${root.name} is in use by the running game; skipped.`, "warning"); continue; }
      const installed = new Map(m.files.map((f) => [f.path.toLowerCase(), f]));
      const staged = new Map(m.staged.map((f) => [f.path.toLowerCase(), f]));
      for (const f of root.files) {
        if (this.stopped) return null;
        const key = f.rel.toLowerCase();
        if (!(await same(f.file, staged.get(key))) && !(await same(f.file, installed.get(key)))) {
          todo.push({ path: `${root.name}/${f.rel}`, file: f.file });
        }
        if (++checked % 50 === 0) {
          $("progress-detail").textContent = `${checked} of ${total} files`;
          setBar(checked / total);
        }
      }
    }
    if (!todo.length) {
      $("progress-title").textContent = "Already up to date";
      $("progress-detail").textContent = "";
      setBar(1);
      addLog("Everything is already on the headset.", "success");
      const st = await api("GET", "/api/status");
      if (st.staged.files > 0) await this.commit();
      return null;
    }
    return todo;
  },

  async send(todo) {
    const totalBytes = todo.reduce((n, t) => n + t.file.size, 0);
    await api("POST", "/api/upload/plan", { files: todo.length, bytes: totalBytes });
    $("progress-title").textContent = `Uploading ${todo.length} file${todo.length === 1 ? "" : "s"}`;
    let doneBytes = 0, doneFiles = 0, failed = 0;
    const inflight = new Map();
    const started = Date.now();
    const update = () => {
      const live = [...inflight.values()].reduce((a, b) => a + b, 0);
      const sent = doneBytes + live;
      setBar(totalBytes ? sent / totalBytes : doneFiles / todo.length);
      const rate = sent / Math.max(1, (Date.now() - started) / 1000);
      $("progress-detail").textContent = `${doneFiles} of ${todo.length} files · ${bytes(sent)} of ${bytes(totalBytes)} · ${bytes(rate)}/s`;
    };
    const queue = todo.slice();
    const worker = async () => {
      while (queue.length && !this.stopped && !this.waitingForAuth) {
        const item = queue.shift();
        let delay = 1000;
        for (;;) {
          if (this.stopped || this.waitingForAuth) { queue.unshift(item); return; }
          try {
            await this.put(item, (loaded) => { inflight.set(item, loaded); update(); });
            inflight.delete(item);
            doneBytes += item.file.size;
            doneFiles++;
            update();
            $("progress-note").textContent = "";
            break;
          } catch (e) {
            inflight.delete(item);
            if (e.status === 0) {
              // Dropped connection: wait and retry; staged files are kept.
              $("progress-note").textContent = "Connection lost. Retrying…";
              setOnline(false);
              await sleep(delay);
              delay = Math.min(delay * 2, 10000);
              continue;
            }
            if (e.status === 401) { this.pauseForAuth(); showPair("The headset restarted the server. Enter the new PIN to continue."); queue.unshift(item); return; }
            if (e.status === 507) { this.stopped = true; addLog("The headset is out of space.", "error"); return; }
            failed++;
            addLog(`${item.path}: ${e.message}`, "error");
            break;
          }
        }
      }
    };
    await Promise.all(Array.from({ length: CONCURRENCY }, worker));
    if (this.stopped || this.waitingForAuth) return false;
    if (failed) addLog(`${failed} file${failed === 1 ? "" : "s"} couldn't be sent; installing the rest.`, "warning");
    return true;
  },

  put(item, onProgress) {
    return new Promise((resolve, reject) => {
      const x = new XMLHttpRequest();
      this.xhrs.add(x);
      const q = `path=${encodeURIComponent(item.path)}&mtime=${item.file.lastModified / 1000}`;
      x.open("PUT", `/api/upload?${q}`);
      x.upload.onprogress = (e) => onProgress(e.loaded);
      x.onload = () => {
        this.xhrs.delete(x);
        if (x.status >= 200 && x.status < 300) { setOnline(true); resolve(); return; }
        let msg = `HTTP ${x.status}`;
        try { msg = JSON.parse(x.responseText).error || msg; } catch { /* keep */ }
        reject(new HTTPError(x.status, msg));
      };
      x.onerror = x.onabort = () => { this.xhrs.delete(x); reject(new HTTPError(0, "network")); };
      x.send(item.file);
    });
  },

  async commit() {
    $("progress-title").textContent = "Installing on the headset…";
    $("progress-note").textContent = "The import log below follows along.";
    $("progress-stop").hidden = true;
    await api("POST", "/api/commit");
    this.roots = null;
    $("progress-title").textContent = "Sent";
  },
};

async function same(file, entry) {
  if (!entry || entry.size !== file.size) return false;
  if (Math.abs(entry.mtime - file.lastModified / 1000) < 2) return true;
  if (!entry.sha256) return false;
  return (await hashBlob(file)) === entry.sha256;
}

function setBar(f) { $("progress-bar").style.width = `${Math.min(100, Math.max(0, f * 100)).toFixed(1)}%`; }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

$("progress-stop").addEventListener("click", () => {
  uploader.stopped = true;
  uploader.abortAll();
});
$("progress-resume").addEventListener("click", () => { if (uploader.roots) uploader.run(); });
$("staged-install").addEventListener("click", async () => {
  try { await api("POST", "/api/commit"); $("staged").hidden = true; } catch (e) { addLog(e.message, "error"); }
});
$("staged-discard").addEventListener("click", async () => {
  try { await api("POST", "/api/staging/discard"); $("staged").hidden = true; } catch (e) { addLog(e.message, "error"); }
});

function uploadZip(file) {
  if (uploader.running) { addLog("An upload is already running.", "warning"); return; }
  uploader.running = true;
  $("progress").hidden = false;
  $("progress-stop").hidden = false;
  $("progress-resume").hidden = true;
  $("progress-title").textContent = `Uploading ${file.name}`;
  $("progress-note").textContent = "A zip is installed whole; if the connection drops, send it again.";
  const x = new XMLHttpRequest();
  uploader.xhrs.add(x);
  const started = Date.now();
  x.open("PUT", `/api/upload-zip?name=${encodeURIComponent(file.name)}`);
  x.upload.onprogress = (e) => {
    setBar(e.loaded / file.size);
    const rate = e.loaded / Math.max(1, (Date.now() - started) / 1000);
    $("progress-detail").textContent = `${bytes(e.loaded)} of ${bytes(file.size)} · ${bytes(rate)}/s`;
  };
  const done = (title, level, msg) => {
    uploader.running = false;
    uploader.xhrs.delete(x);
    $("progress-title").textContent = title;
    $("progress-stop").hidden = true;
    if (msg) addLog(msg, level);
  };
  x.onload = () => {
    if (x.status >= 200 && x.status < 300) { done("Installing on the headset…", "info"); return; }
    let msg = `HTTP ${x.status}`;
    try { msg = JSON.parse(x.responseText).error || msg; } catch { /* keep */ }
    if (x.status === 401) showPair();
    done("Upload failed", "error", msg);
  };
  x.onerror = () => done("Upload interrupted", "error", "The connection dropped. Send the zip again when LambdaVision is reachable.");
  x.onabort = () => done("Stopped", "info");
  x.send(file);
}

// ---------------------------------------------------------------- SteamCMD instructions

function steamSteps(os, user) {
  const name = user || "YOUR_STEAM_NAME";
  if (os === "windows") {
    const exe = "C:\\steamcmd\\steamcmd.exe";
    return [
      { title: "1. Install SteamCMD", note: "Run these in PowerShell.",
        cmd: "New-Item -ItemType Directory -Force C:\\steamcmd | Out-Null; cd C:\\steamcmd\nInvoke-WebRequest https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip -OutFile steamcmd.zip\nExpand-Archive -Force steamcmd.zip ." },
      { title: "2. Download Half-Life (the steam_legacy build)",
        cmd: `${exe} +force_install_dir C:\\HalfLife +login ${name} +app_update 70 -beta steam_legacy validate +quit`,
        note: "Then drop C:\\HalfLife onto this page. LambdaVision picks out valve and valve_hd." },
      { title: "3. Opposing Force and Blue Shift (optional)",
        cmd: `${exe} +force_install_dir C:\\HalfLife-Expansions +login ${name} +app_update 50 validate +app_update 130 validate +quit`,
        note: expansionNote },
    ];
  }
  const linux = os === "linux";
  const tarball = linux ? "steamcmd_linux.tar.gz" : "steamcmd_osx.tar.gz";
  return [
    { title: "1. Install SteamCMD",
      cmd: `mkdir -p ~/steamcmd && cd ~/steamcmd\ncurl -sqL "https://steamcdn-a.akamaihd.net/client/installer/${tarball}" | tar zxvf -`,
      note: linux ? "SteamCMD is 32-bit: on Debian or Ubuntu, install lib32gcc-s1 first."
                  : "On a Mac with Apple silicon, accept if macOS offers to install Rosetta." },
    { title: "2. Download Half-Life (the steam_legacy build)",
      cmd: `~/steamcmd/steamcmd.sh +force_install_dir ~/HalfLife +login ${name} +app_update 70 -beta steam_legacy validate +quit`,
      note: "Then drop the HalfLife folder from your home folder onto this page. LambdaVision picks out valve and valve_hd." },
    { title: "3. Opposing Force and Blue Shift (optional)",
      cmd: `~/steamcmd/steamcmd.sh +force_install_dir ~/HalfLife-Expansions +login ${name} +app_update 50 validate +app_update 130 validate +quit`,
      note: expansionNote },
  ];
}
const expansionNote = "Keep these in their own folder: Steam installs them with a newer valve folder from the 25th Anniversary update, which must not replace your steam_legacy Half-Life. Drop the folder here and send only gearbox, bshift and their _hd folders (the page unticks valve for you).";

function detectOS() {
  const ua = navigator.userAgent;
  if (/Windows/i.test(ua)) return "windows";
  if (/Linux|X11/i.test(ua) && !/Android/i.test(ua)) return "linux";
  return "mac";
}

let currentOS = detectOS();
function renderSteps() {
  for (const b of document.querySelectorAll(".tabs button")) b.setAttribute("aria-selected", String(b.dataset.os === currentOS));
  const user = $("steam-name").value.trim().replace(/[^\w.@-]/g, "");
  $("howto-steps").replaceChildren(...steamSteps(currentOS, user).map((s) => {
    const pre = el("pre", { textContent: s.cmd });
    const copy = el("button", { type: "button", textContent: "Copy", onclick: () => copyText(pre, copy) });
    return el("div", { class: "step" }, el("h3", { textContent: s.title }),
      el("div", { class: "cmd" }, pre, copy), s.note ? el("p", { class: "muted small", textContent: s.note }) : null);
  }));
}

// navigator.clipboard needs a secure context, which a LAN http page isn't.
function copyText(pre, button) {
  const range = document.createRange();
  range.selectNodeContents(pre);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
  let ok = false;
  try { ok = document.execCommand("copy"); } catch { /* fall through */ }
  if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(pre.textContent); ok = true; }
  if (ok) sel.removeAllRanges();
  button.textContent = ok ? "Copied" : "Selected";
  setTimeout(() => { button.textContent = "Copy"; }, 1500);
}

for (const b of document.querySelectorAll(".tabs button")) b.addEventListener("click", () => { currentOS = b.dataset.os; renderSteps(); });
$("steam-name").addEventListener("input", renderSteps);
renderSteps();

boot();

// For poking at from the console (and the Mac smoke test).
export { detectRoots, handleTree, handleArchive };
