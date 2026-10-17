/* math.js — dependency-free LaTeX -> MathML converter (a practical subset).
 *
 * Output is native MathML, which every current browser renders, so there is
 * nothing to download and no build step. Anything the converter doesn't
 * understand degrades to a visible `\name` instead of throwing.
 *
 * Public API:  CerisierMath.render(tex, display)  -> HTML string
 */
(function (global) {
'use strict';

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

const GREEK = {
  alpha: 'α', beta: 'β', gamma: 'γ', delta: 'δ', epsilon: 'ϵ', varepsilon: 'ε', zeta: 'ζ', eta: 'η',
  theta: 'θ', vartheta: 'ϑ', iota: 'ι', kappa: 'κ', varkappa: 'ϰ', lambda: 'λ', mu: 'μ', nu: 'ν', xi: 'ξ',
  omicron: 'ο', pi: 'π', varpi: 'ϖ', rho: 'ρ', varrho: 'ϱ', sigma: 'σ', varsigma: 'ς', tau: 'τ',
  upsilon: 'υ', phi: 'ϕ', varphi: 'φ', chi: 'χ', psi: 'ψ', omega: 'ω',
  Gamma: 'Γ', Delta: 'Δ', Theta: 'Θ', Lambda: 'Λ', Xi: 'Ξ', Pi: 'Π', Sigma: 'Σ', Upsilon: 'Υ',
  Phi: 'Φ', Psi: 'Ψ', Omega: 'Ω',
};

// name -> [char, kind]   kind: 'o' = operator/relation/punctuation (<mo>), 'i' = ordinary symbol (<mi>)
const SYMBOLS = {};
function defSyms(kind, pairs) { for (const k in pairs) SYMBOLS[k] = [pairs[k], kind]; }
defSyms('o', {
  times: '×', div: '÷', cdot: '⋅', pm: '±', mp: '∓', ast: '∗', star: '⋆', circ: '∘', bullet: '•',
  oplus: '⊕', ominus: '⊖', otimes: '⊗', odot: '⊙', cup: '∪', cap: '∩', setminus: '∖', sqcup: '⊔', sqcap: '⊓',
  wedge: '∧', land: '∧', vee: '∨', lor: '∨', neg: '¬', lnot: '¬',
  leq: '≤', le: '≤', geq: '≥', ge: '≥', neq: '≠', ne: '≠', approx: '≈', equiv: '≡', sim: '∼', simeq: '≃',
  cong: '≅', propto: '∝', ll: '≪', gg: '≫', prec: '≺', succ: '≻', preceq: '⪯', succeq: '⪰',
  in: '∈', notin: '∉', ni: '∋', subset: '⊂', supset: '⊃', subseteq: '⊆', supseteq: '⊇', nsubseteq: '⊈',
  perp: '⊥', parallel: '∥', mid: '∣', nmid: '∤', vdash: '⊢', models: '⊨', top: '⊤', bot: '⊥',
  to: '→', rightarrow: '→', leftarrow: '←', gets: '←', leftrightarrow: '↔', uparrow: '↑', downarrow: '↓',
  Rightarrow: '⇒', Leftarrow: '⇐', Leftrightarrow: '⇔', implies: '⟹', impliedby: '⟸', iff: '⟺',
  longrightarrow: '⟶', longleftarrow: '⟵', Longrightarrow: '⟹', Longleftarrow: '⟸', mapsto: '↦',
  longmapsto: '⟼', hookrightarrow: '↪', rightharpoonup: '⇀', nearrow: '↗', searrow: '↘',
  ldots: '…', dots: '…', cdots: '⋯', vdots: '⋮', ddots: '⋱', therefore: '∴', because: '∵',
  langle: '⟨', rangle: '⟩', lfloor: '⌊', rfloor: '⌋', lceil: '⌈', rceil: '⌉',
  vert: '|', Vert: '‖', lvert: '|', rvert: '|', lVert: '‖', rVert: '‖', backslash: '\\',
  colon: ':', triangle: '△', square: '□', Box: '□', diamond: '◇', dagger: '†', ddagger: '‡',
});
defSyms('i', {
  infty: '∞', partial: '∂', nabla: '∇', emptyset: '∅', varnothing: '∅', forall: '∀', exists: '∃', nexists: '∄',
  hbar: 'ℏ', ell: 'ℓ', Re: 'ℜ', Im: 'ℑ', aleph: 'ℵ', wp: '℘', angle: '∠', measuredangle: '∡',
  prime: '′', degree: '°', imath: 'ı', jmath: 'ȷ', surd: '√', S: '§', P: '¶', copyright: '©',
  checkmark: '✓', clubsuit: '♣', spadesuit: '♠', heartsuit: '♡', diamondsuit: '♢', flat: '♭', sharp: '♯', natural: '♮',
});

// Large operators whose sub/superscripts go under/over (movablelimits) vs. beside (integrals).
const BIG_LIMITS = { sum: '∑', prod: '∏', coprod: '∐', bigcup: '⋃', bigcap: '⋂', bigvee: '⋁', bigwedge: '⋀',
  bigoplus: '⨁', bigotimes: '⨂', bigsqcup: '⨆', biguplus: '⨄' };
const BIG_SIDE = { int: '∫', iint: '∬', iiint: '∭', oint: '∮', oiint: '∯' };
const LIM_FUNCS = new Set(['lim', 'limsup', 'liminf', 'max', 'min', 'sup', 'inf', 'det', 'gcd', 'Pr']);
const FUNCS = new Set(['sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'arcsin', 'arccos', 'arctan', 'sinh', 'cosh',
  'tanh', 'coth', 'log', 'ln', 'lg', 'exp', 'dim', 'ker', 'deg', 'arg', 'hom', 'sgn']);
const ACCENTS = { vec: ['→', false], hat: ['^', false], widehat: ['^', true], bar: ['¯', false], overline: ['‾', true],
  tilde: ['~', false], widetilde: ['~', true], dot: ['˙', false], ddot: ['¨', false], dddot: ['⃛', false],
  check: ['ˇ', false], breve: ['˘', false], acute: ['´', false], grave: ['`', false],
  overrightarrow: ['→', true], overleftarrow: ['←', true] };
const DELIMS = { '{': '{', '}': '}', langle: '⟨', rangle: '⟩', lfloor: '⌊', rfloor: '⌋', lceil: '⌈', rceil: '⌉',
  vert: '|', Vert: '‖', lvert: '|', rvert: '|', lVert: '‖', rVert: '‖', backslash: '\\', uparrow: '↑', downarrow: '↓' };
const IGNORED = new Set(['displaystyle', 'textstyle', 'scriptstyle', 'scriptscriptstyle', 'nonumber', 'notag',
  'hline', 'hfill', 'protect', 'relax', 'centering', 'toprule', 'midrule', 'bottomrule', 'limits', 'nolimits',
  'allowbreak', 'strut', 'smash']);
const WITH_ARG_IGNORED = new Set(['label', 'hspace', 'vspace', 'hskip', 'vskip', 'ref', 'eqref', 'phantom_']);
const SPACES = { ',': '0.1667em', ':': '0.2222em', '>': '0.2222em', ';': '0.2778em', ' ': '0.25em', quad: '1em', qquad: '2em', '!': '0em' };
const FENCES = { pmatrix: ['(', ')'], bmatrix: ['[', ']'], Bmatrix: ['{', '}'], vmatrix: ['|', '|'], Vmatrix: ['‖', '‖'],
  cases: ['{', ''], dcases: ['{', ''] };
const NOT_MAP = { '=': '≠', '<': '≮', '>': '≯', in: '∉', subset: '⊄', subseteq: '⊈', supset: '⊅', supseteq: '⊉',
  equiv: '≢', sim: '≁', approx: '≉', exists: '∄', leq: '≰', geq: '≱', ni: '∌', cong: '≇', mid: '∤', parallel: '∦' };

function safeColor(c) {
  c = String(c).trim();
  if (/^#[0-9a-fA-F]{3,8}$/.test(c)) return c;
  if (/^[a-zA-Z]{3,24}$/.test(c)) return c;
  if (/^(?:rgb|hsl)a?\(\s*[\d.]+%?(?:\s*[, ]\s*[\d.]+%?){2}(?:\s*[,/]\s*[\d.]+%?)?\s*\)$/.test(c)) return c;
  return null;
}

// Unicode "mathematical alphanumeric" alphabets for \mathbb, \mathcal, \mathfrak
const ALPHA = {
  bb: { A: 0x1D538, a: 0x1D552, d: 0x1D7D8, ex: { C: 'ℂ', H: 'ℍ', N: 'ℕ', P: 'ℙ', Q: 'ℚ', R: 'ℝ', Z: 'ℤ' } },
  cal: { A: 0x1D49C, a: 0x1D4B6, d: 0, ex: { B: 'ℬ', E: 'ℰ', F: 'ℱ', H: 'ℋ', I: 'ℐ', L: 'ℒ', M: 'ℳ', R: 'ℛ', e: 'ℯ', g: 'ℊ', o: 'ℴ' } },
  frak: { A: 0x1D504, a: 0x1D51E, d: 0, ex: { C: 'ℭ', H: 'ℌ', I: 'ℑ', R: 'ℜ', Z: 'ℨ' } },
};
function mapAlpha(str, kind) {
  const t = ALPHA[kind];
  let out = '';
  for (const ch of str) {
    if (t.ex[ch]) out += t.ex[ch];
    else if (ch >= 'A' && ch <= 'Z') out += String.fromCodePoint(t.A + ch.charCodeAt(0) - 65);
    else if (ch >= 'a' && ch <= 'z') out += String.fromCodePoint(t.a + ch.charCodeAt(0) - 97);
    else if (t.d && ch >= '0' && ch <= '9') out += String.fromCodePoint(t.d + ch.charCodeAt(0) - 48);
    else out += ch;
  }
  return out;
}

const wrap = (h) => ({ h });
const mo = (c, attrs) => `<mo${attrs ? ' ' + attrs : ''}>${esc(c)}</mo>`;

class Parser {
  constructor(src) { this.s = src; this.i = 0; this.steps = 0; }
  tick() { if (++this.steps > 200000) throw new Error('expression too complex'); }
  eof() { return this.i >= this.s.length; }
  ws() { const s = this.s; while (this.i < s.length && /\s/.test(s[this.i])) this.i++; }

  readCmd() { // at a backslash
    const s = this.s;
    this.i++;
    const m = /^[A-Za-z]+/.exec(s.slice(this.i, this.i + 40));
    if (m) { this.i += m[0].length; return m[0]; }
    if (this.i >= s.length) return '';
    const ch = String.fromCodePoint(s.codePointAt(this.i));
    this.i += ch.length;
    return ch;
  }
  peekCmd() {
    this.ws();
    if (this.s[this.i] !== '\\') return null;
    const save = this.i;
    const name = this.readCmd();
    this.i = save;
    return name;
  }
  skipStray() { if (this.s[this.i] === '\\') this.readCmd(); else this.i++; }

  // Raw text of a {...} group (balanced) or a single token.
  rawGroup() {
    this.ws();
    const s = this.s;
    if (s[this.i] === '{') {
      let depth = 0; const start = this.i + 1;
      for (; this.i < s.length; this.i++) {
        const c = s[this.i];
        if (c === '\\') { this.i++; continue; }
        if (c === '{') depth++;
        else if (c === '}') { depth--; if (depth === 0) { const raw = s.slice(start, this.i); this.i++; return raw; } }
      }
      return s.slice(start); // unterminated (e.g. while streaming)
    }
    if (this.eof()) return '';
    if (s[this.i] === '\\') { const save = this.i; this.readCmd(); return s.slice(save, this.i); }
    const ch = String.fromCodePoint(s.codePointAt(this.i));
    this.i += ch.length;
    return ch;
  }

  seq() {
    let out = '';
    for (;;) {
      this.tick();
      this.ws();
      if (this.eof()) break;
      const c = this.s[this.i];
      if (c === '}' || c === '&') break;
      if (c === '\\') {
        const nm = this.peekCmd();
        if (nm === '\\' || nm === 'right' || nm === 'end' || nm === 'middle') break;
      }
      out += this.atomWithScripts();
    }
    return out;
  }

  // One argument: a {group}, a single digit/char, or a command.
  arg() {
    this.ws();
    if (this.eof()) return '<mrow></mrow>';
    const c = this.s[this.i];
    if (c === '{') { this.i++; const inner = this.seq(); this.eatClose(); return `<mrow>${inner}</mrow>`; }
    if (/[0-9]/.test(c)) { this.i++; return `<mn>${c}</mn>`; }
    return this.atom().h;
  }
  eatClose() { this.ws(); if (this.s[this.i] === '}') this.i++; }

  atomWithScripts() {
    const a = this.atom();
    let sub = null, sup = null, primes = 0;
    for (;;) {
      this.ws();
      const c = this.s[this.i];
      if (c === '^') { this.i++; const v = this.arg(); sup = sup === null ? v : `<mrow>${sup}${v}</mrow>`; }
      else if (c === '_') { this.i++; const v = this.arg(); sub = sub === null ? v : `<mrow>${sub}${v}</mrow>`; }
      else if (c === "'") { this.i++; primes++; }
      else if (c === '\\') {
        const nm = this.peekCmd();
        if (nm === 'limits') { this.readCmd(); a.limits = true; }
        else if (nm === 'nolimits') { this.readCmd(); a.limits = false; }
        else break;
      } else break;
    }
    if (primes) {
      const p = `<mo>${'′'.repeat(primes)}</mo>`;
      sup = sup === null ? p : `<mrow>${p}${sup}</mrow>`;
    }
    const post = a.post || '';
    if (sub === null && sup === null) return a.h + post;
    let h;
    if (a.limits) {
      if (sub !== null && sup !== null) h = `<munderover>${a.h}${sub}${sup}</munderover>`;
      else if (sub !== null) h = `<munder>${a.h}${sub}</munder>`;
      else h = `<mover>${a.h}${sup}</mover>`;
    } else if (sub !== null && sup !== null) h = `<msubsup>${a.h}${sub}${sup}</msubsup>`;
    else if (sub !== null) h = `<msub>${a.h}${sub}</msub>`;
    else h = `<msup>${a.h}${sup}</msup>`;
    return h + post;
  }

  atom() {
    this.tick();
    const s = this.s;
    const c = s[this.i];
    if (c === '{') { this.i++; const inner = this.seq(); this.eatClose(); return wrap(`<mrow>${inner}</mrow>`); }
    if (c === '\\') return this.command();
    if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(s[this.i + 1] || ''))) {
      const m = /^(?:\d+(?:\.\d+)?|\.\d+)/.exec(s.slice(this.i, this.i + 64));
      this.i += m[0].length;
      return wrap(`<mn>${m[0]}</mn>`);
    }
    const ch = String.fromCodePoint(s.codePointAt(this.i));
    this.i += ch.length;
    if (/[A-Za-z]/.test(ch) || /\p{L}/u.test(ch)) return wrap(`<mi>${esc(ch)}</mi>`);
    if (ch === '-') return wrap(mo('−'));
    if (ch === '*') return wrap(mo('∗'));
    if (ch === '~') return wrap('<mspace width="0.33em"></mspace>');
    if (ch === "'") return wrap(mo('′'));
    return wrap(mo(ch));
  }

  delim() {
    this.ws();
    if (this.eof()) return '';
    if (this.s[this.i] === '\\') {
      const name = this.readCmd();
      if (name === '|') return '‖';
      return DELIMS[name] || name;
    }
    const ch = this.s[this.i++];
    return ch === '.' ? '' : ch;
  }

  styled(raw, kind) {
    if (/^[A-Za-z0-9]+$/.test(raw) && kind in ALPHA) return `<mi>${mapAlpha(raw, kind)}</mi>`;
    return null;
  }
  sub(raw) { // parse an independent snippet
    const p = new Parser(raw); p.steps = this.steps;
    let out = '';
    while (!p.eof()) { out += p.seq(); if (!p.eof()) p.skipStray(); }
    this.steps = p.steps;
    return out;
  }

  command() {
    const name = this.readCmd();
    if (GREEK[name]) return wrap(`<mi>${GREEK[name]}</mi>`);
    if (SYMBOLS[name]) {
      const [ch, kind] = SYMBOLS[name];
      return wrap(kind === 'o' ? mo(ch) : `<mi>${ch}</mi>`);
    }
    if (BIG_LIMITS[name]) return { h: mo(BIG_LIMITS[name], 'largeop="true" movablelimits="true"'), limits: true };
    if (BIG_SIDE[name]) return { h: mo(BIG_SIDE[name], 'largeop="true"'), limits: false };
    if (LIM_FUNCS.has(name)) return { h: `<mo movablelimits="true">${name}</mo>`, limits: true, post: '<mspace width="0.1667em"></mspace>' };
    if (FUNCS.has(name)) return { h: `<mi>${name}</mi>`, post: '<mspace width="0.1667em"></mspace>' };
    if (ACCENTS[name]) {
      const [ch, stretchy] = ACCENTS[name];
      const base = this.arg();
      return wrap(`<mover accent="true">${base}${mo(ch, `stretchy="${stretchy}"`)}</mover>`);
    }
    if (name in SPACES) return wrap(`<mspace width="${SPACES[name]}"></mspace>`);
    if (IGNORED.has(name)) return wrap('');
    if (WITH_ARG_IGNORED.has(name)) { this.rawGroup(); return wrap(''); }

    switch (name) {
      case 'frac': case 'dfrac': case 'tfrac': case 'cfrac': {
        const a = this.arg(), b = this.arg();
        return wrap(`<mfrac>${a}${b}</mfrac>`);
      }
      case 'binom': case 'dbinom': case 'tbinom': {
        const a = this.arg(), b = this.arg();
        return wrap(`<mrow>${mo('(')}<mfrac linethickness="0">${a}${b}</mfrac>${mo(')')}</mrow>`);
      }
      case 'sqrt': {
        this.ws();
        if (this.s[this.i] === '[') {
          const end = this.s.indexOf(']', this.i);
          const idx = end < 0 ? '' : this.s.slice(this.i + 1, end);
          this.i = end < 0 ? this.s.length : end + 1;
          const body = this.arg();
          return wrap(`<mroot>${body}<mrow>${this.sub(idx)}</mrow></mroot>`);
        }
        return wrap(`<msqrt>${this.arg()}</msqrt>`);
      }
      case 'text': case 'textrm': case 'textnormal': case 'mbox': case 'hbox': case 'textsf': case 'texttt':
      case 'textbf': case 'textit': case 'textsl': case 'textup': {
        let raw = this.rawGroup().replace(/\\([{}%$&#_])/g, '$1').replace(/\s+/g, ' ');
        raw = raw.replace(/^ /, '\u00A0').replace(/ $/, '\u00A0');
        let style = '';
        if (name === 'textbf') style = ' style="font-weight:bold"';
        else if (name === 'textit' || name === 'textsl') style = ' style="font-style:italic"';
        else if (name === 'texttt') style = ' style="font-family:monospace"';
        else if (name === 'textsf') style = ' style="font-family:sans-serif"';
        return wrap(`<mtext${style}>${esc(raw)}</mtext>`);
      }
      case 'operatorname': case 'mathrm': case 'mathop': case 'mathrel': case 'mathbin': {
        let star = false;
        if (this.s[this.i] === '*') { this.i++; star = true; }
        const raw = this.rawGroup();
        if (/^[^\\{}^_]+$/.test(raw)) {
          const h = name === 'operatorname' || name === 'mathop'
            ? `<mi mathvariant="normal">${esc(raw)}</mi>` : `<mi mathvariant="normal">${esc(raw)}</mi>`;
          return { h, limits: star, post: name === 'operatorname' ? '<mspace width="0.1667em"></mspace>' : '' };
        }
        return wrap(`<mrow style="font-style:normal">${this.sub(raw)}</mrow>`);
      }
      case 'mathbb': case 'mathcal': case 'mathscr': case 'mathfrak': {
        const kind = name === 'mathbb' ? 'bb' : name === 'mathfrak' ? 'frak' : 'cal';
        const raw = this.rawGroup();
        return wrap(this.styled(raw, kind) || `<mrow>${this.sub(raw)}</mrow>`);
      }
      case 'mathbf': case 'boldsymbol': case 'bm': case 'pmb': {
        const raw = this.rawGroup();
        if (/^[A-Za-z0-9]+$/.test(raw) && name === 'mathbf') {
          return wrap(`<mi mathvariant="normal" style="font-weight:bold">${esc(raw)}</mi>`);
        }
        return wrap(`<mrow style="font-weight:bold">${this.sub(raw)}</mrow>`);
      }
      case 'mathit': case 'mathnormal': return wrap(`<mrow>${this.sub(this.rawGroup())}</mrow>`);
      case 'mathsf': return wrap(`<mrow style="font-family:sans-serif;font-style:normal">${this.sub(this.rawGroup())}</mrow>`);
      case 'mathtt': return wrap(`<mrow style="font-family:monospace;font-style:normal">${this.sub(this.rawGroup())}</mrow>`);
      case 'color': {
        const col = safeColor(this.rawGroup());
        const rest = this.seq();
        return wrap(`<mrow${col ? ` style="color:${col}"` : ''}>${rest}</mrow>`);
      }
      case 'textcolor': {
        const col = safeColor(this.rawGroup());
        const body = this.arg();
        return wrap(`<mrow${col ? ` style="color:${col}"` : ''}>${body}</mrow>`);
      }
      case 'colorbox': case 'fcolorbox': { this.rawGroup(); return wrap(this.arg()); }
      case 'boxed': return wrap(`<mrow style="border:1px solid currentColor;padding:2px 5px">${this.arg()}</mrow>`);
      case 'cancel': case 'bcancel': case 'xcancel': return wrap(`<mrow style="text-decoration:line-through">${this.arg()}</mrow>`);
      case 'phantom': case 'hphantom': case 'vphantom': return wrap(`<mphantom>${this.arg()}</mphantom>`);
      case 'underline': return wrap(`<munder accentunder="true">${this.arg()}${mo('_', 'stretchy="true"')}</munder>`);
      case 'overbrace': return { h: `<mover>${this.arg()}${mo('⏞', 'stretchy="true"')}</mover>`, limits: true };
      case 'underbrace': return { h: `<munder>${this.arg()}${mo('⏟', 'stretchy="true"')}</munder>`, limits: true };
      case 'overset': case 'stackrel': { const top = this.arg(), base = this.arg(); return wrap(`<mover>${base}${top}</mover>`); }
      case 'underset': { const under = this.arg(), base = this.arg(); return wrap(`<munder>${base}${under}</munder>`); }
      case 'xrightarrow': case 'xleftarrow': {
        let under = '';
        this.ws();
        if (this.s[this.i] === '[') {
          const end = this.s.indexOf(']', this.i);
          under = this.sub(end < 0 ? '' : this.s.slice(this.i + 1, end));
          this.i = end < 0 ? this.s.length : end + 1;
        }
        const over = this.arg();
        const arrow = mo(name === 'xrightarrow' ? '→' : '←', 'stretchy="true"');
        return wrap(under ? `<munderover>${arrow}<mrow>${under}</mrow>${over}</munderover>` : `<mover>${arrow}${over}</mover>`);
      }
      case 'not': {
        this.ws();
        let key = null;
        if (this.s[this.i] === '\\') { const save = this.i; key = this.readCmd(); if (!NOT_MAP[key]) { this.i = save; key = null; } }
        else if (NOT_MAP[this.s[this.i]]) { key = this.s[this.i++]; }
        if (key) return wrap(mo(NOT_MAP[key]));
        return wrap(mo('¬'));
      }
      case 'pmod': return wrap(`<mrow><mspace width="1em"></mspace>${mo('(')}<mi>mod</mi><mspace width="0.3em"></mspace>${this.arg()}${mo(')')}</mrow>`);
      case 'bmod': case 'mod': return wrap(`<mrow><mspace width="0.3em"></mspace><mi>mod</mi><mspace width="0.3em"></mspace></mrow>`);
      case 'tag': { const t = this.rawGroup(); return wrap(`<mrow><mspace width="2em"></mspace><mtext>(${esc(t)})</mtext></mrow>`); }
      case 'big': case 'Big': case 'bigg': case 'Bigg': case 'bigl': case 'bigr': case 'Bigl': case 'Bigr':
      case 'biggl': case 'biggr': case 'Biggl': case 'Biggr': {
        const d = this.delim();
        return wrap(d ? mo(d) : '');
      }
      case 'left': {
        const d1 = this.delim();
        let body = d1 ? mo(d1, 'fence="true" stretchy="true"') : '';
        for (;;) {
          body += this.seq();
          const nm = this.peekCmd();
          if (nm === 'middle') { this.readCmd(); const d = this.delim(); if (d) body += mo(d, 'fence="true" stretchy="true"'); continue; }
          if (nm === 'right') { this.readCmd(); const d2 = this.delim(); if (d2) body += mo(d2, 'fence="true" stretchy="true"'); }
          break;
        }
        return wrap(`<mrow>${body}</mrow>`);
      }
      case 'begin': return this.environment();
      case 'right': case 'middle': case 'end': { this.delim(); return wrap(''); } // stray
      case '\\': return wrap('<mspace linebreak="newline"></mspace>');
      case '{': case '}': return wrap(mo(name));
      case '%': case '$': case '&': case '#': case '_': return wrap(`<mi mathvariant="normal">${esc(name)}</mi>`);
      case '|': return wrap(mo('‖'));
      case '/': return wrap('');
      case '': return wrap('');
      default:
        return wrap(`<mi mathvariant="normal">\\${esc(name)}</mi>`);
    }
  }

  optionalSpacingArg() { this.ws(); const m = /^\[[^\]\n]*\]/.exec(this.s.slice(this.i, this.i + 40)); if (m) this.i += m[0].length; }

  environment() {
    const envRaw = this.rawGroup().trim();
    const base = envRaw.replace(/\*$/, '');
    let colSpec = '';
    if (base === 'array' || base === 'tabular' || base === 'subarray') colSpec = this.rawGroup();
    const rows = [];
    let row = [];
    for (;;) {
      this.tick();
      row.push(this.seq());
      this.ws();
      if (this.eof()) { rows.push(row); break; }
      const c = this.s[this.i];
      if (c === '&') { this.i++; continue; }
      if (c === '}') { this.i++; continue; }
      if (c === '\\') {
        const nm = this.peekCmd();
        if (nm === '\\') { this.readCmd(); this.optionalSpacingArg(); rows.push(row); row = []; continue; }
        if (nm === 'end') { this.readCmd(); this.rawGroup(); rows.push(row); break; }
        this.readCmd(); this.delim(); continue; // stray \right / \middle
      }
    }
    while (rows.length > 1 && rows[rows.length - 1].every((c) => c === '')) rows.pop();

    const aligns = colSpec.replace(/[^lcr]/g, '').split('');
    const isAligned = /^(aligned|align|alignat|split|eqnarray|flalign)$/.test(base);
    const isCases = base === 'cases' || base === 'dcases';
    const cellStyle = (ci) => {
      let a = 'center';
      if (isAligned) a = ci % 2 === 0 ? 'right' : 'left';
      else if (isCases) a = 'left';
      else if (aligns.length) a = { l: 'left', c: 'center', r: 'right' }[aligns[ci]] || 'center';
      const pad = isCases && ci === 0 ? ';padding-right:1em' : isAligned && ci % 2 === 1 ? ';padding-left:0' : '';
      return ` style="text-align:${a}${pad}"`;
    };
    const table = '<mtable' + (isAligned || isCases ? ' displaystyle="true"' : '') + '>' +
      rows.map((r) => '<mtr>' + r.map((c, ci) => `<mtd${cellStyle(ci)}>${c}</mtd>`).join('') + '</mtr>').join('') + '</mtable>';
    const f = FENCES[base];
    if (f) {
      return wrap(`<mrow>${mo(f[0], 'fence="true" stretchy="true"')}${table}${f[1] ? mo(f[1], 'fence="true" stretchy="true"') : ''}</mrow>`);
    }
    return wrap(table);
  }
}

function toMathML(tex) {
  const p = new Parser(tex);
  const rows = [];
  let cur = '';
  while (!p.eof()) {
    cur += p.seq();
    if (p.eof()) break;
    if (p.peekCmd() === '\\') { p.readCmd(); p.optionalSpacingArg(); rows.push(cur); cur = ''; }
    else p.skipStray();
  }
  rows.push(cur);
  const nonEmpty = rows.filter((r) => r !== '');
  if (nonEmpty.length > 1) {
    return '<mtable>' + nonEmpty.map((r) => `<mtr><mtd>${r}</mtd></mtr>`).join('') + '</mtable>';
  }
  return cur === '' && nonEmpty.length ? nonEmpty[0] : (nonEmpty[0] || '');
}

function render(tex, display) {
  tex = String(tex).trim();
  let body;
  try {
    body = toMathML(tex);
  } catch (e) {
    return `<code class="math-error">${esc(tex)}</code>`;
  }
  const math = `<math xmlns="http://www.w3.org/1998/Math/MathML"${display ? ' display="block"' : ''}>${body}</math>`;
  return display ? `<div class="math-block">${math}</div>` : `<span class="math-inline">${math}</span>`;
}

global.CerisierMath = { render, toMathML };
})(typeof window !== 'undefined' ? window : globalThis);
