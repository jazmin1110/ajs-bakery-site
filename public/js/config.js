// Site config: connection settings + display copy.
//
// Flavors, prices, box sizes and the Sunday cap/cutoff now come from the
// Supabase database (see js/supabase.js). Only things the database doesn't
// store live here: the connection, descriptions, and static wording.
// Prices shown in the browser are for DISPLAY ONLY; the database recalculates
// every total when an order is placed (see CLAUDE.md).

// Flavor badges (the little monkey stamps on the menu). Config-driven: change this list, no markup to touch.
//   key   = the flavor's name as a slug (Coco Loco -> "coco-loco"). A flavor not listed gets no badge.
//   value = a badge type from BADGE_TYPES below. Delete a line to remove that badge.
// Display only: nothing in the database.
export const FLAVOR_BADGES = {
  "coco-loco": "pick",          // AJ's Pick
  "bueno-mucho": "bestseller",  // Best seller (the owner's choice)
  // "chimp-chips": none
};
export const BADGE_TYPES = {
  pick:       { label: "AJ's Pick",   image: "badge-aj-pick" },   // chef-hat monkey (drawn a bit larger in the CSS: its detail blurs when small)
  bestseller: { label: "Best seller", image: "badge-tongue" },    // tongue-out monkey
};

// "Coming soon" flavors: placeholders shown under the menu until each one is ready to sell.
// Display only: they are NOT in the database, so they can't be ordered or counted toward caps.
// When a flavor's final details are ready: add it to flavor-content.json + the flavors table,
// then delete its line here. Delete them all and the section hides itself.
//   teaser = optional one-liner (leave "" until the owner writes it; never invent ingredients)
export const COMING_SOON = [
  { name: "Nutella",       emoji: "🌰", teaser: "" },
  { name: "Biscoff",       emoji: "🍪", teaser: "" },
  { name: "Peanut Butter", emoji: "🥜", teaser: "" },
];

export const CONFIG = {
  brandName: "AJ's Bakery",
  tagline: "Small-batch brown butter cookies, baked at home in Manila.",
  timezone: "Asia/Manila",

  // --- Supabase connection (Project Settings > API in the dashboard) ---
  // The URL is public. The anon key is ALSO safe in browser code: it can only
  // do what Row Level Security allows. NEVER paste the service_role key here.
  supabaseUrl: "https://jzkehcfhuanavjdkbrpn.supabase.co",
  supabaseAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imp6a2VoY2ZodWFuYXZqZGticnBuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE0NjQwMjcsImV4cCI6MjEwNzA0MDAyN30.QSQyjcQhbeclzfOGw_7fuw68sLDyXKiXIh1rSmocdCw",

  // Instagram
  instagramUrl: "https://instagram.com/ajs.mnl",
  instagramHandle: "@ajs.mnl",

  // Description, photo and fallback emoji for each flavor, keyed by the flavor's
  // slug in the database. (The flavor NAME lives in the database.)
  // A flavor with no entry here still shows up, with an emoji and no description.
  flavorInfo: {
    "choc-chip": {
      emoji: "🍪",
      image: "assets/flavors/chimp-chips.jpg",
      description: "Nutty brown butter packed with Callebaut dark chocolate. Soft, chewy, and the one to start with.",
    },
    "double-choc": {
      emoji: "🍫",
      image: "assets/flavors/coco-loco.jpg",
      description: "Dutch cocoa dough with Callebaut dark chocolate chunks. Rich, deep, and not bitter.",
    },
    "kinder-bueno": {
      emoji: "🥜",
      image: "assets/flavors/bueno-mucho.jpg",
      description: "Half a Kinder Bueno hidden inside, with Kinder Maxi chocolate in the dough. Our biggest cookie.",
    },
  },

  // Cache-busting numbers for the photos that aren't flavor photos (those use flavors.photo_version in
  // the database). Replaced a file? Add 1 here, deploy. The site loads it as assets/logo.png?v=<number>.
  assetVersions: { logo: 2, gcashQr: 1 },

  maxBoxesPerOrder: 3, // cart limit (the checkout step must respect this too)
  // Order minimums (copy only: the database enforces them): pickup = 1 cookie; delivery = 2 cookies OR ₱200.
  minPickupCookies: 1,
  minDeliveryCookies: 2,
  minDeliveryTotal: 200,

  // Copy only: the real limit (weekly_cap on each flavor, 15 each) and the cutoff are enforced by the database.
  // This number is just the fallback for the "15 of each flavor" wording until the live data loads.
  weeklyCapPerFlavor: 15,
  // A sanity limit on the cart's size (so nobody's cart grows forever). The database's
  // per-flavor weekly caps are the real limit.
  maxCookiesInCart: 90,
  cutoff: { label: "Wednesday 9pm" },

  pickupWindow: "3-6pm",
  pickupArea: "Pickup is at Corinthian Gardens Village, Quezon City. We'll send the exact address on Instagram once your payment is confirmed.",
  unpaidExpiryHours: 24,
};
