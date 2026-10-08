// Site config: connection settings + display copy.
//
// Flavors, prices, box sizes and the Sunday cap/cutoff now come from the
// Supabase database (see js/supabase.js). Only things the database doesn't
// store live here: the connection, descriptions, and static wording.
// Prices shown in the browser are for DISPLAY ONLY; the database recalculates
// every total when an order is placed (see CLAUDE.md).

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
      description: "Classic nutty brown butter chocolate chip cookie.",
    },
    "double-choc": {
      emoji: "🍫",
      image: "assets/flavors/coco-loco.jpg",
      description: "Double chocolate brown butter chocolate chip cookie.",
    },
    "kinder-bueno": {
      emoji: "🥜",
      image: "assets/flavors/bueno-mucho.jpg",
      description: "Nutty brown butter with Kinder Maxi chocolate and a bueno center.",
    },
  },

  // One-liner for each box, keyed by box size.
  boxBlurbs: {
    4: "A little treat for you, or a gift for one.",
    6: "Share it (or don't). Best for gifting.",
  },

  maxBoxesPerOrder: 3, // cart limit (the checkout step must respect this too)
  minCookiesPerOrder: 2, // copy only: the database enforces the minimum (singles + boxes combined)

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
