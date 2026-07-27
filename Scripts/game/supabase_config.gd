class_name SupabaseConfig

# Replace with your project's values from the Supabase dashboard (Settings → API).
# The anon key is safe to commit — RLS scopes it per table: career_stats is
# INSERT + SELECT (no UPDATE/DELETE); bug_reports and network_sessions are
# INSERT-only. Server-side CHECK constraints bound row size/ranges (see
# supabase/migrations/).
const URL: String = "https://bxzaqnkeneelwdjqxflt.supabase.co"
const ANON_KEY: String = "sb_publishable_-4Lq3iRG9rUaD9OKaxdLWg_kLmpirPr"
