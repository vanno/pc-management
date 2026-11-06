"""La page de la console (un seul fichier, sans ressource externe : elle marche
sans internet)."""

PAGE_CODE = """<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Console régie</title><style>
body{margin:0;font:16px system-ui,sans-serif;background:#111418;color:#e8eaed;display:grid;place-items:center;min-height:100vh}
form{background:#1b2027;padding:28px;border-radius:12px;width:min(360px,90vw)}
input{font:inherit;width:100%;box-sizing:border-box;padding:10px;margin:12px 0;border-radius:8px;border:1px solid #3a424d;background:#0d1014;color:inherit;letter-spacing:.3em;text-align:center}
button{font:inherit;width:100%;padding:10px;border:0;border-radius:8px;background:#3b82f6;color:#fff}
p{color:#aab2bd;font-size:14px}.e{color:#f87171}
</style></head><body><form method="get" action="/entrer"><b>Console régie</b>
<p>Entrez le code affiché sur la console, dans la fenêtre ou sur sa page.</p>
<input name="code" inputmode="numeric" autocomplete="off" autofocus maxlength="6"><button>Ouvrir</button><p class="e">{{ERREUR}}</p></form></body></html>"""

PAGE = r"""<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Console régie</title>
<style>
:root{--fond:#111418;--carte:#1b2027;--trait:#2c333d;--texte:#e8eaed;--doux:#9aa4b1;--ok:#22c55e;--alerte:#f59e0b;--hl:#6b7280;--rouge:#ef4444;--bleu:#3b82f6}
*{box-sizing:border-box}
body{margin:0;font:15px/1.4 system-ui,"Segoe UI",sans-serif;background:var(--fond);color:var(--texte)}
header{display:flex;flex-wrap:wrap;gap:12px 24px;align-items:center;padding:14px 20px;border-bottom:1px solid var(--trait);position:sticky;top:0;background:var(--fond);z-index:2}
header h1{font-size:18px;margin:0}
.compte{display:flex;gap:10px;flex-wrap:wrap}
.pastille{padding:3px 10px;border-radius:999px;font-weight:600;font-size:13px}
.p-ok{background:#14532d;color:#bbf7d0}.p-alerte{background:#78350f;color:#fde68a}.p-hors_ligne{background:#374151;color:#e5e7eb}
.doux{color:var(--doux)}
main{padding:16px 20px;max-width:1600px;margin:0 auto}
h2{font-size:15px;text-transform:uppercase;letter-spacing:.06em;color:var(--doux);margin:26px 0 10px}
.grille{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:12px}
.poste{background:var(--carte);border:1px solid var(--trait);border-left:6px solid var(--hl);border-radius:10px;padding:12px 14px;cursor:pointer}
.poste.ok{border-left-color:var(--ok)}.poste.alerte{border-left-color:var(--alerte)}.poste.choisi{outline:2px solid var(--bleu)}
.poste .tete{display:flex;justify-content:space-between;align-items:baseline;gap:8px}
.poste b{font-size:20px}
.chiffres{display:grid;grid-template-columns:repeat(3,1fr);gap:4px;margin:8px 0 4px;font-variant-numeric:tabular-nums}
.chiffres div span{display:block;font-size:11px;color:var(--doux);text-transform:uppercase}
.al{color:#fcd34d;font-size:13px;margin:2px 0}
.vide{padding:24px;background:var(--carte);border-radius:10px;color:var(--doux)}
table{border-collapse:collapse;width:100%;background:var(--carte);border-radius:10px;overflow:hidden;font-size:14px}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--trait)}
th{color:var(--doux);font-weight:500}
.rem{color:#fcd34d}.conflit{color:var(--rouge);font-weight:600}
.bloc{overflow-x:auto;background:var(--carte);border:1px solid var(--trait);border-radius:10px;padding:14px 16px;margin-bottom:12px}
pre.mono{white-space:pre-wrap;background:#0d1014;padding:10px;border-radius:8px}
.bloc code,.mono{font-family:ui-monospace,Consolas,monospace;font-size:13px;word-break:break-all}
input[type=text]{font:inherit;padding:7px 9px;border-radius:7px;border:1px solid #3a424d;background:#0d1014;color:inherit;min-width:260px;max-width:100%}
button{font:inherit;padding:7px 12px;border:0;border-radius:7px;background:var(--bleu);color:#fff;cursor:pointer}
button.second{background:#2c333d}
.ligne{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:6px 0}
svg{display:block;width:100%;height:120px;background:#0d1014;border-radius:8px}
.deux{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px}
details summary{cursor:pointer;color:var(--doux)}
</style>
</head>
<body>
<header>
  <h1 id="nom">Console régie</h1>
  <div class="compte" id="compte"></div>
  <div class="doux" id="info"></div>
</header>
<main>
  <section><h2>Postes</h2><div class="grille" id="postes"></div></section>
  <section id="detail" hidden><h2 id="detail-titre"></h2><div class="deux">
    <div class="bloc"><div class="doux">Processeur (%) sur 2 h</div><svg id="g-cpu" viewBox="0 0 600 120" preserveAspectRatio="none"></svg></div>
    <div class="bloc"><div class="doux">Passerelle (ms) sur 2 h</div><svg id="g-gw" viewBox="0 0 600 120" preserveAspectRatio="none"></svg></div>
  </div><div class="bloc" id="detail-cartes"></div></section>
  <section><h2>Réseaux</h2><div id="reseaux"></div></section>
  <section><h2>Companion</h2><div class="bloc" id="companion"></div></section>
  <section id="sec-appairage" hidden><h2>Appairage et accès</h2><div id="appairage"></div></section>
</main>
<script>
"use strict";
let choisi = null, dernier = null;
const $ = id => document.getElementById(id);
const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const pct = v => v == null ? "—" : Math.round(v) + " %";
const ms = v => v == null ? "—" : (v < 10 ? v.toFixed(1) : Math.round(v)) + " ms";
function debit(b){ if(!b) return "0"; const u=["b/s","kb/s","Mb/s","Gb/s"]; let i=0; while(b>=1000&&i<3){b/=1000;i++} return (b<10?b.toFixed(1):Math.round(b))+" "+u[i]; }
function age(s){ if(s<90) return "à l'instant"; if(s<3600) return "il y a "+Math.round(s/60)+" min"; return "il y a "+Math.round(s/3600)+" h"; }

async function charger(){
  try{
    const r = await fetch("/api/etat",{cache:"no-store"});
    if(r.status===401){ location.href="/entrer"; return; }
    dernier = await r.json();
    afficher(dernier);
  }catch(e){ $("info").textContent = "Console injoignable : "+e; }
}

function afficher(d){
  const c = d.console;
  $("nom").textContent = c.nom;
  document.title = c.nom;
  $("compte").innerHTML = `<span class="pastille p-ok">${d.compte.ok} OK</span><span class="pastille p-alerte">${d.compte.alerte} en alerte</span><span class="pastille p-hors_ligne">${d.compte.hors_ligne} hors ligne</span>`;
  $("info").textContent = `Adresses : ${c.adresses.join(", ") || "aucune"} · HTTPS ${c.port_https} · ${c.recues} envois reçus`;
  const P = d.postes;
  $("postes").innerHTML = P.length ? P.map(p => `
    <div class="poste ${p.etat} ${p.reference===choisi?"choisi":""}" data-ref="${esc(p.reference)}">
      <div class="tete"><b>${esc(p.reference)}</b><span class="pastille p-${p.etat}">${esc(p.etiquette)}</span></div>
      <div class="doux">${esc(p.adresses.join(", ") || p.adresse || "")} · ${age(p.age)}</div>
      <div class="chiffres"><div><span>CPU</span>${pct(p.cpu)}</div><div><span>Mémoire</span>${pct(p.ram)}</div><div><span>Disque libre</span>${pct(p.disque)}</div>
      <div><span>Passerelle</span>${ms(p.passerelle_ms)}</div><div><span>Reçu</span>${debit(p.rx)}</div><div><span>Envoyé</span>${debit(p.tx)}</div></div>
      ${p.vmix?`<div class="doux">vMix : <b>${esc(p.vmix)}</b>${p.vmix_detail&&p.vmix_detail.recording_s!=null&&p.vmix_detail.recording?` · enregistrement ${Math.floor(p.vmix_detail.recording_s/60)} min`:""}${p.vmix_detail&&p.vmix_detail.dropped!=null?` · ${p.vmix_detail.dropped} images perdues au journal`:""}</div>`:""}
      ${p.alertes.map(a => `<div class="al">${esc(a)}</div>`).join("")}
      ${p.internet===false?'<div class="doux">Pas d\'internet</div>':""}
    </div>`).join("") : `<div class="vide">Aucune sonde n'a encore écrit à cette console. Vérifiez que le code d'appairage est posé sur le relais du NAS (voir plus bas), puis que les postes ont été supervisés à nouveau depuis AVDiagram.</div>`;
  document.querySelectorAll(".poste").forEach(el => el.onclick = () => { choisi = el.dataset.ref; afficher(dernier); detail(); });
  // Réseaux
  $("reseaux").innerHTML = d.reseaux.length ? d.reseaux.map(g => `
    <div class="bloc"><b>${esc(g.reseau)}</b> <span class="doux">${g.membres.length} carte(s) · passerelle ${esc(g.passerelles.join(", ")||"aucune")}</span>
    ${g.remarques.map(r => `<div class="${g.conflit&&r.startsWith("Adresse")?"conflit":"rem"}">${esc(r)}</div>`).join("")}
    <table><tr><th>Poste</th><th>Adresse</th><th>Carte</th><th>Mode</th><th>Passerelle</th><th>Profil</th></tr>
    ${g.membres.map(m => `<tr><td>${esc(m.reference)}</td><td class="${d.doublons[m.ip]?"conflit":""}">${esc(m.ip)}</td><td>${esc(m.carte)}${m.filaire===false?" (sans fil)":""}</td><td>${m.dhcp?"DHCP":"Fixe"}</td><td>${esc(m.passerelle||"")}</td><td>${esc(m.profil||"")}</td></tr>`).join("")}
    </table></div>`).join("") : `<div class="vide">Aucun poste en ligne.</div>`;
  // Un champ en cours de saisie n'est pas réécrit par le rafraîchissement.
  const ae = document.activeElement;
  if(ae && ae.tagName === "INPUT") return;
  const ouvert = $("co-details") ? $("co-details").open : false;
  // Companion
  const co = c.companion;
  let etatCo = !c.companion_url ? "Pas de Companion réglé : la console ne pousse rien." : co.ok===true ? "Variables poussées dans Companion." : co.ok===false ? "Erreur : "+co.erreur : "En attente du premier envoi.";
  $("companion").innerHTML = `<div>${esc(etatCo)}</div>
    ${c.local?`<div class="ligne"><input type="text" id="co-url" placeholder="http://127.0.0.1:8000" value="${esc(c.companion_url)}"><button id="co-ok">Enregistrer</button></div>`:""}
    <details id="co-details"${ouvert?" open":""}><summary>Variables à créer dans Companion (Variables personnalisées)</summary>
    <p class="doux">Sur un bouton : texte <span class="mono">$(custom:pn_pn09_texte)</span>, retour interne « Variable : vérifier la valeur » sur <span class="mono">pn_pn09_etat</span> égal à ALERTE ou HORS LIGNE pour la couleur. vMix : <span class="mono">$(custom:pn_pn09_vmix)</span> (LIVE, REC, LIVE REC, PRÊT, MUET, FERMÉ), et <span class="mono">pn_live</span> pour le nombre de postes en stream.</p>
    <table><tr><th>Variable</th><th>Valeur</th></tr><tbody id="co-vars"></tbody></table></details>
    ${c.local?`<p class="doux">Companion sur un autre appareil : lecture sans pousser par <span class="mono">GET https://${esc(c.adresses[0]||"adresse")}:${c.port_https}/api/companion/pn_resume?jeton=${esc(c.jeton_companion)}</span></p>`:""}`;
  if(c.local){ $("co-ok").onclick = () => regler({companion_url: $("co-url").value}); }
  fetch("/api/companion").then(r=>r.json()).then(v => { const t=$("co-vars"); if(t) t.innerHTML = Object.keys(v).sort().map(k => `<tr><td class="mono">${esc(k)}</td><td>${esc(v[k])}</td></tr>`).join(""); }).catch(()=>{});
  // Appairage
  if(c.local){
    $("sec-appairage").hidden = false;
    $("appairage").innerHTML = `
    <div class="bloc"><b>Code d'appairage</b> <span class="doux">à poser une fois sur le relais du NAS, il contient le secret de la console : à ne pas diffuser.</span>
      <div class="ligne"><code id="code-app">${esc(c.appairage)}</code></div><div class="ligne"><button id="copier">Copier</button></div>
      <p class="doux">Sur le NAS, dans <span class="mono">config/consoles.json</span> :</p>
      <pre class="mono" id="json-app">${esc(JSON.stringify({consoles:[{code:c.appairage, adresse:c.adresses[0]||""}]}, null, 2))}</pre>
      <p class="doux">L'adresse sert de secours quand la découverte sur le réseau ne passe pas (autre réseau, diffusion bloquée). Le relais repose ensuite la sonde sur les postes supervisés, seul.</p></div>
    <div class="bloc"><b>Voir la page depuis un autre appareil</b><div class="ligne">https://${esc(c.adresses[0]||"adresse")}:${c.port_https}/ puis le code <b class="mono">${esc(c.code_page)}</b></div>
      <div class="doux">Le navigateur prévient d'un certificat inconnu : c'est celui de la console, empreinte <span class="mono">${esc(c.empreinte)}</span>.</div></div>
    <div class="bloc"><b>Nom de la console</b><div class="ligne"><input type="text" id="nom-in" value="${esc(c.nom)}"><button id="nom-ok">Renommer</button></div></div>
    ${c.derniers_refus.length?`<div class="bloc"><b>Envois refusés</b> <span class="doux">(jeton d'une autre console ou sonde pas encore reposée)</span>${c.derniers_refus.map(r=>`<div>${esc(r.reference)} depuis ${esc(r.adresse)}</div>`).join("")}</div>`:""}`;
    $("copier").onclick = () => navigator.clipboard.writeText(c.appairage);
    $("nom-ok").onclick = () => regler({nom: $("nom-in").value});
  }
}

async function regler(corps){
  const r = await fetch("/api/reglages",{method:"POST",headers:{"Content-Type":"application/json","X-PN-Local":"1"},body:JSON.stringify(corps)});
  const d = await r.json();
  if(!r.ok) alert(d.erreur || "Refusé");
  charger();
}

function courbe(svg, pts, max){
  if(!pts.length){ svg.innerHTML = ""; return; }
  const t0 = pts[0][0], t1 = Math.max(pts[pts.length-1][0], t0+1);
  const m = Math.max(max || 0, ...pts.map(p => p[1] || 0), 1);
  const d = pts.map((p,i) => (i?"L":"M")+((p[0]-t0)/(t1-t0)*600).toFixed(1)+","+(118-(p[1]||0)/m*112).toFixed(1)).join("");
  svg.innerHTML = `<path d="${d}" fill="none" stroke="#3b82f6" stroke-width="2" vector-effect="non-scaling-stroke"/><text x="4" y="12" fill="#9aa4b1" font-size="11">${Math.round(m)}</text>`;
}

async function detail(){
  if(!choisi){ $("detail").hidden = true; return; }
  const p = (dernier.postes||[]).find(x => x.reference===choisi);
  $("detail").hidden = false;
  $("detail-titre").textContent = choisi + (p && p.poste ? " ("+p.poste+")" : "");
  $("detail-cartes").innerHTML = p ? `<table><tr><th>Carte</th><th>Adresse</th><th>Reçu</th><th>Envoyé</th><th>Vitesse</th><th>Erreurs</th></tr>${p.cartes.map(n=>`<tr><td>${esc(n.name)}${n.down?' <span class="conflit">débranchée</span>':""}</td><td>${esc(n.ipv4||"")}${n.prefix?"/"+n.prefix:""}</td><td>${debit(n.rx)}</td><td>${debit(n.tx)}</td><td>${n.speed?debit(n.speed):""}</td><td>${n.errors||0}</td></tr>`).join("")}</table>` : "";
  try{
    const r = await fetch("/api/historique?reference="+encodeURIComponent(choisi));
    const h = (await r.json()).points || [];
    const depuis = h.length ? h[h.length-1][0] - 7200 : 0;
    const recent = h.filter(x => x[0] >= depuis);
    courbe($("g-cpu"), recent.map(x => [x[0], x[1]]), 100);
    courbe($("g-gw"), recent.filter(x => x[3]!=null).map(x => [x[0], x[3]]), 5);
  }catch(e){}
}

charger();
setInterval(() => { charger().then(() => { if(choisi) detail(); }); }, 5000);
</script>
</body>
</html>
"""
