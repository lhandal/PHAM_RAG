// supabase/functions/hybrid-search-v2/index.ts
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
Deno.serve(async (req)=>{
  // CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey"
      }
    });
  }
  try {
    // Use SERVICE ROLE — runs with full DB privileges (RLS bypass)
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    // Parse body as-is; expected to include query_text, match_count, filter, lang, etc.
    const body = await req.json();
    const { data, error } = await supabase.rpc("hybrid_search_v2_with_details", body);
    if (error) throw error;
    return new Response(JSON.stringify(data), {
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*"
      },
      status: 200
    });
  } catch (err) {
    console.error('EDGE ERROR:', err); // will show in Supabase logs
    return new Response(JSON.stringify({
      error: String(err?.message || err),
      stack: err?.stack ?? null
    }), {
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*"
      },
      status: 400
    });
  }
});
