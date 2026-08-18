import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Fill these in from Supabase dashboard > Project Settings > API.
// The anon key is safe to expose client-side — RLS is what protects data.
const SUPABASE_URL = 'https://dspmysobgqyzkkwdcqit.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRzcG15c29iZ3F5emtrd2RjcWl0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYyMDkyNTYsImV4cCI6MjEwMTc4NTI1Nn0.hR2VxPO54n7Ew1QcX7-IvfRA7bBLVHUiN16CxmgqV34';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

export async function requireSession() {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) {
    window.location.href = 'index.html';
    return null;
  }
  return session;
}

