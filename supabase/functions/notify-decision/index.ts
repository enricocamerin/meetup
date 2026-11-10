// Emails about event requests, called by the portal:
//   POST { event_id }              after the admin approves / rejects → email to the requester
//   POST { event_id, kind: "new" } after someone requests an event → email to the administrators
// Secrets (Supabase → Edge Functions → Secrets): SMTP_USER, SMTP_PASS;
// optional SMTP_HOST (default smtp.gmail.com), SMTP_PORT (465), APP_URL.
// verify_jwt is off: the function checks the signed-in caller itself.
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

  // Who is calling? Must be a signed-in user of the portal.
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await admin.auth.getUser(jwt);
  const caller = (u?.user?.email || "").toLowerCase();
  if (!caller) return json({ error: "Not signed in" }, 401);
  const { data: me } = await admin.from("organizers").select("role").eq("email", caller).maybeSingle();

  let body: { event_id?: string; kind?: string } = {};
  try { body = await req.json(); } catch { /* empty */ }
  if (!body.event_id) return json({ error: "event_id missing" }, 400);

  const { data: ev } = await admin.from("events").select("*").eq("id", body.event_id).maybeSingle();
  if (!ev) return json({ error: "Event not found" }, 404);

  const user = Deno.env.get("SMTP_USER"), pass = Deno.env.get("SMTP_PASS");
  if (!user || !pass) return json({ error: "SMTP_USER / SMTP_PASS secrets are not set" }, 500);
  const port = Number(Deno.env.get("SMTP_PORT") || 465);
  const transport = nodemailer.createTransport({
    host: Deno.env.get("SMTP_HOST") || "smtp.gmail.com", port, secure: port === 465, auth: { user, pass },
  });
  const app = Deno.env.get("APP_URL") || "https://enricocamerin.github.io/meetup/";
  const span = ev.starts_on === ev.ends_on ? day(ev.starts_on) : `${day(ev.starts_on)} → ${day(ev.ends_on)}`;

  // A new request: tell the administrators (only the requester can trigger it, while pending).
  if (body.kind === "new") {
    if (ev.organizer_email !== caller || ev.status !== "pending") return json({ error: "Not allowed" }, 403);
    if (Date.now() - new Date(ev.created_at).getTime() > 10 * 60 * 1000) return json({ skipped: "too old" });
    const { data: admins } = await admin.from("organizers").select("email").eq("role", "admin");
    const to = (admins || []).map((a) => a.email).filter((e) => e !== caller);
    if (!to.length) return json({ skipped: "no other admin" });
    const who = ev.organizer_name || caller;
    try {
      await transport.sendMail({
        from: { name: "Meetup Hiking", address: user }, to, replyTo: caller,
        subject: `New request: ${ev.title} (${span})`,
        text: `${who} <${caller}> requested "${ev.title}" on ${span}.\n${ev.meeting_point ? "Meeting point: " + ev.meeting_point + "\n" : ""}${ev.description ? "\n" + ev.description + "\n" : ""}\nApprove or reject it: ${app}`,
        html: `<div style="font-family:Arial,sans-serif;font-size:15px;color:#1C2B21;max-width:520px">
          <p><b>${esc(who)}</b> (${esc(caller)}) requested <b>${esc(ev.title)}</b> on ${esc(span)}.</p>
          ${ev.meeting_point ? `<p>Meeting point: ${esc(ev.meeting_point)}</p>` : ""}
          ${ev.description ? `<p style="white-space:pre-line">${esc(ev.description)}</p>` : ""}
          <p><a href="${esc(app)}" style="color:#2F6B45;font-weight:bold">Approve or reject it</a></p></div>`,
      });
    } catch (e) { return json({ error: "Email not sent: " + (e as Error).message }, 502); }
    return json({ sent: to.length });
  }

  // A decision: only an administrator, and only once the event is approved or rejected.
  if (me?.role !== "admin") return json({ error: "Only an administrator can send this" }, 403);
  if (ev.status !== "approved" && ev.status !== "rejected") return json({ skipped: "event is pending" });
  const { data: org } = await admin.from("organizers").select("name").eq("email", ev.organizer_email).maybeSingle();

  const ok = ev.status === "approved";
  const when = span;
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
