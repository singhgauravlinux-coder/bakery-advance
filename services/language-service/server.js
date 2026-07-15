'use strict';
const express = require('express');
const pino = require('pino');
const pinoHttp = require('pino-http');

const SERVICE_NAME = process.env.SERVICE_NAME || 'language-service';
const PORT = Number(process.env.PORT || 3000);

// All logs are structured JSON on stdout (12-factor), ready for
// Fluent Bit / Loki / ELK collection from the container runtime.
const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  timestamp: pino.stdTimeFunctions.isoTime,
  base: { service: SERVICE_NAME, version: process.env.SERVICE_VERSION || '1.0.0' },
  formatters: { level: (label) => ({ level: label }) }
});

const app = express();
app.use(express.json());
app.use(pinoHttp({
  logger,
  customProps: (req) => ({ requestId: req.headers['x-request-id'] || undefined })
}));

// --- Kubernetes probes -------------------------------------------------
app.get('/health', (req, res) => res.json({ status: 'ok', service: SERVICE_NAME }));
app.get('/ready', (req, res) => res.json({ ready: true, service: SERVICE_NAME }));

// --- Language catalog ----------------------------------------------------
// English is the source-of-truth locale; every other locale below is a
// full translation of the UI string bundle further down this file.
const DEFAULT_LANG = 'en';
const LANGUAGES = {
  en: { name: 'English',    nativeName: 'English',   direction: 'ltr' },
  es: { name: 'Spanish',    nativeName: 'Español',   direction: 'ltr' },
  fr: { name: 'French',     nativeName: 'Français',  direction: 'ltr' },
  de: { name: 'German',     nativeName: 'Deutsch',   direction: 'ltr' },
  it: { name: 'Italian',    nativeName: 'Italiano',  direction: 'ltr' },
  pt: { name: 'Portuguese', nativeName: 'Português', direction: 'ltr' },
  nl: { name: 'Dutch',      nativeName: 'Nederlands',direction: 'ltr' },
  ru: { name: 'Russian',    nativeName: 'Русский',   direction: 'ltr' },
  tr: { name: 'Turkish',    nativeName: 'Türkçe',    direction: 'ltr' },
  ar: { name: 'Arabic',     nativeName: 'العربية',   direction: 'rtl' },
  hi: { name: 'Hindi',      nativeName: 'हिन्दी',     direction: 'ltr' },
  zh: { name: 'Chinese (Simplified)', nativeName: '中文', direction: 'ltr' },
  ja: { name: 'Japanese',   nativeName: '日本語',     direction: 'ltr' },
  ko: { name: 'Korean',     nativeName: '한국어',     direction: 'ltr' }
};

// --- UI string bundles ---------------------------------------------------
// Small, curated set of keys used across the storefront chrome. Add new
// keys to every locale below to keep bundles complete; missing keys fall
// back to the English string at read time.
const STRINGS = {
  en: { nav_home: 'Home', nav_products: 'Products', nav_cart: 'Cart', action_add_to_cart: 'Add to Cart', action_checkout: 'Checkout', action_search: 'Search', label_total: 'Total', label_out_of_stock: 'Out of Stock', msg_order_confirmed: 'Your order has been confirmed', msg_welcome: 'Welcome to Crumb & Ember' },
  es: { nav_home: 'Inicio', nav_products: 'Productos', nav_cart: 'Carrito', action_add_to_cart: 'Añadir al carrito', action_checkout: 'Finalizar compra', action_search: 'Buscar', label_total: 'Total', label_out_of_stock: 'Agotado', msg_order_confirmed: 'Tu pedido ha sido confirmado', msg_welcome: 'Bienvenido a Crumb & Ember' },
  fr: { nav_home: 'Accueil', nav_products: 'Produits', nav_cart: 'Panier', action_add_to_cart: 'Ajouter au panier', action_checkout: 'Passer la commande', action_search: 'Rechercher', label_total: 'Total', label_out_of_stock: 'Rupture de stock', msg_order_confirmed: 'Votre commande a été confirmée', msg_welcome: 'Bienvenue chez Crumb & Ember' },
  de: { nav_home: 'Startseite', nav_products: 'Produkte', nav_cart: 'Warenkorb', action_add_to_cart: 'In den Warenkorb', action_checkout: 'Zur Kasse', action_search: 'Suchen', label_total: 'Gesamt', label_out_of_stock: 'Nicht vorrätig', msg_order_confirmed: 'Ihre Bestellung wurde bestätigt', msg_welcome: 'Willkommen bei Crumb & Ember' },
  it: { nav_home: 'Home', nav_products: 'Prodotti', nav_cart: 'Carrello', action_add_to_cart: 'Aggiungi al carrello', action_checkout: 'Procedi al pagamento', action_search: 'Cerca', label_total: 'Totale', label_out_of_stock: 'Esaurito', msg_order_confirmed: 'Il tuo ordine è stato confermato', msg_welcome: 'Benvenuto su Crumb & Ember' },
  pt: { nav_home: 'Início', nav_products: 'Produtos', nav_cart: 'Carrinho', action_add_to_cart: 'Adicionar ao carrinho', action_checkout: 'Finalizar compra', action_search: 'Pesquisar', label_total: 'Total', label_out_of_stock: 'Esgotado', msg_order_confirmed: 'O seu pedido foi confirmado', msg_welcome: 'Bem-vindo à Crumb & Ember' },
  nl: { nav_home: 'Start', nav_products: 'Producten', nav_cart: 'Winkelwagen', action_add_to_cart: 'In winkelwagen', action_checkout: 'Afrekenen', action_search: 'Zoeken', label_total: 'Totaal', label_out_of_stock: 'Niet op voorraad', msg_order_confirmed: 'Uw bestelling is bevestigd', msg_welcome: 'Welkom bij Crumb & Ember' },
  ru: { nav_home: 'Главная', nav_products: 'Продукты', nav_cart: 'Корзина', action_add_to_cart: 'Добавить в корзину', action_checkout: 'Оформить заказ', action_search: 'Поиск', label_total: 'Итого', label_out_of_stock: 'Нет в наличии', msg_order_confirmed: 'Ваш заказ подтверждён', msg_welcome: 'Добро пожаловать в Crumb & Ember' },
  tr: { nav_home: 'Ana Sayfa', nav_products: 'Ürünler', nav_cart: 'Sepet', action_add_to_cart: 'Sepete Ekle', action_checkout: 'Ödeme', action_search: 'Ara', label_total: 'Toplam', label_out_of_stock: 'Stokta Yok', msg_order_confirmed: 'Siparişiniz onaylandı', msg_welcome: "Crumb & Ember'e Hoş Geldiniz" },
  ar: { nav_home: 'الرئيسية', nav_products: 'المنتجات', nav_cart: 'عربة التسوق', action_add_to_cart: 'أضف إلى السلة', action_checkout: 'إتمام الشراء', action_search: 'بحث', label_total: 'الإجمالي', label_out_of_stock: 'غير متوفر', msg_order_confirmed: 'تم تأكيد طلبك', msg_welcome: 'مرحبًا بك في Crumb & Ember' },
  hi: { nav_home: 'होम', nav_products: 'उत्पाद', nav_cart: 'कार्ट', action_add_to_cart: 'कार्ट में जोड़ें', action_checkout: 'चेकआउट', action_search: 'खोजें', label_total: 'कुल', label_out_of_stock: 'स्टॉक में नहीं', msg_order_confirmed: 'आपका ऑर्डर पुष्ट हो गया है', msg_welcome: 'Crumb & Ember में आपका स्वागत है' },
  zh: { nav_home: '首页', nav_products: '产品', nav_cart: '购物车', action_add_to_cart: '加入购物车', action_checkout: '结账', action_search: '搜索', label_total: '总计', label_out_of_stock: '缺货', msg_order_confirmed: '您的订单已确认', msg_welcome: '欢迎光临 Crumb & Ember' },
  ja: { nav_home: 'ホーム', nav_products: '商品', nav_cart: 'カート', action_add_to_cart: 'カートに追加', action_checkout: '購入手続き', action_search: '検索', label_total: '合計', label_out_of_stock: '在庫切れ', msg_order_confirmed: 'ご注文が確定しました', msg_welcome: 'Crumb & Emberへようこそ' },
  ko: { nav_home: '홈', nav_products: '상품', nav_cart: '장바구니', action_add_to_cart: '장바구니에 담기', action_checkout: '결제하기', action_search: '검색', label_total: '합계', label_out_of_stock: '품절', msg_order_confirmed: '주문이 확정되었습니다', msg_welcome: 'Crumb & Ember에 오신 것을 환영합니다' }
};

const normalize = (code) => String(code || '').trim().toLowerCase().split('-')[0];
const known = (code) => Object.prototype.hasOwnProperty.call(LANGUAGES, code);

function bundleFor(code) {
  const base = STRINGS[DEFAULT_LANG];
  const locale = STRINGS[code] || {};
  const merged = { ...base, ...locale };
  const missing = Object.keys(base).filter((k) => !(k in locale));
  return { merged, missing };
}

// Parses a raw "Accept-Language" header (e.g. "fr-CA,fr;q=0.9,en;q=0.8")
// into a list of {code, q} sorted by descending quality.
function parseAcceptLanguage(header) {
  if (!header) return [];
  return String(header)
    .split(',')
    .map((part) => {
      const [rawCode, rawQ] = part.trim().split(';q=');
      const code = normalize(rawCode);
      const q = rawQ ? Number(rawQ) : 1;
      return { code, q: Number.isFinite(q) ? q : 1 };
    })
    .filter((entry) => entry.code)
    .sort((a, b) => b.q - a.q);
}

// GET /languages — full catalog of supported UI locales
app.get(['/language', '/language/languages'], (req, res) => {
  res.json({
    default: DEFAULT_LANG,
    languages: Object.entries(LANGUAGES).map(([code, l]) => ({ code, ...l }))
  });
});

// GET /language/detect — resolve the best supported language for a client.
// Priority: explicit ?lang= override, then the Accept-Language header,
// then DEFAULT_LANG. Also accepts a raw header via ?acceptLanguage= for
// easy testing without setting request headers.
app.get('/language/detect', (req, res) => {
  const override = normalize(req.query.lang);
  if (override) {
    if (!known(override)) return res.status(400).json({ error: `Unknown language "${override}"`, supported: Object.keys(LANGUAGES) });
    return res.json({ resolved: override, reason: 'override', ...LANGUAGES[override] });
  }

  const header = req.query.acceptLanguage || req.headers['accept-language'];
  const candidates = parseAcceptLanguage(header);
  const match = candidates.find((c) => known(c.code));

  const resolved = match ? match.code : DEFAULT_LANG;
  req.log.info({ event: 'language_detected', resolved, header: header || null }, 'language detected');
  res.json({
    resolved,
    reason: match ? 'accept-language' : 'default',
    candidates,
    ...LANGUAGES[resolved]
  });
});

// GET /language/strings?lang=xx — UI string bundle for a locale (also
// accepts POST with a JSON body: { "lang": "xx" })
function handleStrings(req, res) {
  const src = req.method === 'POST' ? (req.body || {}) : req.query;
  const code = normalize(src.lang || DEFAULT_LANG);
  if (!known(code)) return res.status(400).json({ error: `Unknown language "${code}"`, supported: Object.keys(LANGUAGES) });
  const { merged, missing } = bundleFor(code);
  res.json({
    lang: code,
    direction: LANGUAGES[code].direction,
    fallback: DEFAULT_LANG,
    strings: merged,
    missingKeys: missing
  });
}
app.get('/language/strings', handleStrings);
app.post('/language/strings', handleStrings);

// --- 404 + error handling ----------------------------------------------
app.use((req, res) => res.status(404).json({ error: 'Route not found' }));
app.use((err, req, res, next) => {
  req.log.error({ event: 'unhandled_error', message: err.message }, 'request failed');
  res.status(500).json({ error: 'Internal server error' });
});

const server = app.listen(PORT, () => logger.info({ event: 'service_started', port: PORT }, `${SERVICE_NAME} listening`));

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    logger.info({ event: 'shutdown', signal }, 'shutting down gracefully');
    server.close(() => process.exit(0));
  });
}
