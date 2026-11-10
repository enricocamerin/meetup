// Sends the organizer an email when the admin approves or rejects their event.
// Called by the portal right after the decision: POST { event_id }.
// Secrets (Supabase → Edge Functions → Secrets): SMTP_USER, SMTP_PASS;
// optional SMTP_HOST (default smtp.gmail.com), SMTP_PORT (465), APP_URL.
// verify_jwt is off: the function checks the caller itself (signed-in admin).
import nodemailer from "npm:nodemailer@6.9.16";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const day = (d: string) =>
  new Date(d + "T12:00:00Z").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // Who is calling? Must be a signed-in admin of the portal.
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await admin.auth.getUser(jwt);
  const caller = (u?.user?.email || "").toLowerCase();
  if (!caller) return json({ error: "Not signed in" }, 401);
  const { data: me } = await admin.from("organizers").select("role").eq("email", caller).maybeSingle();
  if (me?.role !== "admin") return json({ error: "Only an administrator can send this" }, 403);

  let body: { event_id?: string } = {};
  try { body = await req.json(); } catch { /* empty */ }
  if (!body.event_id) return json({ error: "event_id missing" }, 400);

  const { data: ev } = await admin.from("events").select("*").eq("id", body.event_id).maybeSingle();
  if (!ev) return json({ error: "Event not found" }, 404);
  if (ev.status !== "approved" && ev.status !== "rejected") return json({ skipped: "event is pending" });

  const { data: org } = await admin.from("organizers").select("name").eq("email", ev.organizer_email).maybeSingle();
  const user = Deno.env.get("SMTP_USER"), pass = Deno.env.get("SMTP_PASS");
  if (!user || !pass) return json({ error: "SMTP_USER / SMTP_PASS secrets are not set" }, 500);
  const port = Number(Deno.env.get("SMTP_PORT") || 465);
  const transport = nodemailer.createTransport({
    host: Deno.env.get("SMTP_HOST") || "smtp.gmail.com", port, secure: port === 465, auth: { user, pass },
  });

  const ok = ev.status === "approved";
  const when = ev.starts_on === ev.ends_on ? day(ev.starts_on) : `${day(ev.starts_on)} → ${day(ev.ends_on)}`;
  const app = Deno.env.get("APP_URL") || "https://meetup-hiking.netlify.app";
  const subject = `${ok ? "Approved" : "Not approved"}: ${ev.title} (${when})`;
  const hello = org?.name ? `Hi ${org.name},` : "Hi,";
  const text = [
    hello, "",
    ok ? `your event "${ev.title}" has been approved.` : `your event "${ev.title}" has not been approved.`,
    `Date: ${when}`,
    ev.meeting_point ? `Meeting point: ${ev.meeting_point}` : "",
    ev.admin_note ? `Note from the administrator: ${ev.admin_note}` : "",
    "", `Open the calendar: ${app}`,
  ].filter((l, i, a) => l !== "" || a[i - 1] !== "").join("\n");
  const html = `<div style="font-family:Arial,sans-serif;font-size:15px;color:#1C2B21;max-width:520px">
    <p>${esc(hello)}</p>
    <p>your event <b>${esc(ev.title)}</b> ${ok ? "has been <b style=\"color:#2E7D4F\">approved</b>" : "has <b style=\"color:#B23A3A\">not been approved</b>"}.</p>
    <p>Date: ${esc(when)}${ev.meeting_point ? `<br>Meeting point: ${esc(ev.meeting_point)}` : ""}</p>
    ${ev.admin_note ? `<p>Note from the administrator:<br><i>${esc(ev.admin_note)}</i></p>` : ""}
    <p><a href="${esc(app)}" style="color:#2F6B45;font-weight:bold">Open the calendar</a></p></div>`;

  try {
    await transport.sendMail({
      from: { name: "Meetup Hiking", address: user }, to: ev.organizer_email, replyTo: caller, subject, text, html,
    });
  } catch (e) {
    return json({ error: "Email not sent: " + (e as Error).message }, 502);
  }
  return json({ sent: ev.organizer_email });
});
