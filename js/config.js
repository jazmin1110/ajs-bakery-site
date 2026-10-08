// Business config: the ONE place for flavors, prices, box sizes, cap and cutoff.
// This is display-only. The database enforces the real rules (see CLAUDE.md).
// Change a number here and every page updates, because pages render from this object.

export const CONFIG = {
  brandName: "AJ's Bakery",
  tagline: "Small-batch brown butter cookies, baked at home in Manila.",
  timezone: "Asia/Manila",

  // PLACEHOLDER until the database assigns the real Sunday.
  nowOrderingFor: "Sunday, Oct 18",

  // Links (placeholder until the real handle is set)
  instagramUrl: "https://instagram.com/",
  instagramHandle: "@ajsbakery",

  // Prices are per cookie, in pesos.
  flavors: [
    {
      id: "choc-chip",
      name: "Brown Butter Choc Chip",
      description: "Nutty brown butter dough, melty chocolate chips, crisp edges and a soft middle.",
      price: 95,
      boxSurcharge: 0, // extra pesos per cookie when inside a box
    },
    {
      id: "double-choc",
      name: "Brown Butter Double Chocolate",
      description: "Deep cocoa dough packed with chocolate chunks. For the chocolate-first crowd.",
      price: 100,
      boxSurcharge: 0,
    },
    {
      id: "kinder-bueno",
      name: "Brown Butter Kinder Bueno",
      description: "Brown butter dough stuffed with Kinder Bueno. Gooey, hazelnutty, a little extra.",
      price: 125,
      boxSurcharge: 30, // +P30 per Bueno cookie over the P95 base, inside box totals
    },
  ],

  // Box prices are flat for the base flavors. Bueno cookies add their boxSurcharge.
  boxes: [
    { id: "box-4", size: 4, price: 380, blurb: "A little treat for you, or a gift for one." },
    { id: "box-6", size: 6, price: 570, blurb: "Share it (or don't). Best for gifting." },
  ],

  capPerSunday: 45, // max cookies per Sunday

  // Cutoff: a Sunday accepts orders until 4 days before, at 21:00 (Wednesday 9pm).
  cutoff: { daysBeforeSunday: 4, hour: 21, minute: 0, label: "Wednesday 9pm" },

  pickupWindow: "3-6pm",
  unpaidExpiryHours: 24,
};
