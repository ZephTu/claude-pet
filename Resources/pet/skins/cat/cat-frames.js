/* Claude Pet cat, frame-by-frame. Plays the clips scripts/cat-frames.swift cut
 * out of the Seedance videos, and walks between poses through the transition
 * clips instead of cutting.
 *
 * Same surface as CatPet (ready / setState / setPaused / setReducedMotion /
 * setStrength / dispose), so pet.js swaps one for the other and nothing else
 * changes. A pose with no clip yet shows its still picture: the videos arrive
 * a few at a time, and a half-made set must never show an empty canvas.
 */
(function (global) {
"use strict";

const VERT = `
attribute vec2 position;
uniform vec4 cell;          // x, y, w, h of this frame inside the atlas, 0..1
varying vec2 uv;
void main() {
  uv = cell.xy + position * cell.zw;
  gl_Position = vec4(position.x * 2.0 - 1.0, 1.0 - position.y * 2.0, 0.0, 1.0);
}`;

// Output is premultiplied, so a crossfade is two draws added together at
// weights that sum to one — the plain lerp, with no dark seam halfway.
const FRAG = `
precision mediump float;
varying vec2 uv;
uniform sampler2D color;
uniform sampler2D alpha;
uniform float split;        // 1: alpha lives in its own texture
uniform float weight;
void main() {
  vec4 c = texture2D(color, uv);
  float a = split > 0.5 ? texture2D(alpha, uv).r : c.a;
  gl_FragColor = vec4(c.rgb, a) * weight;
}`;

/** How long a cut between two clips is blended over, in seconds. */
const BLEND = 0.15;
/**
 * A pose change with no transition clip to play. Longer than a cut: this is
 * the whole cat changing, not a frame or two of drift, and 0.15s of it reads
 * as a flash rather than a move.
 */
const BLEND_POSE = 0.35;
/** GPU bytes clips may hold. A 5s loop is ~18MB, a transition ~6MB. */
const BUDGET = 96 * 1024 * 1024;
/** A fidget is considered only after this long in one pose, then at a loop's end. */
const FIDGET_AFTER = 8;
const FIDGET_CHANCE = 0.35;

class CatFrames {
  /**
   * @param {HTMLCanvasElement} canvas
   * @param {{size:number,fps:number,clips:Object}} manifest  window.CAT_FRAMES
   * @param {string} base  where the atlases live, e.g. "skins/cat/frames/"
   * @param {Object<string,string>} stills  pose → still picture, the same map CatPet takes
   */
  constructor(canvas, manifest, base, stills, options = {}) {
    this.canvas = canvas;
    this.fps = manifest.fps || 12;
    this.clips = manifest.clips || {};
    this.base = base;
    this.stills = stills;
    this.reduced = options.reducedMotion ??
      matchMedia("(prefers-reduced-motion: reduce)").matches;
    this.paused = false;
    this.disposed = false;
    this.cache = new Map();      // clip or "still:<pose>" → {color, alpha, used} | Promise
    this.target = "idle";        // the pose asked for
    this.queue = [];             // clip names still to play before settling
    this.layer = null;           // {name, frame, tex} on screen now
    this.fading = null;          // {tex, frame, cell} being blended out
    this.fadeLeft = 0;
    this.fadeTotal = BLEND;
    this.blendFor = BLEND;
    this.inPose = 0;             // seconds the current loop has been settled
    this.clock = 0;
    this.last = 0;

    const gl = canvas.getContext("webgl", { alpha: true, premultipliedAlpha: true, antialias: false });
    if (!gl) throw new Error("WebGL unavailable");
    this.gl = gl;
    const shader = (type, src) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, src); gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
      return s;
    };
    this.program = gl.createProgram();
    const vs = shader(gl.VERTEX_SHADER, VERT), fs = shader(gl.FRAGMENT_SHADER, FRAG);
    gl.attachShader(this.program, vs); gl.attachShader(this.program, fs);
    gl.linkProgram(this.program);
    gl.deleteShader(vs); gl.deleteShader(fs);
    if (!gl.getProgramParameter(this.program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(this.program));
    gl.useProgram(this.program);
    this.buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 1]), gl.STATIC_DRAW);
    const position = gl.getAttribLocation(this.program, "position");
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
    this.u = {};
    for (const k of ["cell", "color", "alpha", "split", "weight"]) this.u[k] = gl.getUniformLocation(this.program, k);
    gl.uniform1i(this.u.color, 0);
    gl.uniform1i(this.u.alpha, 1);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE);
    gl.clearColor(0, 0, 0, 0);

    // Ready once the opening pose can be drawn at all — its still, which is
    // small. The loop streams in behind it and takes over when it lands.
    this.ready = this.load("still:idle").then(() => {
      if (this.disposed) return;
      this.settle();
      this.raf = requestAnimationFrame(this.tick);
    });
    this.tick = (now) => {
      if (this.disposed) return;
      const delta = this.last ? Math.min((now - this.last) / 1000, 0.1) : 0;
      this.last = now;
      if (!document.hidden && !this.paused && !this.reduced) this.advance(delta);
      this.raf = requestAnimationFrame(this.tick);
    };
  }

  // ---- what to play -------------------------------------------------------

  setState(pose) {
    if (!this.stills[pose]) pose = "idle";
    // `finished` is a flash the host fires again for every turn that ends;
    // each one is a fresh cheer, not "already there".
    if (pose === this.target && pose !== "finished") return this;
    const from = this.layer ? this.poseAt(this.layer.name) : this.target;
    this.target = pose;
    // No walk while only a still is up — that is startup, and the cat should
    // simply be where the state says, not get up and walk there.
    const animated = this.layer && this.clips[this.layer.name];
    this.queue = this.reduced || !animated ? [] : this.route(from, pose);
    this.inPose = 0;
    // Consumed by the next show(), which may be later than this call: when the
    // loop is still loading, the change happens on its arrival.
    this.blendFor = this.queue.length ? BLEND : BLEND_POSE;
    this.next(true);
    return this;
  }

  /** The pose a clip ends on: where the next clip has to start from. */
  poseAt(name) {
    const clip = this.clips[name];
    return clip ? clip.pose : name.replace(/^still:/, "");
  }

  /**
   * The transition clips from one pose to another: a direct one if it was
   * made, else through idle, which every pose can be reached from. With
   * neither the route is empty and the change is a short blend instead.
   */
  route(from, to) {
    if (from === to) return [];
    const direct = `${from}_to_${to}`;
    if (this.clips[direct]) return [direct];
    const out = `${from}_to_idle`, back = `idle_to_${to}`;
    if (from !== "idle" && to !== "idle" && this.clips[out] && this.clips[back]) return [out, back];
    return [];
  }

  /** The loop for the target pose, or its still while there is none. */
  resting() {
    const loop = this.clips[this.target];
    return loop && loop.kind === "loop" ? this.target : `still:${this.target}`;
  }

  /**
   * Move on to the next clip. A clip that is not loaded yet is skipped rather
   * than waited for — a late transition is worse than none, since the state it
   * leads to is already true.
   */
  next(cut) {
    while (this.queue.length) {
      const name = this.queue.shift();
      if (this.loaded(name)) return this.show(name, cut);
      this.load(name);
    }
    const rest = this.resting(), still = `still:${this.target}`;
    if (this.loaded(rest)) return this.show(rest, cut);
    if (rest !== still) {
      // The loop is on its way — a JPEG decode, tens of milliseconds. Keep the
      // frame that is up rather than flash the still: the still is the
      // original drawing, the clips are the model's, and the two styles
      // differ enough that one frame of it reads as a flicker. A loop that
      // fails to load is dropped from the list, and then the still it is.
      this.load(rest).then(() => this.clips[rest] ? this.handover(rest) : this.next(true));
      if (this.layer) return;
    }
    if (this.loaded(still)) this.show(still, cut);
    else this.load(still).then(() => this.handover(still));
  }

  /** A picture landed late. It takes over only if it is still wanted and nothing is playing in front of it. */
  handover(name) {
    if (this.disposed || this.queue.length) return;
    const rest = this.resting();
    if (name !== rest && name !== `still:${this.target}`) return;
    const now = this.layer && this.clips[this.layer.name];
    if (now && now.kind !== "loop") return;   // a transition or fidget; it hands over when it ends
    if (this.layer && this.layer.name === rest) return;
    this.show(name, true);
  }

  show(name, cut) {
    // Only an interruption needs the blend. Clips that follow one another
    // meet on the same seed picture, so a blend there would only smear it.
    if (cut && !this.reduced && this.layer && this.layer.name !== name) {
      this.fading = { name: this.layer.name, frame: this.layer.frame };
      this.fadeLeft = this.fadeTotal = this.blendFor;
    }
    this.blendFor = BLEND;
    this.layer = { name, frame: 0, time: 0 };
    this.touch(name);
    this.prefetch();
    this.draw();
  }

  settle() {
    this.queue = [];
    this.next(false);
  }

  /**
   * Warm what can be wanted next: every way out of this pose, and one fidget.
   * A transition is skipped when it is not ready in time, so a transition
   * fetched only once it is asked for is a transition that never plays.
   */
  prefetch() {
    const rest = this.resting();
    if (!this.loaded(rest)) this.load(rest);
    let fidget = false;
    for (const name of Object.keys(this.clips)) {
      const clip = this.clips[name];
      if (clip.kind === "transition" && clip.from === this.target) this.load(name);
      if (!fidget && clip.kind === "fidget" && clip.pose === this.target) { this.load(name); fidget = true; }
    }
  }

  // ---- time ---------------------------------------------------------------

  advance(delta) {
    this.clock += delta;
    const blending = !!this.fading;
    if (this.fading) {
      this.fadeLeft -= delta;
      if (this.fadeLeft <= 0) this.fading = null;
    }
    const layer = this.layer;
    if (!layer) return;
    const clip = this.clips[layer.name];
    if (!clip) { if (blending) this.draw(); return; }  // a still

    layer.time += delta;
    const frame = Math.floor(layer.time * this.fps);
    if (frame < clip.frames) {
      if (frame !== layer.frame || blending) { layer.frame = frame; this.draw(); }
      return;
    }
    // The clip ran out.
    if (clip.kind === "loop") {
      this.inPose += layer.time;
      const fidget = this.inPose > FIDGET_AFTER && Math.random() < FIDGET_CHANCE && this.pickFidget();
      // Blended both ways: a fidget is cut from a different stretch of the
      // video than the loop, and the model rarely draws the same face twice.
      if (fidget) return this.show(fidget, true);
      layer.time -= clip.frames / this.fps;
      layer.frame = 0;
      this.draw();
      return;
    }
    if (clip.kind === "fidget") this.inPose = 0;
    // Blended out of everything that is not a loop. A fidget is cut from
    // another stretch of video than the loop; a transition lands on the pinned
    // end frame, which the model snaps to in its last frame or two, and the
    // loop after it comes from a different video again.
    this.next(true);
  }

  pickFidget() {
    const options = Object.keys(this.clips).filter((name) =>
      this.clips[name].kind === "fidget" && this.clips[name].pose === this.target && this.loaded(name));
    return options.length ? options[Math.floor(Math.random() * options.length)] : null;
  }

  // ---- textures -----------------------------------------------------------

  loaded(name) {
    const entry = this.cache.get(name);
    return !!entry && !(entry instanceof Promise);
  }

  /** Resolves when `name` is on the GPU. A clip that fails resolves too: it is simply never played. */
  load(name) {
    const have = this.cache.get(name);
    if (have) return have instanceof Promise ? have : Promise.resolve();
    const clip = this.clips[name];
    const still = name.startsWith("still:") ? this.stills[name.slice(6)] : null;
    const urls = clip ? [this.base + clip.file, this.base + clip.alpha] : [still];
    const promise = Promise.all(urls.map(image)).then(
      ([color, alpha]) => {
        if (this.disposed) return;
        this.cache.set(name, {
          color: this.texture(color, !clip, this.gl.RGBA),
          alpha: alpha ? this.texture(alpha, false, this.gl.LUMINANCE) : null,
          bytes: color.width * color.height * (alpha ? 5 : 4),
          used: this.clock,
        });
        this.evict();
      },
      (error) => {
        if (clip) { this.cache.delete(name); delete this.clips[name]; return; }
        throw error;   // a missing still is a broken install; let the skin fall back
      });
    this.cache.set(name, promise);
    return promise;
  }

  texture(img, premultiply, format) {
    const gl = this.gl, tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, premultiply);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texImage2D(gl.TEXTURE_2D, 0, format, format, gl.UNSIGNED_BYTE, img);
    return tex;
  }

  touch(name) {
    const entry = this.cache.get(name);
    if (entry && !(entry instanceof Promise)) entry.used = this.clock;
  }

  /**
   * Drop the least recently shown clips past the budget. Stills are tiny and
   * stay; so does anything on screen, queued, or a way out of this pose.
   */
  evict() {
    const keep = (name) => name.startsWith("still:") || name === this.layer?.name
      || name === this.fading?.name || name === this.resting() || this.queue.includes(name)
      || this.clips[name]?.from === this.target;
    const ready = [...this.cache.entries()].filter(([, e]) => !(e instanceof Promise));
    let total = ready.reduce((sum, [, e]) => sum + e.bytes, 0);
    for (const [name, entry] of ready.filter(([n]) => !keep(n)).sort((x, y) => x[1].used - y[1].used)) {
      if (total <= BUDGET) break;
      this.gl.deleteTexture(entry.color);
      if (entry.alpha) this.gl.deleteTexture(entry.alpha);
      this.cache.delete(name);
      total -= entry.bytes;
    }
  }

  // ---- drawing ------------------------------------------------------------

  draw() {
    if (this.disposed || !this.layer) return;
    const gl = this.gl;
    gl.viewport(0, 0, this.canvas.width, this.canvas.height);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(this.program);
    const k = this.fading ? Math.max(0, this.fadeLeft) / this.fadeTotal : 0;
    if (this.fading) this.drawLayer(this.fading, k);
    this.drawLayer(this.layer, 1 - k);
  }

  drawLayer(layer, weight) {
    const gl = this.gl, entry = this.cache.get(layer.name);
    if (!entry || entry instanceof Promise || weight <= 0) return;
    const clip = this.clips[layer.name];
    if (clip) {
      const cols = clip.columns, rows = Math.ceil(clip.frames / cols);
      const f = Math.min(layer.frame, clip.frames - 1);
      gl.uniform4f(this.u.cell, (f % cols) / cols, Math.floor(f / cols) / rows, 1 / cols, 1 / rows);
    } else {
      gl.uniform4f(this.u.cell, 0, 0, 1, 1);
    }
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, entry.color);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, entry.alpha || entry.color);
    gl.uniform1f(this.u.split, entry.alpha ? 1 : 0);
    gl.uniform1f(this.u.weight, weight);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  }

  // ---- host controls ------------------------------------------------------

  setPaused(value) { this.paused = !!value; return this; }

  /** Reduced motion holds the first frame of the pose: the seed picture itself. */
  setReducedMotion(value) {
    this.reduced = !!value;
    if (this.reduced) {
      this.queue = [];
      this.fading = null;
      this.next(false);
    }
    return this;
  }

  /** The mesh warp's strength knob. Nothing here is procedural, so it does nothing. */
  setStrength() { return this; }

  dispose() {
    this.disposed = true;
    cancelAnimationFrame(this.raf);
    const gl = this.gl;
    for (const entry of this.cache.values()) {
      if (entry instanceof Promise) continue;
      gl.deleteTexture(entry.color);
      if (entry.alpha) gl.deleteTexture(entry.alpha);
    }
    this.cache.clear();
    gl.deleteBuffer(this.buffer);
    gl.deleteProgram(this.program);
  }
}

function image(url) {
  return new Promise((resolve, reject) => {
    if (!url) return resolve(null);
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error("Cannot load " + url));
    img.src = url;
  });
}

global.CatFrames = CatFrames;
})(window);
