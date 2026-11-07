/*
The site's background: a wireframe tube looping around a bent ring ("orbit"), drawn with
WebGL as lines and points that add up to a soft violet glow. The shape is computed in the
vertex shader from each point's place on the tube, so a frame costs the CPU nothing.

It turns slowly and breathes, leans a little towards the pointer and turns a little with
scrolling. It fills the window; pages style canvas.mesh-bg (fixed, behind the content). With reduced motion it draws one still frame. Without WebGL there is no canvas,
and the page keeps its plain background.
*/
(function () {
  'use strict';

  var canvas = document.createElement('canvas');
  var gl = canvas.getContext('webgl', { alpha: true, premultipliedAlpha: true, antialias: true, powerPreference: 'low-power' });
  if (!gl) return;
  canvas.className = 'mesh-bg';
  canvas.setAttribute('aria-hidden', 'true');

  var still = window.matchMedia('(prefers-reduced-motion: reduce)');
  var small = window.matchMedia('(max-width: 640px)');

  var VERTEX = [
    'attribute vec2 a_uv;',
    'uniform float u_time;',
    'uniform vec2 u_lean;',
    'uniform float u_turn;',
    'uniform vec2 u_scale;',
    'uniform vec2 u_offset;',
    'uniform float u_point;',
    'varying float v_depth;',
    'varying float v_side;',
    'const float TAU = 6.2831853;',
    // A ring of radius 1 bent up and down twice (a saddle), its height drifting slowly.
    'vec3 centre(float t) {',
    '  return vec3(cos(t), sin(t), 0.55 * sin(2.0 * t + 0.35 * sin(u_time * 0.11)));',
    '}',
    'vec3 rotX(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(p.x, c * p.y - s * p.z, s * p.y + c * p.z); }',
    'vec3 rotY(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z); }',
    'vec3 rotZ(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(c * p.x - s * p.y, s * p.x + c * p.y, p.z); }',
    'void main() {',
    '  float t = a_uv.x * TAU;',
    '  vec3 c = centre(t);',
    '  vec3 tangent = normalize(centre(t + 0.001) - centre(t - 0.001));',
    '  vec3 n = normalize(cross(tangent, vec3(0.0, 0.0, 1.0)));',
    '  vec3 b = cross(n, tangent);',
    // The tube twists along the ring and breathes in two slow waves.
    '  float a = a_uv.y * TAU + 1.5 * t + u_time * 0.07;',
    '  float r = 0.42 * (1.0 + 0.1 * sin(3.0 * t - u_time * 0.35) + 0.05 * sin(5.0 * t + u_time * 0.2));',
    '  vec3 p = c + r * (cos(a) * n + sin(a) * b);',
    '  p = rotZ(p, 0.35);',
    '  p = rotY(p, u_time * 0.045 + u_turn + u_lean.x * 0.25);',
    '  p = rotX(p, 1.08 + u_lean.y * 0.18);',
    '  float z = p.z + 3.4;',
    '  vec2 xy = p.xy * (2.6 / z);',
    '  gl_Position = vec4(xy * u_scale + u_offset, 0.0, 1.0);',
    '  v_depth = clamp((z - 2.0) / 2.8, 0.0, 1.0);',
    '  v_side = 0.5 + 0.5 * sin(t + u_time * 0.05);',
    '  gl_PointSize = u_point * (1.25 - 0.6 * v_depth);',
    '}',
  ].join('\n');

  var FRAGMENT = [
    'precision mediump float;',
    'uniform float u_alpha;',
    'uniform float u_round;',
    'varying float v_depth;',
    'varying float v_side;',
    'void main() {',
    '  float d = 1.0;',
    '  if (u_round > 0.5) { vec2 q = gl_PointCoord - 0.5; d = smoothstep(0.5, 0.15, length(q)); }',
    // Violet, cooler towards the far side; brighter near.
    '  vec3 violet = vec3(0.47, 0.33, 1.0);',
    '  vec3 indigo = vec3(0.30, 0.38, 0.98);',
    '  vec3 col = mix(violet, indigo, 0.55 * v_side + 0.3 * v_depth);',
    '  float a = u_alpha * d * (1.0 - 0.72 * v_depth);',
    '  gl_FragColor = vec4(col * a, a);',
    '}',
  ].join('\n');

  function shader(type, source) {
    var s = gl.createShader(type);
    gl.shaderSource(s, source);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) || 'shader');
    return s;
  }

  var program, loc, lineCount, pointCount, built = '';

  function setup() {
    program = gl.createProgram();
    gl.attachShader(program, shader(gl.VERTEX_SHADER, VERTEX));
    gl.attachShader(program, shader(gl.FRAGMENT_SHADER, FRAGMENT));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program) || 'link');
    gl.useProgram(program);
    loc = {};
    ['u_time', 'u_lean', 'u_turn', 'u_scale', 'u_offset', 'u_point', 'u_alpha', 'u_round'].forEach(function (name) {
      loc[name] = gl.getUniformLocation(program, name);
    });
    loc.a_uv = gl.getAttribLocation(program, 'a_uv');
    built = '';
    mesh();
    // Premultiplied colour and alpha both add up: overlapping lines glow, and the canvas
    // still composites correctly over the page.
    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(gl.ONE, gl.ONE, gl.ONE, gl.ONE);
    gl.disable(gl.DEPTH_TEST);
  }

  // The grid of points on the tube, and its edges: along the ring, around the tube, and one
  // diagonal per square, so it reads as a triangle mesh.
  function mesh() {
    var size = small.matches ? '84x28' : '128x40';
    if (size === built) return;
    built = size;
    var U = small.matches ? 84 : 128;
    var V = small.matches ? 28 : 40;
    var uv = new Float32Array(U * V * 2);
    var k = 0;
    for (var i = 0; i < U; i++) {
      for (var j = 0; j < V; j++) {
        uv[k++] = i / U;
        uv[k++] = j / V;
      }
    }
    var idx = new Uint16Array(U * V * 6);
    k = 0;
    for (i = 0; i < U; i++) {
      for (j = 0; j < V; j++) {
        var here = i * V + j;
        var along = ((i + 1) % U) * V + j;
        var around = i * V + ((j + 1) % V);
        var diag = ((i + 1) % U) * V + ((j + 1) % V);
        idx[k++] = here; idx[k++] = along;
        idx[k++] = here; idx[k++] = around;
        idx[k++] = here; idx[k++] = diag;
      }
    }
    lineCount = idx.length;
    pointCount = U * V;
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, uv, gl.STATIC_DRAW);
    gl.enableVertexAttribArray(loc.a_uv);
    gl.vertexAttribPointer(loc.a_uv, 2, gl.FLOAT, false, 0, 0);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, idx, gl.STATIC_DRAW);
  }

  var dpr = 1;
  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    var w = Math.round(window.innerWidth * dpr);
    var h = Math.round(window.innerHeight * dpr);
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    gl.viewport(0, 0, w, h);
    mesh();
  }

  // The pointer and scrolling move the shape a little; it eases towards them.
  var lean = [0, 0], leanTo = [0, 0], turn = 0;
  window.addEventListener('pointermove', function (e) {
    leanTo[0] = (e.clientX / window.innerWidth) * 2 - 1;
    leanTo[1] = (e.clientY / window.innerHeight) * 2 - 1;
  }, { passive: true });

  function draw(time) {
    var w = canvas.width, h = canvas.height;
    var aspect = w / h;
    // The whole background: centred, and big enough that the loop reaches past the sides of a
    // wide window and past the top and bottom of a tall one.
    var k = aspect >= 1 ? 0.6 * Math.min(aspect, 2.4) : 0.66;
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.uniform1f(loc.u_time, time);
    gl.uniform2f(loc.u_lean, lean[0], lean[1]);
    gl.uniform1f(loc.u_turn, turn);
    gl.uniform2f(loc.u_scale, k / aspect, k);
    gl.uniform2f(loc.u_offset, 0, 0);
    gl.uniform1f(loc.u_round, 0);
    gl.uniform1f(loc.u_alpha, 0.15);
    gl.drawElements(gl.LINES, lineCount, gl.UNSIGNED_SHORT, 0);
    gl.uniform1f(loc.u_round, 1);
    gl.uniform1f(loc.u_alpha, 0.42);
    gl.uniform1f(loc.u_point, 2.4 * dpr);
    gl.drawArrays(gl.POINTS, 0, pointCount);
  }

  var start = performance.now(), frame = 0, running = false;
  function tick(now) {
    frame = 0;
    lean[0] += (leanTo[0] - lean[0]) * 0.03;
    lean[1] += (leanTo[1] - lean[1]) * 0.03;
    turn += ((window.scrollY || 0) * 0.0006 - turn) * 0.05;
    draw((now - start) / 1000);
    if (running) frame = requestAnimationFrame(tick);
  }

  function play() {
    if (still.matches) {
      running = false;
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
      draw(14);
      return;
    }
    if (!running) {
      running = true;
      frame = requestAnimationFrame(tick);
    }
  }

  canvas.addEventListener('webglcontextlost', function (e) {
    e.preventDefault();
    running = false;
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
  });
  canvas.addEventListener('webglcontextrestored', function () {
    setup();
    resize();
    play();
  });

  function start_() {
    try {
      setup();
    } catch (e) {
      return;
    }
    document.body.insertBefore(canvas, document.body.firstChild);
    resize();
    play();
    window.addEventListener('resize', function () {
      resize();
      if (!running) play();
    });
    var watch = function (m, fn) {
      if (m.addEventListener) m.addEventListener('change', fn); else if (m.addListener) m.addListener(fn);
    };
    watch(still, play);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start_);
  else start_();
})();
