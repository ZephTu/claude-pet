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
 }else{
  float burst=pow(max(0.0,sin(t*1.8)),3.0);
  d.x+=.004*sin(t*24.0)*burst*weight(p,vec2(.52,.45),vec2(.65,.70));
  d.y-=.006*sin(t*5.0)*weight(p,vec2(.725,.53),vec2(.10,.11));
 }
 p+=d*strength;
 // Common 6% safety margin, invariant ground anchor.
 p=vec2(.06)+p*.88;
 gl_Position=vec4(p.x*2.0-1.0,1.0-p.y*2.0,0.0,1.0);
}`;
const FRAG=`precision mediump float; varying vec2 uv; uniform sampler2D texture0;
void main(){ gl_FragColor=texture2D(texture0,uv); }`;
const states={idle:0,working:1,waiting:2,sleeping:3,urgent:4};
class CatPet{
 constructor(canvas, assets, options={}){
  this.canvas=canvas; this.assets=assets; this.state='idle'; this.strength=1;
  this.paused=false; this.reduced=options.reducedMotion??matchMedia('(prefers-reduced-motion: reduce)').matches;
  this.time=0; this.textures={}; this.disposed=false; this.last=0; this.nextFrame=0;
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
  this.u={};for(const k of ['time','strength','state'])this.u[k]=gl.getUniformLocation(this.program,k);
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
   if(!document.hidden&&!this.paused&&!this.reduced&&now>=this.nextFrame){this.time+=delta;this.draw();this.nextFrame=now+1000/30;}
   else if(!document.hidden&&!this.paused&&!this.reduced)this.time+=delta;
   this.raf=requestAnimationFrame(this.tick);
  };
  this.ready.then(()=>{if(!this.disposed){this.draw();this.raf=requestAnimationFrame(this.tick);}});
 }
 setState(state){if(!(state in states))state='idle';this.state=state;this.time=0;this.draw();return this;}
 setPaused(value){this.paused=!!value;return this;}
 setReducedMotion(value){this.reduced=!!value;this.draw();return this;}
 setStrength(value){const n=Number(value);this.strength=Number.isFinite(n)?Math.max(0,Math.min(1.5,n)):1;this.draw();return this;}
 draw(){
  if(this.disposed||!this.textures[this.state])return;
  const gl=this.gl;gl.viewport(0,0,this.canvas.width,this.canvas.height);gl.clear(gl.COLOR_BUFFER_BIT);
  gl.useProgram(this.program);gl.bindTexture(gl.TEXTURE_2D,this.textures[this.state]);
  gl.uniform1f(this.u.time,this.time);gl.uniform1f(this.u.strength,this.reduced?0:this.strength);
  gl.uniform1f(this.u.state,states[this.state]);gl.drawArrays(gl.TRIANGLES,0,this.count);
 }
 dispose(){this.disposed=true;cancelAnimationFrame(this.raf);const gl=this.gl;Object.values(this.textures).forEach(t=>gl.deleteTexture(t));gl.deleteBuffer(this.buffer);gl.deleteProgram(this.program);}
}
global.CatPet=CatPet;
})(window);
