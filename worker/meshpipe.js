'use strict';
/*
  Une connexion PERMANENTE à MeshCentral pour pc-management (lot 5).

  meshctrl 1.2.5 ouvre une session par commande, et marque chaque demande
  `responseid: 'meshctrl'` : la réponse d'un poste revient à TOUTES les
  sessions du compte (le serveur n'y met pas de sessionid) et chaque meshctrl
  prend la première venue. Deux meshctrl en même temps se volent donc leurs
  réponses : d'où « un poste à la fois ».

  Ici, une seule session, gardée ouverte, et un `responseid` propre à chaque
  demande (« pcm-<id> »), que l'agent renvoie tel quel : les réponses se
  rangent sans erreur, et plusieurs postes travaillent en même temps. Un agent
  ne fait qu'une commande à la fois (il ignore la seconde) : les demandes
  d'un même poste attendent leur tour ici.

  Le certificat du serveur est vérifié (l'adresse publique, derrière Traefik,
  a un certificat valide). Pour une autorité interne : NODE_EXTRA_CA_CERTS.

  Entrée (stdin), une ligne JSON par demande :
      { "id": "12", "node": "node//abc", "cmds": "...", "type": 2 }
      { "cancel": "12" }
  Sortie (stdout), une ligne JSON par événement :
      { "event": "ready" }            session ouverte
      { "event": "down", "reason" }   session perdue, reconnexion en cours
      { "id": "12", "output": "..." } réponse du poste
      { "id": "12", "error": "..." }  refus du serveur, ou session perdue

  Identifiants : MESHPIPE_URL (wss://hote), MESHPIPE_USER, MESHPIPE_PASS,
  MESHPIPE_TOKEN, lus dans l'environnement et jamais affichés. Le module
  `ws` vient du paquet meshcentral (NODE_PATH).
*/

const WebSocket = require('ws');
const readline = require('readline');

function emit(o) {
  process.stdout.write(JSON.stringify(o) + '\n');
}

const url = (() => {
  let u = process.env.MESHPIPE_URL || '';
  if (!/^wss?:\/\//.test(u)) {
    emit({ event: 'down', reason: 'MESHPIPE_URL manquante ou illisible' });
    process.exit(2);
  }
  if (!u.endsWith('/')) u += '/';
  return u + 'control.ashx';
})();

const b64 = (s) => Buffer.from(String(s)).toString('base64');
function headers() {
  const user = process.env.MESHPIPE_USER || 'admin';
  const pass = process.env.MESHPIPE_PASS || '';
  const token = process.env.MESHPIPE_TOKEN ? ',' + b64(process.env.MESHPIPE_TOKEN) : '';
  return { 'x-meshauth': b64(user) + ',' + b64(pass) + token };
}

let ws = null;
let open = false;
let retry = 2000;
let refusal = null;
const queues = new Map(); // poste -> demandes en attente
const running = new Map(); // poste -> demande en cours
const byResponse = new Map(); // responseid -> demande

function release(req) {
  byResponse.delete('pcm-' + req.id);
  if (running.get(req.node) === req) running.delete(req.node);
}

function pump(node) {
  if (!open || running.has(node)) return;
  const q = queues.get(node);
  if (!q || !q.length) return;
  const req = q.shift();
  running.set(node, req);
  byResponse.set('pcm-' + req.id, req);
  try {
    ws.send(JSON.stringify({ action: 'runcommands', nodeids: [node], type: req.type || 2, cmds: req.cmds, responseid: 'pcm-' + req.id, runAsUser: 0, reply: true }));
  } catch (e) {
    release(req);
    emit({ id: req.id, error: 'envoi impossible : ' + e.message });
    pump(node);
  }
}

function finish(req, line) {
  release(req);
  emit(line);
  pump(req.node);
}

function connect() {
  ws = new WebSocket(url, { headers: headers() });
  ws.on('open', () => {
    open = true;
    retry = 2000;
    refusal = null;
    emit({ event: 'ready' });
    for (const node of queues.keys()) pump(node);
  });
  ws.on('message', (raw) => {
    let data = null;
    try {
      data = JSON.parse(raw);
    } catch (e) {
      return;
    }
    if (!data) return;
    if (typeof data.responseid !== 'string' || !data.responseid.startsWith('pcm-')) {
      if (data.action === 'close') {
        refusal = 'session refusée par le serveur : ' + (data.cause || data.msg || '?');
        emit({ event: 'down', reason: refusal });
      }
      return;
    }
    const req = byResponse.get(data.responseid);
    if (!req) return;
    if (data.type === 'runcommands' && typeof data.result === 'string') {
      finish(req, { id: req.id, output: data.result });
    } else if (data.action === 'runcommands' && data.result !== 'OK') {
      finish(req, { id: req.id, error: String(data.result || 'refusé') });
    }
  });
  ws.on('error', (e) => emit({ event: 'down', reason: e.code || e.message }));
  ws.on('close', () => {
    open = false;
    for (const req of [...running.values()]) {
      release(req);
      emit({ id: req.id, error: refusal || 'session MeshCentral perdue pendant la commande' });
    }
    emit({ event: 'down', reason: refusal || 'session fermée' });
    setTimeout(connect, retry);
    retry = Math.min(60000, retry * 2);
  });
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  let m = null;
  try {
    m = JSON.parse(line);
  } catch (e) {
    return;
  }
  if (m.cancel != null) {
    const id = String(m.cancel);
    for (const [node, q] of queues) {
      const i = q.findIndex((r) => r.id === id);
      if (i >= 0) q.splice(i, 1);
      const r = running.get(node);
      // L'agent finit sa commande de toute façon : la place se libère, une
      // réponse tardive est ignorée.
      if (r && r.id === id) {
        release(r);
        pump(node);
      }
    }
    return;
  }
  if (typeof m.id !== 'string' || typeof m.node !== 'string' || typeof m.cmds !== 'string') return;
  if (!open) {
    emit({ id: m.id, error: 'MeshCentral injoignable (session en cours de rétablissement)' });
    return;
  }
  if (!queues.has(m.node)) queues.set(m.node, []);
  queues.get(m.node).push({ id: m.id, node: m.node, cmds: m.cmds, type: m.type });
  pump(m.node);
});

process.stdin.on('end', () => process.exit(0));
connect();
