/* Claude Pet cat prototype. Original PNG textures; small procedural mesh motion.
   No model, CDN, account, or network required. */
(function(global){
'use strict';
const VERT = `
attribute vec2 position;
varying vec2 uv;
uniform float time;
uniform float strength;
uniform float state;
// Per-pose geometry for the idle motions below. Measured off each texture, not
// guessed: the eye boxes come from connected components over the dark pixels,
// which put working's eyes 0.14 lower than reading them off a grid did — the
// first version blinked the cat's nose.
uniform vec4 tailRegion;   // cx, cy, rx, ry
uniform vec2 tailRoot;     // the pivot, where the tail meets the body
uniform vec4 eyeRegion;    // cx, cy, half-width, half-height
uniform vec4 pupils;       // left x,y then right x,y
uniform float blink;       // 0 open, 1 shut
uniform vec2 gaze;         // pupil offset
float weight(vec2 p, vec2 c, vec2 r){vec2 d=(p-c)/r; return exp(-dot(d,d)*2.5);}
void main(){
 uv=position; vec2 p=position; float t=time; vec2 d=vec2(0.0);
 // Local deformations taper smoothly to zero, so there are no cutout seams.
 if(state<0.5){
  float b=sin(t*1.85); d.y-=0.005*b*weight(p,vec2(.55,.60),vec2(.48,.68));
  d.x+=.010*sin(t*1.35)*weight(p,vec2(.23,.70),vec2(.18,.24));
 }else if(state<1.5){
  float a=sin(t*12.566); float b=sin(t*12.566+3.14159);
  d.y+=.009*a*weight(p,vec2(.477,.742),vec2(.09,.068));
  d.y+=.007*b*weight(p,vec2(.638,.705),vec2(.058,.060));
  d.y+=.0025*sin(t*3.14159)*weight(p,vec2(.54,.33),vec2(.38,.40));
 }else if(state<2.5){
  vec2 pivot=vec2(.675,.650); vec2 r=p-pivot;
  float angle=.12*sin(t*5.2); float w=weight(p,vec2(.758,.534),vec2(.145,.19));
  d+=vec2(-r.y,r.x)*angle*w;
  d.y-=.0025*sin(t*2.0)*weight(p,vec2(.47,.44),vec2(.4,.55));
 }else if(state<3.5){
  d.y-=.008*sin(t*1.45)*weight(p,vec2(.49,.53),vec2(.47,.54));
  d.x+=.005*sin(t*1.1)*weight(p,vec2(.79,.77),vec2(.19,.20));
 }else if(state<4.5){
  float burst=pow(max(0.0,sin(t*1.8)),3.0);
  d.x+=.004*sin(t*24.0)*burst*weight(p,vec2(.52,.45),vec2(.65,.70));
  d.y-=.006*sin(t*5.0)*weight(p,vec2(.725,.53),vec2(.10,.11));
 }else{
  // finished: one short bob on the idle picture, anchored at the feet and
  // decaying to nothing. There is no artwork for a finished turn, and a still
  // picture could not say "just now" even if there were — what carries this
  // state is that it MOVES and then stops. setState resets time, so t is
  // seconds since the turn ended.
  float k=exp(-t*1.9)*sin(t*12.0);
  // 1.0 - smoothstep(lo,hi,..), not smoothstep(hi,lo,..): GLSL ES leaves
  // smoothstep undefined when edge0 >= edge1, and the reversed form
  // silently produced a bob of exactly zero — two renders 0.15s apart
  // came out pixel-identical.
  float lift=1.0-smoothstep(0.25,1.0,p.y);
  d.y-=.035*k*lift;
  d.x+=.005*k*weight(p,vec2(.5,.3),vec2(.45,.35));
 }

 // ---- idle life --------------------------------------------------------
 // The tail turns about its root, so the root stays put and the tip moves
 // most; a tail translated as a block would detach from the body.
 vec2 tr = p - tailRoot;
 d += vec2(-tr.y, tr.x) * (.16 * sin(t * 2.2)) * weight(p, tailRegion.xy, tailRegion.zw);

 // The blink cannot use the round gaussian everything else here uses: the
 // points that must move MOST are the top and bottom edges of the eye, which
 // is exactly where a round falloff is weakest. Separable instead — a gaussian
 // across x, a plateau across y that only tapers outside the eye.
 float bx = exp(-pow((p.x - eyeRegion.x) / max(eyeRegion.z, 1e-4), 2.0) * 2.0);
 float by = 1.0 - smoothstep(0.7, 1.6, abs(p.y - eyeRegion.y) / max(eyeRegion.w, 1e-4));
 d.y += (eyeRegion.y - p.y) * blink * bx * by;

 d += gaze * (weight(p, pupils.xy, vec2(.055)) + weight(p, pupils.zw, vec2(.055)));

 p+=d*strength;
 // Common 6% safety margin, invariant ground anchor.
 p=vec2(.06)+p*.88;
 gl_Position=vec4(p.x*2.0-1.0,1.0-p.y*2.0,0.0,1.0);
}`;
const FRAG=`precision mediump float; varying vec2 uv; uniform sampler2D texture0;
void main(){ gl_FragColor=texture2D(texture0,uv); }`;
const states={idle:0,working:1,waiting:2,sleeping:3,urgent:4,finished:5};
/* Where the tail and the eyes are in each picture, in texture coordinates.
   tail/root read off a labelled 0.1 grid; eyes/pupils measured by connected
   components (each eye is ~1100 dark pixels, about 0.12 by 0.11).
   sleeping's eyes are drawn shut already, so its eye band is given no width
   and the blink cannot touch it. */
const LIFE={
 idle:     {tail:[.17,.70,.11,.12], root:[.30,.75], eyes:[.532,.330,.190,.075], pupils:[.404,.349,.659,.318]},
 working:  {tail:[.20,.64,.10,.11], root:[.33,.72], eyes:[.559,.420,.194,.078], pupils:[.433,.408,.694,.434]},
 waiting:  {tail:[.17,.70,.11,.12], root:[.30,.76], eyes:[.492,.350,.185,.078], pupils:[.369,.371,.619,.330]},
 sleeping: {tail:[.75,.74,.13,.11], root:[.58,.78], eyes:[.500,.440,.000,.001], pupils:[0,0,0,0]},
 urgent:   {tail:[.15,.62,.10,.12], root:[.28,.70], eyes:[.466,.345,.180,.075], pupils:[.348,.361,.589,.330]},
};
// `finished` is a deformation of an existing picture, not a picture of its own.
const textureFor={finished:'idle'};
class CatPet{
 constructor(canvas, assets, options={}){
  this.canvas=canvas; this.assets=assets; this.state='idle'; this.strength=1;
  this.paused=false; this.reduced=options.reducedMotion??matchMedia('(prefers-reduced-motion: reduce)').matches;
  this.time=0; this.textures={}; this.disposed=false; this.last=0; this.nextFrame=0;
  // Blinking runs on its OWN clock. `time` restarts with every pose (the
  // finished bob needs "seconds since the turn ended"), and a blink scheduled
  // on that clock is lost at every state change: the next blink sits seconds
  // ahead on a clock that just went back to zero, and a blink caught mid-way
  // keeps a start time the clock can never reach. The pet changes state every
  // few seconds, so on a shared clock it would simply never blink.
  this.life=0; this.blink=0; this.blinkStart=-1; this.nextBlink=2+Math.random()*2;
  this.gaze=[0,0]; this.gazeTarget=[0,0]; this.nextGaze=1.5;
  this.gl=canvas.getContext('webgl',{alpha:true,antialias:true,premultipliedAlpha:false,preserveDrawingBuffer:true});
  if(!this.gl)throw new Error('WebGL unavailable');
  const gl=this.gl;
  const shader=(type,src)=>{const s=gl.createShader(type);gl.shaderSource(s,src);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(s));return s;};
  this.program=gl.createProgram(); const vs=shader(gl.VERTEX_SHADER,VERT),fs=shader(gl.FRAGMENT_SHADER,FRAG);
  gl.attachShader(this.program,vs);gl.attachShader(this.program,fs);gl.linkProgram(this.program);
  gl.deleteShader(vs);gl.deleteShader(fs);
  if(!gl.getProgramParameter(this.program,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(this.program));
  gl.useProgram(this.program);
  const points=[],N=56;
  for(let y=0;y<N;y++)for(let x=0;x<N;x++){
   const a=x/N,b=y/N,c=(x+1)/N,d=(y+1)/N;
   points.push(a,b,c,b,a,d,c,b,c,d,a,d);
  }
  this.count=points.length/2; this.buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,this.buffer);
  gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(points),gl.STATIC_DRAW);
  const a=gl.getAttribLocation(this.program,'position');gl.enableVertexAttribArray(a);gl.vertexAttribPointer(a,2,gl.FLOAT,false,0,0);
  this.u={};for(const k of ['time','strength','state','tailRegion','tailRoot','eyeRegion','pupils','blink','gaze'])this.u[k]=gl.getUniformLocation(this.program,k);
  gl.uniform1i(gl.getUniformLocation(this.program,'texture0'),0);
  gl.clearColor(0,0,0,0);
  this.ready=Promise.all(Object.entries(assets).map(([key,url])=>new Promise((resolve,reject)=>{
   const img=new Image();img.onload=()=>{
    if(this.disposed){resolve();return;}
    const tex=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,tex);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
    gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,img);this.textures[key]=tex;resolve();
   };img.onerror=()=>reject(new Error('Cannot load '+key));img.src=url;
  })));
  this.tick=(now)=>{
   if(this.disposed)return;
   const delta=this.last?Math.min((now-this.last)/1000,.1):0;this.last=now;
   if(!document.hidden&&!this.paused&&!this.reduced&&now>=this.nextFrame){this.time+=delta;this.advanceLife(delta);this.draw();this.nextFrame=now+1000/30;}
   else if(!document.hidden&&!this.paused&&!this.reduced){this.time+=delta;this.advanceLife(delta);}
   this.raf=requestAnimationFrame(this.tick);
  };
  this.ready.then(()=>{if(!this.disposed){this.draw();this.raf=requestAnimationFrame(this.tick);}});
 }
 /* A blink is 130ms — 55 shut, 75 open — on an irregular interval, because a
    blink on a fixed beat reads as a machine. The pupils drift to a new spot
    every 1.4-3.8s and ease into it; a hard cut looks like a glitch on an eye
    that is 12pt across on screen. */
 advanceLife(delta){
  this.life+=delta;
  if(this.blinkStart<0&&this.life>=this.nextBlink)this.blinkStart=this.life;
  if(this.blinkStart>=0){
   const k=(this.life-this.blinkStart)/0.13;
   this.blink=k>=1?0:Math.sin(Math.PI*k)*0.92;
   if(k>=1){this.blinkStart=-1;this.nextBlink=this.life+3.8*(0.6+Math.random()*0.9);}
  }
  if(this.life>=this.nextGaze){
   this.gazeTarget=[(Math.random()-0.5)*0.014,(Math.random()-0.5)*0.007];
   this.nextGaze=this.life+1.4+Math.random()*2.4;
  }
  const ease=Math.min(1,delta*9);
  this.gaze[0]+=(this.gazeTarget[0]-this.gaze[0])*ease;
  this.gaze[1]+=(this.gazeTarget[1]-this.gaze[1])*ease;
 }
 setState(state){if(!(state in states))state='idle';this.state=state;this.time=0;this.draw();return this;}
 setPaused(value){this.paused=!!value;return this;}
 setReducedMotion(value){this.reduced=!!value;this.draw();return this;}
 setStrength(value){const n=Number(value);this.strength=Number.isFinite(n)?Math.max(0,Math.min(1.5,n)):1;this.draw();return this;}
 draw(){
  const key=textureFor[this.state]||this.state;
  if(this.disposed||!this.textures[key])return;
  const gl=this.gl;gl.viewport(0,0,this.canvas.width,this.canvas.height);gl.clear(gl.COLOR_BUFFER_BIT);
  gl.useProgram(this.program);gl.bindTexture(gl.TEXTURE_2D,this.textures[key]);
  gl.uniform1f(this.u.time,this.time);gl.uniform1f(this.u.strength,this.reduced?0:this.strength);
  gl.uniform1f(this.u.state,states[this.state]);
  const life=LIFE[key]||LIFE.idle;
  gl.uniform4fv(this.u.tailRegion,life.tail);gl.uniform2fv(this.u.tailRoot,life.root);
  gl.uniform4fv(this.u.eyeRegion,life.eyes);gl.uniform4fv(this.u.pupils,life.pupils);
  // Reduced motion stops the pet moving; a cat frozen mid-blink would be a cat
  // with its eyes shut for as long as the setting is on.
  gl.uniform1f(this.u.blink,this.reduced?0:this.blink);
  gl.uniform2fv(this.u.gaze,this.reduced?[0,0]:this.gaze);
  gl.drawArrays(gl.TRIANGLES,0,this.count);
 }
 dispose(){this.disposed=true;cancelAnimationFrame(this.raf);const gl=this.gl;Object.values(this.textures).forEach(t=>gl.deleteTexture(t));gl.deleteBuffer(this.buffer);gl.deleteProgram(this.program);}
}
global.CatPet=CatPet;
})(window);
