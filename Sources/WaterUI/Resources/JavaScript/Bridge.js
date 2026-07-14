(function(){
  if (window.__waterui) { return; }
  function toBase64Utf8(s){ return btoa(unescape(encodeURIComponent(s))); }
  function fromBase64Utf8(b64){ return decodeURIComponent(escape(atob(b64))); }
  window.__waterui = { pending: Object.create(null), toBase64Utf8: toBase64Utf8, fromBase64Utf8: fromBase64Utf8 };
  window.__wateruiResolve = function(id, ok, payload){
    var p = window.__waterui.pending[id];
    if (!p) { return; }
    delete window.__waterui.pending[id];
    if (ok) { p.resolve(payload); } else { p.reject(payload); }
  };
})();
