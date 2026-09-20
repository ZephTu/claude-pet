/* Claude Pet cat life v3. Original PNG textures; procedural mesh + floating sleep glyphs.
   No model, CDN, account, or network required. */
(function(global){
'use strict';
const VERT = `
attribute vec2 position;
varying vec2 uv;
uniform float time;
uniform float lifeTime;
uniform vec4 ears;
uniform vec2 earTwitch;
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
  float b=sin(lifeTime*1.85); d.y-=0.008*b*weight(p,vec2(.55,.60),vec2(.48,.68));
  // Small weight shift, anchored below the knees; never translate the feet.
  d.x+=.006*sin(lifeTime*.82)*(1.0-smoothstep(.68,.96,p.y));
  d.y-=.003*sin(lifeTime*.91)*weight(p,vec2(.53,.30),vec2(.40,.32));
 }else if(state<1.5){
  // Short typing phrases with rests, not an endless metronome.
  float phrase=.25+.75*smoothstep(-.5,.0,sin(lifeTime*1.7));
  float a=sin(t*16.0)*phrase; float b=sin(t*16.0+2.5)*phrase;
  d.y+=.020*a*weight(p,vec2(.477,.742),vec2(.09,.068));
  d.y+=.016*b*weight(p,vec2(.638,.705),vec2(.058,.060));
  d.y+=.0045*sin(t*3.14159)*weight(p,vec2(.54,.33),vec2(.38,.40));
 }else if(state<2.5){
  vec2 pivot=vec2(.675,.650); vec2 r=p-pivot;
  // Two prominent waves on entry, then a quiet gap before the reminder.
  float attention=1.0-smoothstep(1.3,1.9,mod(t,5.0));
  float angle=(.48*attention+.045)*sin(t*7.0);
  float w=weight(p,vec2(.758,.534),vec2(.145,.19));
  d+=vec2(-r.y,r.x)*angle*w;
  d.y-=.009*attention*pow(max(0.0,sin(t*7.0)),2.0)*(1.0-smoothstep(.70,.95,p.y));
  d.x+=.006*attention*sin(t*3.5)*weight(p,vec2(.47,.38),vec2(.4,.42));
 }else if(state<3.5){
  // 4.8s breathing cycle: lift the head/chest while keeping the paws grounded.
  float breath=sin(lifeTime*1.31);
  d.y-=.015*breath*weight(p,vec2(.48,.52),vec2(.48,.51));
  d.x+=(p.x-.48)*.023*breath*weight(p,vec2(.48,.61),vec2(.47,.37));
 }else if(state<4.5){
  float burst=pow(max(0.0,sin(t*1.8)),3.0);
  d.x+=.004*sin(t*24.0)*burst*weight(p,vec2(.52,.45),vec2(.65,.70));
  d.y-=.006*sin(t*5.0)*weight(p,vec2(.725,.53),vec2(.10,.11));
 }else if(state<5.5){
  // A brief cheer that settles within the host's 1.6s finished flash.
  float cheer=exp(-t*2.3)*sin(t*11.0);
  float body=1.0-smoothstep(.66,.91,p.y);
  d.y-=.020*cheer*body;
  d.y-=.017*cheer*(weight(p,vec2(.22,.35),vec2(.12,.20))+weight(p,vec2(.78,.35),vec2(.12,.20)));
  // Keep the closed laptop at the feet completely still.
  d*=1.0-smoothstep(.84,.90,p.y);
 }else if(state<6.5){
  // Reading: slow scan and tiny nod; the book follows the holding paws.
  float breath=sin(lifeTime*1.8);
  d.y-=.004*breath*weight(p,vec2(.53,.39),vec2(.42,.38));
  d.x+=.003*sin(t*.95)*weight(p,vec2(.53,.38),vec2(.40,.35));
  d.y-=.003*breath*weight(p,vec2(.55,.76),vec2(.30,.18));
 }else if(state<7.5){
  // Compress toward the bottom of the stack; the base remains planted.
  float press=pow(max(0.0,sin(t*2.9)),2.0);
  float paper=(1.0-smoothstep(.18,.23,abs(p.x-.59)))*smoothstep(.74,.80,p.y);
  d.y+=(.974-p.y)*.12*press*paper;
  d.y+=.018*press*(weight(p,vec2(.477,.749),vec2(.09,.075))+weight(p,vec2(.645,.750),vec2(.09,.075)));
  d.y+=.004*press*weight(p,vec2(.54,.42),vec2(.39,.34));
 }else{
  // Waiting on another agent is quiet: a few taps, then a pause.
  float taps=pow(max(0.0,sin(t*9.0)),2.0)*(1.0-smoothstep(1.3,1.8,mod(t,4.5)));
  d.y-=.014*taps*weight(p,vec2(.488,.887),vec2(.085,.085));
  vec2 r=p-vec2(.56,.66);
  d+=vec2(-r.y,r.x)*.009*sin(t*.8)*weight(p,vec2(.56,.42),vec2(.43,.43));
 }

 // ---- idle life --------------------------------------------------------
 // The tail turns about its root, so the root stays put and the tip moves
 // most; a tail translated as a block would detach from the body.
 vec2 tr = p - tailRoot;
 d += vec2(-tr.y, tr.x) * ((state>2.5&&state<3.5?.065:.24) * sin(lifeTime * (state>2.5&&state<3.5?1.05:1.65)) + .045*sin(lifeTime*3.1)) * weight(p, tailRegion.xy, tailRegion.zw);

 // Each eye closes about its own centre. A single shared band pulls the
 // muzzle and the differently tilted eyes toward the wrong horizontal line.
 if(eyeRegion.z>0.0){
  for(int i=0;i<2;i++){
   vec2 c=i==0?pupils.xy:pupils.zw;
   float bx=1.0-smoothstep(.044,.090,abs(p.x-c.x));
   float by=1.0-smoothstep(.055,.105,abs(p.y-c.y));
   d.y+=(c.y-p.y)*blink*.88*bx*by;
  }
  d += gaze * (weight(p,pupils.xy,vec2(.055))+weight(p,pupils.zw,vec2(.055)));
 }
 // Independent, occasional ear flicks; deformation dies out before the eyes.
 for(int i=0;i<2;i++){
  vec2 c=i==0?ears.xy:ears.zw;
  vec2 r=p-(c+vec2(0.0,.10));
  float angle=i==0?earTwitch.x:earTwitch.y;
  d+=vec2(-r.y,r.x)*angle*weight(p,c,vec2(.12,.16));
 }
 // The sleep glyphs are moved in the fragment shader, not with the body.
 if(state>2.5&&state<3.5&&p.x>.735&&p.y<.40)d=vec2(0.0);

 p+=d*strength;
 // Common 6% safety margin, invariant ground anchor.
 p=vec2(.06)+p*.88;
 gl_Position=vec4(p.x*2.0-1.0,1.0-p.y*2.0,0.0,1.0);
}`;
const FRAG=`precision mediump float;
varying vec2 uv; uniform sampler2D texture0;
uniform float zTime; uniform float zStrength; uniform float zEnabled;
float inside(vec2 q,vec4 box){
 return step(box.x,q.x)*step(box.y,q.y)*(1.0-step(box.z,q.x))*(1.0-step(box.w,q.y));
}
vec4 over(vec4 a,vec4 b){
 float alpha=a.a+b.a*(1.0-a.a);
 return vec4((a.rgb*a.a+b.rgb*b.a*(1.0-a.a))/max(alpha,.00001),alpha);
}
/* LOCAL FIX on top of the vendored kit (see scripts/patches/zzz-phase.patch).

   The three Zs are pinned to their own bounding boxes in the texture, so they
   can never actually travel the trail — the only thing that can carry a
   direction is the ORDER they light up in. Upstream gives small / medium /
   large the phases 0 / .33 / .66, which retires them bottom, TOP, middle: no
   direction at all, and the eye reads the adjacent pairs as the Zs dropping.
   Bottom, middle, top 1.2s apart is what makes it read as going up.

   'side' had to come out of 'phase' first: one value was carrying both the
   timing and which half of the shared diagonal a glyph keeps, so the phases
   could not be swapped on their own.

   Vertical travel is zero on purpose, and raising it is the obvious wrong
   move — it was tried at .100 (10.6px) and made things worse. Pinned glyphs
   on different phases drift apart and back together, so the trio loses its
   spacing, and every glyph's wrap becomes a visible DROP the full height of
   the travel. Upstream's own .037 is 3.9px on a 120px canvas: too small to
   read as drift, big enough to read as a drop. The horizontal wobble stays;
   it is under a pixel and reads as shimmer, not position. */
vec4 glyph(vec4 box,float phase,float side){
 float cycle=fract(zTime/3.6+phase);
 vec2 offset=vec2(.009*sin(cycle*6.283+phase*2.0),0.0)*zStrength;
 vec2 q=uv-offset;
 vec4 c=texture2D(texture0,q);
 float fade=smoothstep(0.0,.25,cycle)*(1.0-smoothstep(.72,1.0,cycle));
 // Overlapping bounding rectangles share a diagonal gap, not any ink.
 float separate=smoothstep(214.5/384.0,216.5/384.0,q.x-q.y);
 if(side>1.5)c.a*=separate;
 else if(side>0.5)c.a*=1.0-separate;
 c.a*=inside(q,box)*mix(1.0,fade,min(zStrength,1.0));
 return c;
}
void main(){
 vec4 c=texture2D(texture0,uv);
 if(zEnabled>.5&&zStrength>0.0){
  // Pixel bounds of three disconnected Z components in sleeping.png (384px).
  vec4 small=vec4(284.0,128.0,306.0,150.0)/384.0;
  vec4 medium=vec4(294.0,99.0,320.0,126.0)/384.0;
  vec4 large=vec4(313.0,64.0,356.0,108.0)/384.0;
  c.a*=1.0-max(inside(uv,small),max(inside(uv,medium),inside(uv,large)));
  c=over(glyph(small,0.0,0.0),c);
  c=over(glyph(medium,2.0/3.0,1.0),c);
  c=over(glyph(large,1.0/3.0,2.0),c);
 }
 gl_FragColor=c;
}`;
const states={idle:0,working:1,waiting:2,sleeping:3,urgent:4,finished:5,reading:6,compacting:7,'awaiting-agent':8};
/* Where the tail and the eyes are in each picture, in texture coordinates.
   tail/root read off a labelled 0.1 grid; eyes/pupils measured by connected
   components (each eye is ~1100 dark pixels, about 0.12 by 0.11).
   sleeping's eyes are drawn shut already, so its eye band is given no width
   and the blink cannot touch it. */
const LIFE={
 finished: {tail:[.21,.65,.12,.16],root:[.36,.77],eyes:[0,0,0,.001],pupils:[0,0,0,0]},
 reading: {tail:[.18,.69,.14,.18],root:[.34,.83],eyes:[.535,.455,.20,.07],pupils:[.429,.455,.656,.470]},
 compacting: {tail:[.20,.70,.14,.18],root:[.35,.83],eyes:[.55,.480,.20,.06],pupils:[.449,.475,.666,.493]},
 'awaiting-agent': {tail:[.18,.71,.14,.18],root:[.32,.84],eyes:[.58,.43,.20,.07],pupils:[.453,.410,.713,.468]},
 idle:     {tail:[.17,.70,.11,.12], root:[.30,.75], eyes:[.532,.330,.190,.075], pupils:[.404,.349,.659,.318]},
 working:  {tail:[.20,.64,.10,.11], root:[.33,.72], eyes:[.559,.420,.194,.078], pupils:[.433,.408,.694,.434]},
 waiting:  {tail:[.17,.70,.11,.12], root:[.30,.76], eyes:[.492,.350,.185,.078], pupils:[.369,.371,.619,.330]},
 sleeping: {tail:[.75,.74,.13,.11], root:[.58,.78], eyes:[.500,.440,.000,.001], pupils:[0,0,0,0]},
 urgent:   {tail:[.15,.62,.10,.12], root:[.28,.70], eyes:[.466,.345,.180,.075], pupils:[.348,.361,.589,.330]},
};
// Pose-specific registration for the four additional 384px textures.
const EARS={finished:[.30,.17,.69,.13],reading:[.29,.19,.73,.20],compacting:[.31,.20,.75,.22],'awaiting-agent':[.32,.22,.79,.28],idle:[.27,.14,.70,.10],working:[.30,.16,.78,.20],
 waiting:[.24,.20,.66,.12],sleeping:[.21,.30,.64,.19],urgent:[.23,.20,.62,.13]};
// Optional fallback keeps older five-texture integrations usable.
const fallbackFor={finished:'idle',reading:'working',compacting:'working','awaiting-agent':'working'};
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
  this.earTwitch=[0,0]; this.earStart=-1; this.earSide=0; this.nextEar=1.2+Math.random()*2;
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
  const points=[],N=72;
  for(let y=0;y<N;y++)for(let x=0;x<N;x++){
   const a=x/N,b=y/N,c=(x+1)/N,d=(y+1)/N;
   points.push(a,b,c,b,a,d,c,b,c,d,a,d);
  }
  this.count=points.length/2; this.buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,this.buffer);
  gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(points),gl.STATIC_DRAW);
  const a=gl.getAttribLocation(this.program,'position');gl.enableVertexAttribArray(a);gl.vertexAttribPointer(a,2,gl.FLOAT,false,0,0);
  this.u={};for(const k of ['time','strength','state','tailRegion','tailRoot','eyeRegion','pupils','blink','gaze','lifeTime','ears','earTwitch','zTime','zStrength','zEnabled'])this.u[k]=gl.getUniformLocation(this.program,k);
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
  this.ready.then(()=>{if(!this.disposed){this.draw();this.raf=requestAnimationFrame(this.tick);}},()=>{});
 }
 /* A blink is 130ms — 55 shut, 75 open — on an irregular interval, because a
    blink on a fixed beat reads as a machine. The pupils drift to a new spot
    every 1.4-3.8s and ease into it; a hard cut looks like a glitch on an eye
    that is 12pt across on screen. */
 advanceLife(delta){
  this.life+=delta;
  if(this.earStart<0&&this.life>=this.nextEar){this.earStart=this.life;this.earSide=Math.random()<.5?0:1;}
  if(this.earStart>=0){
   const k=(this.life-this.earStart)/.65;
   this.earTwitch=[0,0];
   if(k>=1){this.earStart=-1;this.nextEar=this.life+2.8+Math.random()*4.2;}
   else this.earTwitch[this.earSide]=.24*Math.sin(k*Math.PI*3)*Math.sin(k*Math.PI);
  }
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
 setState(state){if(!Object.prototype.hasOwnProperty.call(states,state))state='idle';if(this.state===state&&state!=='finished')return this;this.state=state;this.time=0;this.draw();return this;}
 setPaused(value){this.paused=!!value;return this;}
 setReducedMotion(value){this.reduced=!!value;this.draw();return this;}
 setStrength(value){const n=Number(value);this.strength=Number.isFinite(n)?Math.max(0,Math.min(1.5,n)):1;this.draw();return this;}
 draw(){
  const key=this.textures[this.state]?this.state:(fallbackFor[this.state]||this.state);
  if(this.disposed||!this.textures[key])return;
  const gl=this.gl;gl.viewport(0,0,this.canvas.width,this.canvas.height);gl.clear(gl.COLOR_BUFFER_BIT);
  gl.useProgram(this.program);gl.bindTexture(gl.TEXTURE_2D,this.textures[key]);
  gl.uniform1f(this.u.time,this.time);gl.uniform1f(this.u.strength,this.reduced?0:this.strength);
  gl.uniform1f(this.u.state,states[key]);
  gl.uniform1f(this.u.lifeTime,this.life);
  gl.uniform4fv(this.u.ears,EARS[key]||EARS.idle);
  const earScale=key==='sleeping'?.3:1;
  gl.uniform2fv(this.u.earTwitch,this.reduced?[0,0]:this.earTwitch.map(v=>v*earScale));
  gl.uniform1f(this.u.zEnabled,key==='sleeping'?1:0);
  gl.uniform1f(this.u.zTime,this.life);
  gl.uniform1f(this.u.zStrength,this.reduced?0:this.strength);
  const life=LIFE[key]||LIFE.idle;
  gl.uniform4fv(this.u.tailRegion,life.tail);gl.uniform2fv(this.u.tailRoot,life.root);
  gl.uniform4fv(this.u.eyeRegion,life.eyes);gl.uniform4fv(this.u.pupils,life.pupils);
  // Reduced motion stops the pet moving; a cat frozen mid-blink would be a cat
  // with its eyes shut for as long as the setting is on.
  gl.uniform1f(this.u.blink,this.reduced?0:this.blink);
  gl.uniform2fv(this.u.gaze,this.reduced||key==='finished'?[0,0]:this.gaze);
  gl.drawArrays(gl.TRIANGLES,0,this.count);
 }
 dispose(){this.disposed=true;cancelAnimationFrame(this.raf);const gl=this.gl;Object.values(this.textures).forEach(t=>gl.deleteTexture(t));gl.deleteBuffer(this.buffer);gl.deleteProgram(this.program);}
}
global.CatPet=CatPet;
})(window);
