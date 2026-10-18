import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const auth = req.headers.get("Authorization") || "";
  if (!url || !anon || !serviceKey) return json({ error: "Supabase server configuration is incomplete" }, 500);
  if (!auth.startsWith("Bearer ")) return json({ error: "请先登录管理员账号" }, 401);
  try {
    const caller = createClient(url, anon, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const { data: userData, error: userError } = await caller.auth.getUser();
    if (userError || !userData.user) return json({ error: "登录已失效，请重新登录" }, 401);
    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
    const { data: role, error: roleError } = await admin.from("admin_roles").select("user_id").eq("user_id", userData.user.id).maybeSingle();
    if (roleError || !role) return json({ error: "没有管理员权限" }, 403);
    let input: { username?: unknown; new_password?: unknown };
    try { input = await req.json(); } catch { return json({ error: "请求格式不正确" }, 400); }
    const username = typeof input.username === "string" ? input.username.trim().normalize("NFC").toLowerCase() : "";
    const password = typeof input.new_password === "string" ? input.new_password : "";
    if (!username || Array.from(username).length > 32 || /[\u0000-\u001F\u007F]/u.test(username)) return json({ error: "用户名格式不正确" }, 400);
    if (password.length < 8 || password.length > 72) return json({ error: "新密码必须为 8–72 个字符" }, 400);
    const { data: profile, error: profileError } = await admin.from("profiles").select("user_id").eq("username", username).maybeSingle();
    if (profileError) return json({ error: "查询用户失败" }, 500);
    if (!profile) return json({ error: "未找到该用户名" }, 404);
    const { error: updateError } = await admin.auth.admin.updateUserById(profile.user_id, { password });
    if (updateError) return json({ error: "Supabase 未能更新密码" }, 500);
    return json({ ok: true });
  } catch {
    return json({ error: "服务器处理失败，请稍后重试" }, 500);
  }
});