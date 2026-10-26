package com.topdown.app

/** سكربتات تُحقن في الصفحة. لا تغيّر شيئًا في الموقع، فقط تقرأ الوسائط وتساعد في التحميل. */
object Scripts {

    /** يرصد الفيديو/الصوت وروابط الملفات ويرسلها للتطبيق عند تغيّرها. */
    val MEDIA_SCANNER = """
(function(){
  if (window.__tdScan) { window.__tdScan(); return; }
  var EXT = /\.(mp4|m4v|webm|mkv|mov|avi|3gp|flv|mp3|m4a|aac|wav|ogg|opus|flac|zip|rar|7z|apk|pdf)(\?|#|$)/i;
  var AUD = /\.(mp3|m4a|aac|wav|ogg|opus|flac)(\?|#|$)/i;
  var VID = /\.(mp4|m4v|webm|mkv|mov|avi|3gp|flv)(\?|#|$)/i;
  var last = '';
  function abs(u){ try { return new URL(u, location.href).href; } catch(e){ return ''; } }
  function kindOf(u, tag, type){
    type = (type||'').toLowerCase();
    if (tag==='video' || type.indexOf('video')===0 || VID.test(u)) return 'video';
    if (tag==='audio' || type.indexOf('audio')===0 || AUD.test(u)) return 'audio';
    return 'file';
  }
  function txt(el){ return ((el && (el.getAttribute('title')||el.innerText||el.textContent))||'').replace(/\s+/g,' ').trim().slice(0,80); }
  function scan(){
    var out = [];
    function add(u, label, kind, height, mime, q){
      u = abs(u); if (!u || u.indexOf('http')!==0) return;
      out.push({url:u, label:label||'', kind:kind, height:height||0, mime:mime||'', q:q||''});
    }
    document.querySelectorAll('video,audio').forEach(function(m){
      var tag = m.tagName.toLowerCase();
      var s = m.currentSrc || m.getAttribute('src') || '';
      if (s && s.indexOf('blob:')!==0) add(s, document.title, tag, m.videoHeight||0, '', '');
      m.querySelectorAll('source').forEach(function(src){
        var u = src.getAttribute('src'); if (!u) return;
        var q = src.getAttribute('label')||src.getAttribute('data-quality')||src.getAttribute('size')||src.getAttribute('res')||src.getAttribute('title')||'';
        add(u, q || document.title, tag, parseInt(src.getAttribute('size')||src.getAttribute('res')||'0')||0, src.getAttribute('type'), q);
      });
    });
    document.querySelectorAll('a[href]').forEach(function(a){
      var h = a.getAttribute('href')||'';
      if (h.indexOf('javascript:')===0 || h.charAt(0)==='#') return;
      var u = abs(h);
      var q = a.getAttribute('data-quality')||a.getAttribute('data-res')||'';
      var label = txt(a);
      if (EXT.test(u) || a.hasAttribute('download') || q || /\b(2160|1440|1080|720|480|360|240)p\b/i.test(label)) {
        add(u, label, kindOf(u, '', a.getAttribute('type')), 0, a.getAttribute('type'), q);
      }
    });
    var json = JSON.stringify(out);
    if (json !== last) { last = json; try { TopdownApp.onMedia(json); } catch(e){} }
  }
  window.__tdScan = scan;
  var t = null;
  new MutationObserver(function(){ clearTimeout(t); t = setTimeout(scan, 600); })
    .observe(document.documentElement, {childList:true, subtree:true, attributes:true, attributeFilter:['src','href']});
  document.addEventListener('loadedmetadata', function(){ setTimeout(scan, 100); }, true);
  scan();
})();
""".trimIndent()

    /** يحوّل رابط blob: إلى ملف عبر إرساله على دفعات للتطبيق. */
    fun blobFetcher(url: String, fileName: String, mime: String): String {
        val u = org.json.JSONObject.quote(url)
        val n = org.json.JSONObject.quote(fileName)
        val m = org.json.JSONObject.quote(mime)
        return """
(function(){
  var id = 'b' + Date.now() + Math.floor(Math.random()*1e6);
  fetch($u).then(function(r){ return r.blob(); }).then(function(blob){
    var type = blob.type || $m;
    TopdownApp.blobStart(id, $n, type, blob.size);
    var CH = 512*1024, off = 0;
    function next(){
      if (off >= blob.size) { TopdownApp.blobEnd(id); return; }
      var fr = new FileReader();
      fr.onload = function(){ var s = fr.result; TopdownApp.blobChunk(id, s.substring(s.indexOf(',')+1)); off += CH; next(); };
      fr.onerror = function(){ TopdownApp.blobFail(id); };
      fr.readAsDataURL(blob.slice(off, off+CH));
    }
    next();
  }).catch(function(){ TopdownApp.blobFail(id); });
})();
""".trimIndent()
    }
}
