#!/usr/bin/env python3
"""Interactive UI test-plan runner for Langflow QA.

Serves a plan (JSON) as a single self-contained page Alice fills in, then writes
the results and any attachments to disk where Claude can read them.

    python3 runner.py --plan plan-LE-2316.json [--port N] [--out <dir>]
    (omit --port: a stable per-plan port in 8900-8999 is derived from the plan_id)

Stdlib only. On submit it writes:
    <out>/results.json                  the full submission
    <out>/attachments/<ITEM>-<n>.<ext>  each uploaded print/video
    results.json -> extras[]            findings added with "Adicionar finding"
                                        ({id: EXTRA-n, text, attachments}), files as EXTRA-n-<k>.<ext>
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import html
import json
import os
import re
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

MAX_BODY = 512 * 1024 * 1024  # 512 MB — videos are welcome

EXT_BY_MIME = {
    "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
    "image/webp": "webp", "video/mp4": "mp4", "video/quicktime": "mov",
    "video/webm": "webm", "application/pdf": "pdf",
}

# "Findings fora do plano": Alice often finds things no planned item covers. The
# button is always available and every click appends one more free-text card with
# its own attachments. They are submitted as results.json -> extras[].
EXTRAS_CSS = """
  .extras { margin-top:26px }
  .extras h2 { font-size:12px; text-transform:uppercase; letter-spacing:.08em; color:var(--muted); margin:0 0 6px }
  .extras .intro { font-size:13px; color:var(--muted); margin:0 0 12px }
  .card.extra { border-color:#2d3b55 }
  .card.extra h3 { color:var(--accent) }
  .card.extra .rmx { margin-left:auto; font:inherit; font-size:11px; font-weight:400; padding:2px 8px;
    cursor:pointer; color:var(--muted); background:transparent; border:1px solid var(--line); border-radius:6px }
  .card.extra .rmx:hover { color:var(--fail); border-color:var(--fail) }
  #add-extra { margin-top:2px }
"""

EXTRAS_HTML = """
<section class="extras" id="extras">
  <h2>Findings fora do plano</h2>
  <p class="intro">Viu algo que nenhum item cobre? Adicione quantos quiser — cada clique abre um novo campo.</p>
  <div id="extra-list"></div>
  <button type="button" id="add-extra">＋ Adicionar finding</button>
</section>"""

EXTRAS_JS = """
// ---- Findings fora do plano ------------------------------------------------
let extraSeq = 0;
function extraIds() {
  return [...document.querySelectorAll('#extras .card.extra')].map(c => c.dataset.id);
}
function addExtra(text, id) {
  if (id) {
    const n = parseInt(String(id).replace('EXTRA-', ''), 10);
    if (n > extraSeq) extraSeq = n;
  } else {
    extraSeq += 1; id = 'EXTRA-' + extraSeq;
  }
  if (document.getElementById('card-' + id)) return id;
  const art = document.createElement('article');
  art.className = 'card extra'; art.dataset.id = id; art.id = 'card-' + id;
  art.innerHTML = `
  <header>
    <h3>${id}</h3><span class="area">finding fora do plano</span>
    <button type="button" class="rmx" title="Remover este finding">remover</button>
  </header>
  <div class="body">
    <div class="detail">
      <label class="dlbl" for="d-${id}">Descreva o que você viu <span class="req">— obrigatório</span></label>
      <textarea id="d-${id}" rows="4" placeholder="Onde estava, o que fez, o que aconteceu e o que esperava. Se houve mensagem de erro, cole o texto exato."></textarea>
      <label class="dlbl" for="f-${id}">Anexos <span class="opt">— print, vídeo ou PDF (pode arrastar; escolha de novo para somar)</span><span class="fcount" data-fcount></span></label>
      <input type="file" id="f-${id}" multiple accept="image/*,video/*,application/pdf">
      <ul class="files" data-files></ul>
    </div>
  </div>`;
  document.getElementById('extra-list').appendChild(art);
  if (text) art.querySelector('textarea').value = text;
  return id;
}
document.getElementById('add-extra').onclick = () => {
  const id = addExtra('');
  document.getElementById('card-' + id).scrollIntoView({behavior:'smooth', block:'center'});
  document.getElementById('d-' + id).focus();
  refresh(); draft();
};
document.addEventListener('click', ev => {
  const b = ev.target.closest('.card.extra .rmx');
  if (!b) return;
  const card = b.closest('.card.extra'), id = card.dataset.id;
  const filled = card.querySelector('textarea').value.trim() || (files[id] || []).length;
  if (filled && !confirm(`Remover o finding ${id}?`)) return;
  delete files[id]; card.remove();
  refresh(); draft(); stage();
});
function collectExtras() {
  return extraIds().map(id => ({
    id,
    text: q(id, 'textarea').value.trim(),
    attachments: (files[id] || []).map(f => ({name:f.name, type:f.type, size:f.size, data:f.data}))
  })).filter(x => x.text || x.attachments.length);
}
"""


def _save_attachments(att_dir: str, prefix: str, atts) -> tuple[list, int]:
    """Decode base64 uploads to <att_dir>/<prefix>-<n>.<ext>; returns (kept, count)."""
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", str(prefix))
    kept, saved = [], 0
    for idx, a in enumerate(atts or [], 1):
        raw = base64.b64decode(a.get("data") or "")
        if not raw:
            continue
        ext = EXT_BY_MIME.get(a.get("type", ""), "")
        if not ext:
            ext = (os.path.splitext(a.get("name", ""))[1] or ".bin").lstrip(".")
        name = f"{safe}-{idx}.{ext}"
        with open(os.path.join(att_dir, name), "wb") as fh:
            fh.write(raw)
        kept.append({
            "file": os.path.join("attachments", name),
            "original_name": a.get("name"),
            "type": a.get("type"),
            "bytes": len(raw),
        })
        saved += 1
    return kept, saved


def md_inline(text: str) -> str:
    """Escape, then honour **bold** and `code` so plans can use light markdown."""
    out = html.escape(text)
    out = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"`(.+?)`", r"<code>\1</code>", out)
    return out


def _as_list(value) -> list[str]:
    """A step's `expect` may be one string or a list of checks."""
    if not value:
        return []
    if isinstance(value, (list, tuple)):
        return [str(v).strip() for v in value if str(v).strip()]
    return [str(value).strip()]


def _split_route(text: str) -> list[str]:
    """Legacy plans wrote a whole route on one line, joined by '→'. Break it into
    one line per step so old plans read vertically too."""
    parts = [p.strip().rstrip(".").strip() for p in re.split(r"\s*→\s*", text or "")]
    return [p for p in parts if p]


def _checks_html(checks: list[str]) -> str:
    if not checks:
        return ""
    return '<ul class="exp">' + "".join(f"<li>{md_inline(c)}</li>" for c in checks) + "</ul>"


def _steps_html(it: dict) -> str:
    """Render an item as a vertical, numbered walk-through.

    Preferred shape (one action per step, the checkpoint right under it):
        "start": "Logada como maria.local, em Settings › General",
        "steps": [ {"do": "Clique **Connect**", "expect": ["...", "..."]}, ... ]
    A step may also be a plain string (an action with nothing to check yet).
    Legacy shape: `actions` / `expected` strings, split on '→' into two lists.
    """
    start = it.get("start")
    start_html = (
        f'<div class="field"><span class="lbl">Começa em</span>'
        f'<p class="start">{md_inline(str(start))}</p></div>'
    ) if start else ""

    steps = it.get("steps")
    if isinstance(steps, list) and steps:
        rows = []
        for s in steps:
            if isinstance(s, dict):
                do = s.get("do") or s.get("action") or ""
                checks = _as_list(s.get("expect") or s.get("expected"))
            else:
                do, checks = str(s), []
            rows.append(f'<li><div class="do">{md_inline(str(do))}</div>{_checks_html(checks)}</li>')
        return (start_html
                + '<div class="field"><span class="lbl">Passo a passo '
                  '<span class="legend">— faça a ação, depois confira o que está marcado com ✓</span></span>'
                + f'<ol class="steps">{"".join(rows)}</ol></div>')

    actions = _split_route(it.get("actions", ""))
    expected = _split_route(it.get("expected", ""))
    acts = "".join(f'<li><div class="do">{md_inline(a)}</div></li>' for a in actions)
    return (start_html
            + f'<div class="field"><span class="lbl">Ações</span><ol class="steps">{acts}</ol></div>'
            + f'<div class="field"><span class="lbl">Resultado esperado</span>{_checks_html(expected)}</div>')


def _expected_text(spec: dict) -> str:
    """Plain-text expected result for results.json (findings doc / checklist)."""
    steps = spec.get("steps")
    if isinstance(steps, list) and steps:
        lines = []
        for n, s in enumerate(steps, 1):
            if isinstance(s, dict):
                checks = _as_list(s.get("expect") or s.get("expected"))
                if checks:
                    lines.append(f"{n}. " + "; ".join(checks))
        return "\n".join(lines)
    return spec.get("expected", "")


def _chip(label: str, value: str) -> str:
    """One copyable, independently-selectable credential value."""
    v = html.escape(str(value))
    lbl = f'<span class="lbl">{html.escape(label)}</span>' if label else ""
    return (f'<span class="pair">{lbl}<code>{v}</code>'
            f'<button type="button" class="cp" data-copy="{v}">copiar</button></span>')


def _creds_html(login) -> str:
    """Render `environment.Login` so each value can be selected on its own.

    Accepts three shapes:
      * a list of {role?, user, password?, note?} dicts  <- preferred
      * a single such dict
      * a plain string (legacy) -- rendered as before, one blob

    A plain string is what forced the tester to select user and password
    together, so new plans should always use the structured form.
    """
    if isinstance(login, str):
        return f"<code>{html.escape(login)}</code>"
    entries = login if isinstance(login, list) else [login]
    rows = []
    for e in entries:
        if not isinstance(e, dict):
            rows.append(f'<div class="cred"><code>{html.escape(str(e))}</code></div>')
            continue
        parts = []
        role = e.get("role") or e.get("papel") or e.get("label")
        if role:
            parts.append(f'<span class="role">{html.escape(str(role))}</span>')
        for key, label in (("user", "usuário"), ("username", "usuário"),
                           ("password", "senha"), ("senha", "senha"),
                           ("token", "token"), ("api_key", "api key")):
            if e.get(key):
                parts.append(_chip(label, e[key]))
        note = e.get("note") or e.get("nota")
        if note:
            parts.append(f'<span class="note">{md_inline(str(note))}</span>')
        rows.append(f'<div class="cred">{"".join(parts)}</div>')
    return "".join(rows)


def render(plan: dict) -> str:
    items = plan.get("items", [])
    env = plan.get("environment", {}) or {}
    notes = plan.get("notes", []) or []
    tickets = plan.get("tickets", []) or []
    summary = plan.get("pr_summary") or []
    if isinstance(summary, str):
        summary = [summary]

    # Login must always be present and must stand out — the tester should never
    # have to leave the plan to find out how to get in.
    login = next((v for k, v in env.items() if k.strip().lower() in ("login", "credenciais", "credentials")), None)
    login_html = (
        f'<div class="login"><span class="k">Login</span>'
        f'<div class="creds">{_creds_html(login)}</div></div>'
        if login else
        '<div class="login missing"><span class="k">Login</span>'
        '<em>não informado no plano — peça ao Claude</em></div>'
    )
    env_rows = "".join(
        f"<div class=envrow><dt>{html.escape(str(k))}</dt><dd>{md_inline(str(v))}</dd></div>"
        for k, v in env.items()
        if k.strip().lower() not in ("login", "credenciais", "credentials")
    )
    ticket_links = " · ".join(
        f'<a href="{html.escape(t["url"])}" target="_blank" rel="noopener">{html.escape(t["label"])}</a>'
        for t in tickets if t.get("url")
    )
    summary_html = (
        "<section class=prsummary><h2>O que este PR faz</h2><ul>"
        + "".join(f"<li>{md_inline(x)}</li>" for x in summary)
        + "</ul></section>"
    ) if summary else (
        "<section class='prsummary missing'><h2>O que este PR faz</h2>"
        "<p><em>Resumo ausente do plano — peça ao Claude antes de testar.</em></p></section>"
    )
    notes_html = (
        "<section class=notes><h2>Antes de começar</h2><ul>"
        + "".join(f"<li>{md_inline(n)}</li>" for n in notes)
        + "</ul></section>"
    ) if notes else ""

    cards = []
    for i, it in enumerate(items, 1):
        iid = html.escape(it["id"])
        flag = " attention" if it.get("attention") else ""
        badge = '<span class="flag" title="Item com atenção especial">atenção</span>' if it.get("attention") else ""
        cards.append(f"""
<article class="card{flag}" data-id="{iid}" id="card-{iid}">
  <header>
    <span class="num">{i}/{len(items)}</span>
    <h3>{iid}{badge}</h3>
    <span class="area">{md_inline(it.get('area',''))}</span>
    <span class="state" data-state></span>
  </header>
  <div class="body">
    {_steps_html(it)}
    <div class="choices" role="radiogroup" aria-label="Resultado de {iid}">
      <label class="ch pass"><input type="radio" name="s-{iid}" value="pass"><span>Passou</span></label>
      <label class="ch fail"><input type="radio" name="s-{iid}" value="fail"><span>Falhou</span></label>
      <label class="ch warn"><input type="radio" name="s-{iid}" value="warning"><span>Ressalva</span></label>
      <label class="ch na"><input type="radio" name="s-{iid}" value="na"><span>N/A</span></label>
      <label class="ch blocked"><input type="radio" name="s-{iid}" value="blocked"><span>Bloqueado</span></label>
    </div>
    <div class="detail" hidden>
      <label class="dlbl" for="d-{iid}">O que aconteceu <span class="req">— obrigatório</span></label>
      <textarea id="d-{iid}" rows="4" placeholder="Em qual passo (número) e o que você viu. Se houve mensagem de erro, cole o texto exato."></textarea>
      <label class="dlbl" for="f-{iid}">Anexos <span class="opt">— print, vídeo ou PDF (pode arrastar; escolha de novo para somar)</span><span class="fcount" data-fcount></span></label>
      <input type="file" id="f-{iid}" multiple accept="image/*,video/*,application/pdf">
      <ul class="files" data-files></ul>
    </div>
    <div class="always">
      <label class="dlbl small" for="n-{iid}">Observação (opcional)</label>
      <textarea id="n-{iid}" rows="2" class="small" placeholder="Algo que valha registrar mesmo tendo passado."></textarea>
    </div>
  </div>
</article>""")

    return f"""<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(plan.get('title','Plano de teste'))}</title>
<style>
  :root {{
    --bg:#0f1115; --panel:#171a21; --panel2:#1d212a; --line:#2a2f3a;
    --ink:#e7e9ee; --muted:#9aa3b2; --accent:#6aa3ff;
    --pass:#3fb950; --fail:#f85149; --warn:#d29922; --na:#7d8590; --blocked:#a371f7;
  }}
  * {{ box-sizing:border-box }}
  body {{ margin:0; background:var(--bg); color:var(--ink);
    font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; padding-bottom:120px }}
  a {{ color:var(--accent) }}
  code {{ background:#0b0d11; border:1px solid var(--line); border-radius:4px;
    padding:1px 5px; font-size:.88em; font-family:ui-monospace,SFMono-Regular,Menlo,monospace }}
  .wrap {{ max-width:1000px; margin:0 auto; padding:28px 20px }}
  h1 {{ font-size:24px; margin:0 0 4px }}
  .sub {{ color:var(--muted); margin:0 0 10px }}
  .tickets {{ font-size:13px; margin-bottom:18px }}
  .env, .prsummary {{ background:var(--panel); border:1px solid var(--line); border-radius:10px;
    padding:14px 16px; margin-bottom:16px }}
  .env h2, .notes h2, .prsummary h2 {{ font-size:12px; text-transform:uppercase;
    letter-spacing:.08em; color:var(--muted); margin:0 0 10px }}
  .prsummary ul {{ margin:0; padding-left:20px }}
  .prsummary li {{ margin:5px 0; font-size:13.5px }}
  .prsummary.missing, .login.missing {{ border-color:var(--fail) }}
  .login {{ display:flex; align-items:flex-start; gap:12px; background:var(--panel2);
    border:1px solid var(--accent); border-radius:10px; padding:12px 16px; margin-bottom:16px }}
  .login .k {{ font-size:11px; text-transform:uppercase; letter-spacing:.08em;
    color:var(--muted); padding-top:5px; flex:0 0 auto }}
  .login .creds {{ display:flex; flex-direction:column; gap:8px; min-width:0; flex:1 1 auto }}
  .login em {{ color:var(--fail); font-size:13px }}
  /* One credential per row. Each VALUE is its own chip so a click selects only
     that value -- a single blob forced the tester to select user+password
     together and retype by hand. */
  .cred {{ display:flex; align-items:center; gap:8px; flex-wrap:wrap }}
  .cred .role {{ font-size:12px; color:var(--muted); flex:0 0 auto }}
  .cred .pair {{ display:inline-flex; align-items:center; gap:4px }}
  .cred .lbl {{ font-size:10.5px; text-transform:uppercase; letter-spacing:.06em;
    color:var(--muted) }}
  .cred code {{ font-size:14px; padding:3px 9px; user-select:all; cursor:text;
    background:var(--panel); border:1px solid var(--border); border-radius:6px }}
  .cred .cp {{ font:inherit; font-size:11px; padding:2px 7px; cursor:pointer; color:var(--muted);
    background:transparent; border:1px solid var(--border); border-radius:6px }}
  .cred .cp:hover {{ color:var(--fg); border-color:var(--accent) }}
  .cred .cp.done {{ color:var(--pass); border-color:var(--pass) }}
  .cred .note {{ font-size:12px; color:var(--muted) }}
  .login code {{ font-size:14px; padding:3px 9px; user-select:all }}
  .envrow {{ display:flex; gap:12px; padding:3px 0; font-size:13.5px }}
  .envrow dt {{ color:var(--muted); min-width:120px; margin:0 }}
  .envrow dd {{ margin:0 }}
  .notes {{ background:#1a1710; border:1px solid #3d3320; border-radius:10px;
    padding:14px 16px; margin-bottom:22px }}
  .notes ul {{ margin:0; padding-left:20px }}
  .notes li {{ margin:5px 0; font-size:13.5px }}
  .card {{ background:var(--panel); border:1px solid var(--line); border-radius:10px;
    margin-bottom:14px; overflow:hidden }}
  .card.attention {{ border-color:#4a3a12 }}
  .card header {{ display:flex; align-items:center; gap:10px; padding:12px 16px;
    background:var(--panel2); border-bottom:1px solid var(--line); flex-wrap:wrap }}
  .card h3 {{ font-size:15px; margin:0; font-family:ui-monospace,Menlo,monospace }}
  .num {{ color:var(--muted); font-size:12px; font-variant-numeric:tabular-nums }}
  .area {{ color:var(--muted); font-size:13px }}
  .flag {{ background:#4a3a12; color:#e3b341; font-size:10.5px; text-transform:uppercase;
    letter-spacing:.06em; padding:2px 7px; border-radius:20px; margin-left:8px; vertical-align:1px }}
  .state {{ margin-left:auto; font-size:12px; font-weight:600; text-transform:uppercase;
    letter-spacing:.05em }}
  .body {{ padding:14px 16px }}
  .field {{ margin-bottom:10px }}
  .lbl {{ display:block; font-size:11px; text-transform:uppercase; letter-spacing:.07em;
    color:var(--muted); margin-bottom:3px }}
  .field p {{ margin:0 }}
  .field + .field {{ margin-top:12px }}
  .lbl .legend {{ text-transform:none; letter-spacing:0; font-size:11.5px; opacity:.85 }}
  .start {{ font-size:14px; padding:6px 10px; background:var(--panel2); border-radius:6px;
    border-left:3px solid var(--accent) }}
  /* One step per row: the action, and right under it what to check. */
  ol.steps {{ list-style:none; counter-reset:step; margin:4px 0 0; padding:0 }}
  ol.steps > li {{ counter-increment:step; position:relative; padding:9px 0 9px 38px;
    border-top:1px solid var(--line) }}
  ol.steps > li:first-child {{ border-top:none }}
  ol.steps > li::before {{ content:counter(step); position:absolute; left:2px; top:9px;
    width:24px; height:24px; border-radius:50%; background:var(--panel2);
    border:1px solid var(--line); color:var(--muted); font-size:12px; font-weight:600;
    display:flex; align-items:center; justify-content:center; font-variant-numeric:tabular-nums }}
  .steps .do {{ font-size:14.5px; line-height:1.5; padding-top:1px }}
  ul.exp {{ list-style:none; margin:5px 0 0; padding:0 }}
  ul.exp li {{ position:relative; padding:2px 0 2px 22px; font-size:13.5px; line-height:1.5;
    color:var(--ink); opacity:.92 }}
  ul.exp li::before {{ content:"✓"; position:absolute; left:3px; top:2px; color:var(--accent);
    font-weight:700 }}
  .choices {{ display:flex; gap:8px; flex-wrap:wrap; margin:14px 0 0 }}
  .ch {{ display:inline-flex; align-items:center; gap:6px; padding:7px 13px; cursor:pointer;
    border:1px solid var(--line); border-radius:8px; font-size:13.5px; user-select:none;
    background:#12151b }}
  .ch input {{ margin:0; accent-color:currentColor }}
  .ch:hover {{ border-color:#3a4150 }}
  .ch.pass:has(:checked) {{ border-color:var(--pass); color:var(--pass); background:#0e1c11 }}
  .ch.fail:has(:checked) {{ border-color:var(--fail); color:var(--fail); background:#1f1011 }}
  .ch.warn:has(:checked) {{ border-color:var(--warn); color:var(--warn); background:#1d1809 }}
  .ch.na:has(:checked) {{ border-color:var(--na); color:var(--na); background:#16181c }}
  .ch.blocked:has(:checked) {{ border-color:var(--blocked); color:var(--blocked); background:#170f22 }}
  .detail {{ margin-top:14px; padding:13px; background:#12151b; border:1px solid var(--line);
    border-radius:8px }}
  .dlbl {{ display:block; font-size:12px; color:var(--muted); margin:0 0 5px }}
  .dlbl.small {{ font-size:11px }}
  .req {{ color:var(--fail) }} .opt {{ color:var(--na) }}
  textarea {{ width:100%; background:#0b0d11; color:var(--ink); border:1px solid var(--line);
    border-radius:7px; padding:9px 10px; font:inherit; resize:vertical }}
  textarea.small {{ font-size:13px }}
  textarea:focus, input[type=file]:focus {{ outline:2px solid var(--accent); outline-offset:1px }}
  input[type=file] {{ width:100%; font-size:13px; color:var(--muted); margin-bottom:4px }}
  .always {{ margin-top:12px }}
  .files {{ list-style:none; margin:6px 0 0; padding:0; font-size:12.5px; color:var(--muted) }}
  .files li {{ padding:3px 0; display:flex; align-items:center; gap:8px }}
  .files .big {{ color:var(--warn) }}
  .files .rmf {{ font:inherit; font-size:11px; padding:1px 7px; cursor:pointer; color:var(--muted);
    background:transparent; border:1px solid var(--border); border-radius:6px; flex:0 0 auto }}
  .files .rmf:hover {{ color:var(--fail); border-color:var(--fail) }}
  .fcount {{ font-size:11.5px; color:var(--muted); margin-left:6px }}
  footer {{ position:fixed; inset:auto 0 0 0; background:rgba(15,17,21,.96);
    border-top:1px solid var(--line); backdrop-filter:blur(8px); padding:12px 20px }}
  .fwrap {{ max-width:1000px; margin:0 auto; display:flex; align-items:center; gap:16px;
    flex-wrap:wrap }}
  .counts {{ display:flex; gap:14px; font-size:13px; font-variant-numeric:tabular-nums }}
  .counts b {{ font-weight:600 }}
  .c-pass b {{ color:var(--pass) }} .c-fail b {{ color:var(--fail) }}
  .c-warn b {{ color:var(--warn) }} .c-rest b {{ color:var(--muted) }}
  .bar {{ flex:1; min-width:120px; height:6px; background:#22262f; border-radius:4px;
    overflow:hidden }}
  .bar i {{ display:block; height:100%; width:0; background:var(--accent); transition:width .2s }}
  button {{ font:inherit; font-weight:600; padding:10px 20px; border-radius:8px; cursor:pointer;
    border:1px solid var(--line); background:#22262f; color:var(--ink) }}
  button.primary {{ background:var(--accent); border-color:var(--accent); color:#07101f }}
  button:disabled {{ opacity:.45; cursor:not-allowed }}
  .hint {{ font-size:12px; color:var(--muted); width:100% }}
  .done {{ background:#0e1c11; border:1px solid var(--pass); border-radius:10px;
    padding:20px; text-align:center; margin-bottom:16px }}
  .done h2 {{ margin:0 0 6px; color:var(--pass); font-size:18px; text-transform:none;
    letter-spacing:0 }}
  .err {{ background:#1f1011; border:1px solid var(--fail); border-radius:8px; padding:12px;
    margin-bottom:12px; font-size:13.5px }}
  @media (prefers-color-scheme: light) {{
    :root {{ --bg:#f6f7f9; --panel:#fff; --panel2:#f0f2f5; --line:#d8dce3;
      --ink:#1c2029; --muted:#5c6470 }}
    code, textarea, .ch, .detail {{ background:#f6f7f9 }}
    footer {{ background:rgba(246,247,249,.96) }}
    .notes {{ background:#fdf8e8; border-color:#e6d8a8 }}
  }}
{EXTRAS_CSS}
</style></head><body>
<div class="wrap">
  <h1>{html.escape(plan.get('title','Plano de teste'))}</h1>
  <p class="sub">{html.escape(plan.get('subtitle',''))}</p>
  <p class="tickets">{ticket_links}</p>
  {login_html}
  <div id="banner"></div>
  {summary_html}
  <section class="env"><h2>Ambiente</h2>{env_rows}</section>
  {notes_html}
  <div id="cards">{''.join(cards)}</div>
{EXTRAS_HTML}
</div>
<footer><div class="fwrap">
  <div class="counts">
    <span class="c-pass">Passou <b id="n-pass">0</b></span>
    <span class="c-fail">Falhou <b id="n-fail">0</b></span>
    <span class="c-warn">Ressalva <b id="n-warn">0</b></span>
    <span class="c-rest">Outros <b id="n-rest">0</b></span>
    <span class="c-rest">Faltam <b id="n-todo">{len(items)}</b></span>
    <span class="c-rest">Extras <b id="n-extra">0</b></span>
  </div>
  <div class="bar"><i id="bar"></i></div>
  <button id="save">Salvar rascunho</button>
  <button id="submit" class="primary" disabled>Finalizar e enviar</button>
  <span class="hint" id="hint">Marque todos os {len(items)} itens. Itens com Falhou, Ressalva ou Bloqueado exigem descrição.</span>
</div></footer>
<script>
const PLAN_ID = {json.dumps(plan.get('plan_id','plan'))};
const IDS = {json.dumps([it['id'] for it in items])};
const KEY = 'qa-runner:' + PLAN_ID;
const LABEL = {{pass:'Passou', fail:'Falhou', warning:'Ressalva', na:'N/A', blocked:'Bloqueado'}};
const COLOR = {{pass:'var(--pass)', fail:'var(--fail)', warning:'var(--warn)', na:'var(--na)', blocked:'var(--blocked)'}};
const NEEDS_DETAIL = new Set(['fail','warning','blocked']);
const files = {{}};   // id -> [{{name,type,size,data}}]

// Copy one credential value. Each chip carries only its own value, so the
// tester never has to select user+password together and split them by hand.
document.addEventListener('click', (ev) => {{
  const b = ev.target.closest('.cred .cp');
  if (!b) return;
  const val = b.getAttribute('data-copy') || '';
  const done = () => {{
    const prev = b.textContent; b.textContent = 'copiado'; b.classList.add('done');
    setTimeout(() => {{ b.textContent = prev; b.classList.remove('done'); }}, 1200);
  }};
  if (navigator.clipboard && window.isSecureContext) {{
    navigator.clipboard.writeText(val).then(done, () => fallback(val, done));
  }} else {{ fallback(val, done); }}
}});
// http://localhost is a secure context in Chrome/Safari, but not every browser
// agrees, so keep a selection-based fallback rather than failing silently.
function fallback(val, done) {{
  const ta = document.createElement('textarea');
  ta.value = val; ta.setAttribute('readonly',''); ta.style.position='fixed'; ta.style.opacity='0';
  document.body.appendChild(ta); ta.select();
  try {{ document.execCommand('copy'); done(); }} catch (e) {{}}
  document.body.removeChild(ta);
}}

function q(id, sel) {{ return document.querySelector(`#card-${{id}} ${{sel}}`); }}
function statusOf(id) {{
  const el = document.querySelector(`input[name="s-${{id}}"]:checked`);
  return el ? el.value : null;
}}

function refresh() {{
  let c = {{pass:0, fail:0, warning:0, na:0, blocked:0}}, done = 0, blockers = [];
  for (const id of IDS) {{
    const s = statusOf(id);
    const badge = q(id, '[data-state]');
    const detail = q(id, '.detail');
    if (s) {{
      c[s]++; done++;
      badge.textContent = LABEL[s];
      badge.style.color = COLOR[s];
      const need = NEEDS_DETAIL.has(s);
      detail.hidden = !need;
      if (need && !q(id, 'textarea').value.trim()) blockers.push(id);
    }} else {{
      badge.textContent = '';
      detail.hidden = true;
    }}
  }}
  // Extra findings: a card with an attachment but no text blocks the submit; an
  // empty card is simply ignored.
  const xids = extraIds();
  for (const id of xids) {{
    if (!q(id, 'textarea').value.trim() && (files[id] || []).length) blockers.push(id);
  }}
  document.getElementById('n-extra').textContent = xids.length;
  document.getElementById('n-pass').textContent = c.pass;
  document.getElementById('n-fail').textContent = c.fail;
  document.getElementById('n-warn').textContent = c.warning;
  document.getElementById('n-rest').textContent = c.na + c.blocked;
  document.getElementById('n-todo').textContent = IDS.length - done;
  document.getElementById('bar').style.width = (done / IDS.length * 100) + '%';

  const ok = done === IDS.length && blockers.length === 0;
  document.getElementById('submit').disabled = !ok;
  const hint = document.getElementById('hint');
  if (done < IDS.length) hint.textContent = `Faltam ${{IDS.length - done}} item(ns) sem marcação.`;
  else if (blockers.length) hint.textContent = `Descrição obrigatória em: ${{blockers.join(', ')}}.`;
  else hint.textContent = 'Tudo preenchido — pode enviar.';
}}

function collect() {{
  return {{
    plan_id: PLAN_ID,
    submitted_at: new Date().toISOString(),
    items: IDS.map(id => ({{
      id,
      status: statusOf(id),
      description: q(id, '.detail textarea').value.trim(),
      note: q(id, '.always textarea').value.trim(),
      attachments: (files[id] || []).map(f => ({{name:f.name, type:f.type, size:f.size, data:f.data}}))
    }})),
    extras: collectExtras()
  }};
}}

function draft() {{
  const d = collect();
  d.items.forEach(i => i.attachments = []);   // anexos não vão pro localStorage
  (d.extras || []).forEach(x => x.attachments = []);
  try {{ localStorage.setItem(KEY, JSON.stringify(d)); }} catch (e) {{}}
}}

function restore() {{
  let d; try {{ d = JSON.parse(localStorage.getItem(KEY) || 'null'); }} catch (e) {{ return; }}
  if (!d) return;
  for (const it of d.items || []) {{
    if (!IDS.includes(it.id)) continue;
    if (it.status) {{
      const r = document.querySelector(`input[name="s-${{it.id}}"][value="${{it.status}}"]`);
      if (r) r.checked = true;
    }}
    if (it.description) q(it.id, '.detail textarea').value = it.description;
    if (it.note) q(it.id, '.always textarea').value = it.note;
  }}
  for (const x of d.extras || []) {{ if (x.id) addExtra(x.text || '', x.id); }}
  refresh();
}}

function fmt(n) {{ return n > 1048576 ? (n/1048576).toFixed(1)+' MB' : Math.max(1, Math.round(n/1024))+' KB'; }}

// Attachments are staged on the server as they change, so a reload (or a
// runner restart) no longer loses them the way in-memory-only storage did.
async function stage() {{
  try {{
    await fetch('/stage', {{method:'POST', headers:{{'Content-Type':'application/json'}},
                            body: JSON.stringify(files)}});
  }} catch (e) {{}}
}}

function renderFiles(id) {{
  const ul = q(id, '[data-files]');
  ul.innerHTML = '';
  (files[id] || []).forEach((f, idx) => {{
    const li = document.createElement('li');
    if (f.size > 60*1048576) li.className = 'big';
    const nm = document.createElement('span');
    nm.textContent = `${{f.name}} — ${{fmt(f.size)}}`;
    const rm = document.createElement('button');
    rm.type = 'button'; rm.className = 'rmf'; rm.textContent = 'remover';
    rm.title = 'Remover este anexo';
    rm.dataset.id = id; rm.dataset.idx = String(idx);
    li.append(nm, rm);
    ul.appendChild(li);
  }});
  const n = (files[id] || []).length;
  const c = q(id, '[data-fcount]');
  if (c) c.textContent = n ? `${{n}} anexo${{n > 1 ? 's' : ''}}` : '';
}}

document.addEventListener('change', async ev => {{
  if (ev.target.matches('input[type=radio]')) {{ refresh(); draft(); }}
  if (ev.target.matches('input[type=file]')) {{
    const id = ev.target.closest('.card').dataset.id;
    files[id] = files[id] || [];                 // ADD, never replace
    for (const f of ev.target.files) {{
      // Re-picking the same file (common when adding one more) must not duplicate it.
      if (files[id].some(x => x.name === f.name && x.size === f.size)) continue;
      const data = await new Promise(res => {{
        const r = new FileReader();
        r.onload = () => res(String(r.result).split(',')[1] || '');
        r.readAsDataURL(f);
      }});
      files[id].push({{name:f.name, type:f.type, size:f.size, data}});
    }}
    ev.target.value = '';                        // so the same file can be re-picked later
    renderFiles(id);
    stage();
  }}
}});

document.addEventListener('click', ev => {{
  const b = ev.target.closest('.rmf');
  if (!b) return;
  const id = b.dataset.id, idx = Number(b.dataset.idx);
  const f = (files[id] || [])[idx];
  if (!f) return;
  if (!confirm(`Remover o anexo "${{f.name}}"?`)) return;
  files[id].splice(idx, 1);
  if (!files[id].length) delete files[id];
  renderFiles(id);
  stage();
}});
document.addEventListener('input', ev => {{
  if (ev.target.matches('textarea')) {{ refresh(); draft(); }}
}});
document.getElementById('save').onclick = () => {{
  draft();
  const b = document.getElementById('save');
  b.textContent = 'Rascunho salvo'; setTimeout(() => b.textContent = 'Salvar rascunho', 1400);
}};

document.getElementById('submit').onclick = async () => {{
  const btn = document.getElementById('submit');
  btn.disabled = true; btn.textContent = 'Enviando…';
  const banner = document.getElementById('banner');
  banner.innerHTML = '';
  try {{
    const r = await fetch('/submit', {{
      method: 'POST',
      headers: {{'Content-Type': 'application/json'}},
      body: JSON.stringify(collect())
    }});
    if (!r.ok) throw new Error('HTTP ' + r.status + ' — ' + (await r.text()).slice(0,200));
    const j = await r.json();
    localStorage.removeItem(KEY);
    document.getElementById('cards').innerHTML = '';
    const xs = document.getElementById('extras'); if (xs) xs.remove();
    document.querySelector('footer').remove();
    document.body.style.paddingBottom = '20px';
    banner.innerHTML = `<div class=done><h2>Resultado enviado</h2>
      <p>${{j.items}} itens, ${{j.extras}} finding(s) fora do plano e ${{j.attachments}} anexo(s) gravados. Pode fechar esta aba e voltar pro Claude — ele já consegue ler o resultado.</p>
      <p style="color:var(--muted);font-size:12.5px">${{j.results_path}}</p></div>`;
    window.scrollTo({{top:0, behavior:'smooth'}});
  }} catch (e) {{
    banner.innerHTML = `<div class=err><strong>Falha ao enviar.</strong> ${{e.message}}<br>
      O rascunho continua salvo no navegador — se o servidor caiu, avise o Claude e tente de novo.</div>`;
    btn.disabled = false; btn.textContent = 'Finalizar e enviar';
    window.scrollTo({{top:0, behavior:'smooth'}});
  }}
}};

{EXTRAS_JS}
restore(); refresh();
// Pull back anything staged before a reload / runner restart.
fetch('/staged').then(r => r.json()).then(d => {{
  let n = 0;
  for (const [id, list] of Object.entries(d || {{}})) {{
    if (!Array.isArray(list) || !list.length) continue;
    if (id.startsWith('EXTRA-')) {{ if (!document.getElementById('card-' + id)) addExtra('', id); }}
    else if (!IDS.includes(id)) continue;
    files[id] = list; renderFiles(id); n += list.length;
  }}
  if (n) console.info(`[runner] ${{n}} anexo(s) recuperados do servidor`);
}}).catch(() => {{}});
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    plan: dict = {}
    out_dir: str = "."

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    # Attachments used to live ONLY in page memory, so any reload silently dropped
    # them while marks/descriptions survived in localStorage. They are now staged
    # on disk as they are added, and rehydrated on load.
    @property
    def staged_path(self) -> str:
        return os.path.join(self.out_dir, ".staged.json")

    def _read_staged(self) -> dict:
        try:
            with open(self.staged_path, encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return {}

    def do_GET(self) -> None:  # noqa: N802
        route = self.path.split("?")[0]
        if route in ("/", "/index.html"):
            self._send(200, render(self.plan).encode("utf-8"), "text/html; charset=utf-8")
        elif route == "/staged":
            body = json.dumps(self._read_staged()).encode("utf-8")
            self._send(200, body, "application/json")
        else:
            self._send(404, b"not found", "text/plain; charset=utf-8")

    def do_POST(self) -> None:  # noqa: N802
        route = self.path.split("?")[0]
        if route == "/stage":
            try:
                n = int(self.headers.get("Content-Length") or 0)
                if n < 0 or n > MAX_BODY:
                    raise ValueError(f"corpo invalido ({n} bytes)")
                staged = json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
                tmp = self.staged_path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as fh:
                    json.dump(staged, fh)
                os.replace(tmp, self.staged_path)   # atomic: never a half-written stage
            except Exception as exc:  # noqa: BLE001
                self._send(400, str(exc).encode("utf-8"), "text/plain; charset=utf-8")
                return
            self._send(200, b'{"ok":true}', "application/json")
            return
        if route != "/submit":
            self._send(404, b"not found", "text/plain; charset=utf-8")
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > MAX_BODY:
                raise ValueError(f"corpo inválido ({n} bytes)")
            payload = json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            self._send(400, str(exc).encode("utf-8"), "text/plain; charset=utf-8")
            return

        att_dir = os.path.join(self.out_dir, "attachments")
        os.makedirs(att_dir, exist_ok=True)
        saved = 0
        by_id = {it["id"]: it for it in self.plan.get("items", [])}

        for item in payload.get("items", []):
            spec = by_id.get(item.get("id"), {})
            item["area"] = spec.get("area", "")
            item["expected"] = _expected_text(spec)
            if spec.get("steps"):
                item["start"] = spec.get("start", "")
                item["steps"] = spec["steps"]
            item["attachments"], n = _save_attachments(att_dir, item["id"], item.get("attachments"))
            saved += n

        # Findings Alice added outside the plan ("Adicionar finding"): free text + media.
        extras = []
        for k, x in enumerate(payload.get("extras") or [], 1):
            xid = str(x.get("id") or f"EXTRA-{k}")
            kept, n = _save_attachments(att_dir, xid, x.get("attachments"))
            saved += n
            text = (x.get("text") or "").strip()
            if text or kept:
                extras.append({"id": xid, "text": text, "attachments": kept})
        payload["extras"] = extras

        payload["plan_title"] = self.plan.get("title")
        payload["environment"] = self.plan.get("environment")
        payload["received_at"] = datetime.now(timezone.utc).isoformat()
        results_path = os.path.join(self.out_dir, "results.json")
        with open(results_path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)

        # results.json now owns the attachments; drop the staging copy.
        try:
            os.remove(self.staged_path)
        except OSError:
            pass

        tally: dict[str, int] = {}
        for it in payload.get("items", []):
            tally[it.get("status") or "?"] = tally.get(it.get("status") or "?", 0) + 1
        print(f"\n>>> RESULTADO RECEBIDO  {results_path}")
        print(f"    {tally}  extras={len(extras)}  anexos={saved}", flush=True)

        self._send(200, json.dumps({
            "ok": True,
            "items": len(payload.get("items", [])),
            "attachments": saved,
            "extras": len(extras),
            "results_path": results_path,
        }).encode("utf-8"), "application/json")

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("runner: " + (fmt % args) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--port", type=int, default=0,
                    help="0 (default) derives a stable per-plan port in 8900-8999 so two "
                         "concurrent QA sessions never collide.")
    ap.add_argument("--out")
    a = ap.parse_args()

    with open(a.plan, encoding="utf-8") as fh:
        plan = json.load(fh)

    if not a.port:
        # Stable per-plan port: the same plan always reopens on the same URL, and two
        # sessions running different plans get different ports without coordinating.
        digest = hashlib.sha256(plan.get("plan_id", a.plan).encode("utf-8")).digest()
        a.port = 8900 + (digest[0] << 8 | digest[1]) % 100
    out = a.out or os.path.join(os.path.dirname(os.path.abspath(a.plan)),
                               "runs", plan.get("plan_id", "plan"))
    os.makedirs(out, exist_ok=True)

    Handler.plan = plan
    Handler.out_dir = out
    try:
        server = HTTPServer(("127.0.0.1", a.port), Handler)
    except OSError as exc:
        # Never fail quietly here: another runner still holding the port would keep
        # serving its own (stale) plan, and the tester would fill in the wrong one.
        print(f"ERRO: não consegui abrir a porta {a.port} ({exc}).", file=sys.stderr)
        print(f"      Algo já está escutando nela e continuaria servindo OUTRO plano.",
              file=sys.stderr)
        print(f"      Feche o runner antigo (lsof -ti :{a.port} | xargs kill) e rode de novo.",
              file=sys.stderr, flush=True)
        raise SystemExit(2) from exc
    print(f"Plano  : {plan.get('title')} ({len(plan.get('items', []))} itens)")
    print(f"Abra   : http://localhost:{a.port}")
    print(f"Saída  : {out}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
