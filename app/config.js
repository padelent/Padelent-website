// Padelent app settings. The publishable key is safe to be public.
// Never put the Supabase secret / service_role key or a Stripe secret key in this file.
window.PADELENT_CONFIG = {
  supabaseUrl: "https://bjqffcfbnfyoumklewbd.supabase.co",
  supabaseKey: "sb_publishable_6DL2EwfA35xaWfD88PU5Lw_75_2zI72",
  // false while testing: lessons are free. Turned on when Stripe is connected.
  paymentsEnabled: false,
  platformFeePercent: 20,
  maxVideoMB: 50,
  contactEmail: "info@padelent.com"
};
