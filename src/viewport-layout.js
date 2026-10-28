// Window fitting shares the magazine composition grammar; only the paper's
// dimensions and collection size differ. There is no grid fallback.
(function(root){
  const composer=typeof module==='object'&&module.exports?require('./editorial-layout.js'):root.DoseLayout;
  const api={layoutViewport(input,options){return composer.layoutViewport(Array.isArray(input)?input:input?.photos||[],options);}};
  if(typeof module==='object'&&module.exports)module.exports=api;else root.DoseViewportLayout=api;
})(typeof globalThis!=='undefined'?globalThis:this);
