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

  // Links (placeholder until the real handle is set)
  instagramUrl: "https://instagram.com/",
  instagramHandle: "@ajsbakery",

  // Text and emoji for each flavor, keyed by the flavor's slug in the database.
  // A flavor with no entry here still shows up (with a generic description).
  flavorInfo: {
    "choc-chip": {
      emoji: "🍪",
      description: "Nutty brown butter dough, melty chocolate chips, crisp edges and a soft middle.",
    },
    "double-choc": {
      emoji: "🍫",
      description: "Deep cocoa dough packed with chocolate chunks. For the chocolate-first crowd.",
    },
    "kinder-bueno": {
      emoji: "🥜",
      description: "Brown butter dough stuffed with Kinder Bueno. Gooey, hazelnutty, a little extra.",
    },
  },

  // One-liner for each box, keyed by box size.
  boxBlurbs: {
    4: "A little treat for you, or a gift for one.",
    6: "Share it (or don't). Best for gifting.",
  },

  maxBoxesPerOrder: 3, // cart limit (the checkout step must respect this too)

  // Copy only: the real cap (45) and cutoff are enforced by the database.
  capPerSunday: 45,
  cutoff: { label: "Wednesday 9pm" },

  pickupWindow: "3-6pm",
  // PLACEHOLDER: replace with the real pickup area before launch
  pickupArea: "Pickup is in [your area], Metro Manila. We'll send the exact address on Instagram once your payment is confirmed.",
  unpaidExpiryHours: 24,
};
