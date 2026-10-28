(function () {
  var toc = document.getElementById('toc');
  var toggle = document.querySelector('.toc-toggle');
  var links = Array.prototype.slice.call(toc.querySelectorAll('.toc-part ol a'));
  var byId = {};
  links.forEach(function (a) { byId[a.getAttribute('href').slice(1)] = a; });

  var mq = window.matchMedia('(max-width: 960px)');
  function applyLayout() {
    if (mq.matches) { toc.hidden = true; toggle.setAttribute('aria-expanded', 'false'); }
    else { toc.hidden = false; }
  }
  applyLayout();
  if (mq.addEventListener) mq.addEventListener('change', applyLayout); else mq.addListener(applyLayout);

  toggle.addEventListener('click', function () {
    toc.hidden = !toc.hidden;
    toggle.setAttribute('aria-expanded', String(!toc.hidden));
  });
  toc.addEventListener('click', function (e) {
    if (mq.matches && e.target.tagName === 'A') { toc.hidden = true; toggle.setAttribute('aria-expanded', 'false'); }
  });

  var headings = Array.prototype.slice.call(document.querySelectorAll('.body h2'));
  var active = null;
  function setActive(id) {
    if (active === id) return;
    if (active && byId[active]) byId[active].classList.remove('is-active');
    active = id;
    if (byId[id]) {
      byId[id].classList.add('is-active');
      var r = byId[id].getBoundingClientRect(), t = toc.getBoundingClientRect();
      if (r.top < t.top + 40 || r.bottom > t.bottom - 40) byId[id].scrollIntoView({ block: 'center' });
    }
  }
  function update() {
    var line = 96, current = headings[0];
    for (var i = 0; i < headings.length; i++) {
      if (headings[i].getBoundingClientRect().top <= line) current = headings[i]; else break;
    }
    if (current) setActive(current.id);
  }
  var pending = false;
  window.addEventListener('scroll', function () {
    if (pending) return; pending = true;
    requestAnimationFrame(function () { pending = false; update(); });
  }, { passive: true });
  update();
})();
