/* =========================================================
   Jarvis landing page — interactions
   Vanilla JS, no dependencies. Every lookup is null-safe.
   ========================================================= */
(function () {
  "use strict";

  /* ---------- helpers ---------- */
  var $ = function (sel, ctx) { return (ctx || document).querySelector(sel); };
  var $$ = function (sel, ctx) {
    return Array.prototype.slice.call((ctx || document).querySelectorAll(sel));
  };

  var prefersReduced =
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- 1. Reveal on scroll (IntersectionObserver) ---------- */
  function initReveal() {
    var items = $$(".reveal");
    if (!items.length) return;

    // Fallback: if IO is unavailable, just show everything.
    if (typeof window.IntersectionObserver !== "function" || prefersReduced) {
      items.forEach(function (el) { el.classList.add("is-visible"); });
      return;
    }

    var io = new IntersectionObserver(
      function (entries, observer) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
    );

    items.forEach(function (el, i) {
      // small stagger for siblings within the same grid row
      var delay = Math.min((i % 4) * 70, 240);
      el.style.transitionDelay = delay + "ms";
      io.observe(el);
    });
  }

  /* ---------- 2. Nav scrolled state ---------- */
  function initNavScroll() {
    var nav = $("#nav");
    if (!nav) return;

    var ticking = false;
    var apply = function () {
      nav.classList.toggle("is-scrolled", window.scrollY > 8);
      ticking = false;
    };
    var onScroll = function () {
      if (!ticking) {
        window.requestAnimationFrame(apply);
        ticking = true;
      }
    };

    apply();
    window.addEventListener("scroll", onScroll, { passive: true });
  }

  /* ---------- 3. Mobile menu ---------- */
  function initMobileMenu() {
    var toggle = $("#navToggle");
    var menu = $("#navMobile");
    if (!toggle || !menu) return;

    var setOpen = function (open) {
      menu.classList.toggle("is-open", open);
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    };

    toggle.addEventListener("click", function () {
      setOpen(!menu.classList.contains("is-open"));
    });

    // Close after tapping a link.
    $$("a", menu).forEach(function (link) {
      link.addEventListener("click", function () { setOpen(false); });
    });

    // Close on Escape.
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") setOpen(false);
    });

    // Close if resized up to desktop width.
    window.addEventListener("resize", function () {
      if (window.innerWidth > 880) setOpen(false);
    });
  }

  /* ---------- 4. Current year in footer ---------- */
  function initYear() {
    var el = $("#year");
    if (el) el.textContent = String(new Date().getFullYear());
  }

  /* ---------- 5. Subtle parallax on the hero orb ---------- */
  function initOrbParallax() {
    if (prefersReduced) return;
    var orb = $(".hero__visual .orb");
    var hero = $("#hero");
    if (!orb || !hero) return;

    hero.addEventListener("mousemove", function (e) {
      var rect = hero.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      var dx = (e.clientX - rect.left) / rect.width - 0.5;
      var dy = (e.clientY - rect.top) / rect.height - 0.5;
      orb.style.transform = "translate(" + dx * 22 + "px, " + dy * 22 + "px)";
    });
    hero.addEventListener("mouseleave", function () {
      orb.style.transform = "";
    });
  }

  /* ---------- boot ---------- */
  function init() {
    initReveal();
    initNavScroll();
    initMobileMenu();
    initYear();
    initOrbParallax();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
