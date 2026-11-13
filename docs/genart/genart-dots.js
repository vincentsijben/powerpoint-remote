/*
 * GenArt stippenspiraal — v0.2
 *
 * Tekent op een <canvas> een spiraal van stippen waarvan de vorm uit een naam
 * wordt berekend. Dezelfde naam geeft altijd hetzelfde patroon, dus elke app
 * krijgt een eigen, vast patroon binnen dezelfde familie.
 *
 * Gewoon script, geen module en geen afhankelijkheden:
 *
 *   <canvas id="hero"></canvas>
 *   <script src="genart/genart-dots.js"></script>
 *   <script>
 *     GenArtDots.draw(canvas, "PPT Remote");                 // stilstaand, bv. een icoon
 *     const stop = GenArtDots.animate(canvas, "PPT Remote"); // bewegend, bv. een startscherm
 *   </script>
 *
 * Opties (allemaal optioneel):
 *   count    aantal stippen                      (standaard: past bij het canvas)
 *   spacing  afstand tussen stippen in pixels    (standaard: past bij het canvas)
 *   cx, cy   middelpunt, 0–1                     (standaard 0.5, 0.5)
 *   fade     onderkant laten vervagen            (standaard false)
 *   inner    kleur in het hart, [r, g, b]        (standaard oranjerood)
 *   outer    kleur aan de rand, [r, g, b]        (standaard paper)
 *   time     tijdstip in seconden, voor draw()   (standaard 0)
 */
(function (root) {
  "use strict";

  // Hoeken rond de gulden hoek; elke hoek geeft een ander aantal spiraalarmen.
  var ANGLES = [137.508, 137.3, 137.65, 138.1, 139.0, 136.4, 99.5, 151.1];

  function hash(text) {
    var h = 2166136261;
    for (var i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619);
    return h >>> 0;
  }

  function draw(canvas, seed, options) {
    var o = options || {};
    var ratio = Math.min(root.devicePixelRatio || 1, 2);
    var w = canvas.clientWidth || canvas.width;
    var h = canvas.clientHeight || canvas.height;
    if (canvas.width !== w * ratio || canvas.height !== h * ratio) {
      canvas.width = w * ratio;
      canvas.height = h * ratio;
    }
    var ctx = canvas.getContext("2d");
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.clearRect(0, 0, w, h);

    var size = Math.min(w, h);
    var spacing = o.spacing || Math.max(3, size / 15);
    var count = o.count || Math.round(Math.pow((Math.max(w, h) * 0.62) / spacing, 2));
    var cx = (o.cx === undefined ? 0.5 : o.cx) * w;
    var cy = (o.cy === undefined ? 0.5 : o.cy) * h;
    var inner = o.inner || [255, 91, 53];
    var outer = o.outer || [245, 242, 235];
    var time = o.time || 0;

    var hsh = hash(String(seed));
    var angle = (ANGLES[hsh % ANGLES.length] * Math.PI) / 180;
    var wave = 2 + ((hsh >>> 8) % 4);
    var maxR = spacing * Math.sqrt(count);

    for (var i = 1; i <= count; i++) {
      var r = spacing * Math.sqrt(i);
      var a = i * angle + time * 0.05;
      var x = cx + r * Math.cos(a);
      var y = cy + r * Math.sin(a);
      var t = r / maxR;
      var pulse = 0.74 + 0.26 * Math.sin(a * wave + t * 6 - time * 0.6);
      var dot = spacing * 0.5 * (0.4 + 0.6 * t) * pulse;
      var mix = Math.min(1, t * 1.25);
      var alpha = 1 - 0.35 * t;
      if (o.fade) alpha *= Math.max(0, Math.min(1, (h - y) / (h * 0.22)));
      ctx.fillStyle =
        "rgba(" +
        Math.round(inner[0] + (outer[0] - inner[0]) * mix) + "," +
        Math.round(inner[1] + (outer[1] - inner[1]) * mix) + "," +
        Math.round(inner[2] + (outer[2] - inner[2]) * mix) + "," +
        alpha + ")";
      ctx.beginPath();
      ctx.arc(x, y, Math.max(0.4, dot), 0, Math.PI * 2);
      ctx.fill();
    }
  }

  // Laat de spiraal langzaam draaien. Geeft een functie terug die de animatie
  // stopt. Staat stil als de gebruiker om minder beweging heeft gevraagd, en
  // pauzeert als de pagina niet zichtbaar is.
  function animate(canvas, seed, options) {
    var o = Object.assign({}, options);
    var still = root.matchMedia && root.matchMedia("(prefers-reduced-motion: reduce)").matches;
    var handle = 0;
    var stopped = false;

    function frame(ms) {
      if (stopped) return;
      if (!document.hidden) {
        o.time = ms / 1000;
        draw(canvas, seed, o);
      }
      if (!still) handle = root.requestAnimationFrame(frame);
    }

    handle = root.requestAnimationFrame(frame);
    return function stop() {
      stopped = true;
      root.cancelAnimationFrame(handle);
    };
  }

  root.GenArtDots = { draw: draw, animate: animate };
})(typeof window !== "undefined" ? window : this);
