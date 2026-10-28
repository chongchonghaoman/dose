export class LutBrowser {
  constructor({getContext,onChoose,onFavorite}){
    this.getContext=getContext;this.onChoose=onChoose;this.onFavorite=onFavorite;this.page=0;this.onlyFavorites=false;this.pageSize=12;
    this.dialog=document.querySelector('#lut-dialog');this.grid=document.querySelector('#lut-grid');this.search=document.querySelector('#lut-search');
    document.querySelector('#lut-close').onclick=()=>this.close();
    this.dialog.addEventListener('close',()=>{this.grid.replaceChildren();document.querySelector('#browse-luts').focus();});
    this.search.oninput=()=>{this.page=0;this.render();};
    document.querySelector('#lut-search-clear').onclick=()=>{this.search.value='';this.page=0;this.render();this.search.focus();};
    document.querySelector('#lut-favorites').onclick=()=>{this.onlyFavorites=!this.onlyFavorites;this.page=0;this.render();};
    document.querySelector('#lut-previous').onclick=()=>{this.page--;this.render();};
    document.querySelector('#lut-next').onclick=()=>{this.page++;this.render();};
  }
  get open(){return this.dialog.open;}
  show(){if(!this.getContext().photo)return;this.page=0;this.search.value='';this.render();this.dialog.showModal();this.search.focus();}
  close(){this.dialog.close();}
  render(){
    const {photo,adjustments,library,favorites}=this.getContext();if(!photo)return this.close();
    const q=this.search.value.trim().normalize('NFKC').toLocaleLowerCase();
    const all=[{hash:'',name:'无风格'},...library.filter(l=>l.available!==false)];
    const rows=all.filter(l=>(!this.onlyFavorites||favorites.includes(l.hash))&&l.name.normalize('NFKC').toLocaleLowerCase().includes(q));
    const pages=Math.max(1,Math.ceil(rows.length/this.pageSize));this.page=Math.max(0,Math.min(this.page,pages-1));this.grid.replaceChildren();this.grid.scrollTop=0;
    document.querySelector('#lut-favorites').setAttribute('aria-pressed',String(this.onlyFavorites));
    document.querySelector('#lut-search-clear').hidden=!q;
    document.querySelector('#lut-pages').hidden=pages<=1;
    document.querySelector('#lut-page').textContent=(this.page+1)+' / '+pages;
    document.querySelector('#lut-previous').disabled=this.page===0;document.querySelector('#lut-next').disabled=this.page===pages-1;
    document.querySelector('#lut-empty').hidden=!!rows.length;document.querySelector('#lut-empty').textContent=this.onlyFavorites&&!q?'还没有收藏':'没有匹配的风格';
    for(const lut of rows.slice(this.page*this.pageSize,(this.page+1)*this.pageSize)){
      const card=document.createElement('div');card.className='lut-card';card.dataset.lut=lut.hash;
      const button=document.createElement('button');button.className='lut-apply';button.title=lut.name;button.setAttribute('aria-label',lut.name);
      const active=adjustments.engine!=='spectral'&&(adjustments.lut?adjustments.lutId:'')===lut.hash;button.setAttribute('aria-pressed',String(active));
      const img=document.createElement('img');img.alt='';img.loading='lazy';img.decoding='async';
      const a=globalThis.LightTableFilm.withLut(adjustments,lut.hash);
      img.src='photo://'+photo.id+'/image?size=320&edit='+encodeURIComponent(JSON.stringify(a))+'&lutHash='+lut.hash;
      img.onerror=()=>{card.classList.add('unavailable');button.disabled=true;label.textContent=lut.name+' · 预览不可用';};
      const label=document.createElement('span');label.textContent=lut.name;button.append(img,label);
      button.onclick=()=>{this.onChoose(lut.hash);this.close();};card.append(button);
      if(lut.hash){
        const star=document.createElement('button');star.className='lut-star';
        const setStar=()=>{const active=this.getContext().favorites.includes(lut.hash);star.textContent=active?'★':'☆';star.setAttribute('aria-pressed',String(active));star.setAttribute('aria-label',(active?'取消收藏 ':'收藏 ')+lut.name);star.title=star.getAttribute('aria-label');};
        setStar();star.onclick=async()=>{star.disabled=true;try{await this.onFavorite(lut.hash);setStar();if(this.onlyFavorites)this.render();}finally{star.disabled=false;}};card.append(star);
      }
      this.grid.append(card);
    }
  }
}
