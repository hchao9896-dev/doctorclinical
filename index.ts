// Edge Function: purge-expired-ecg
//
// Việc làm (mỗi lần chạy):
//   1. Xóa ca ECG CHƯA GHIM quá hạn (mặc định 30 ngày; bỏ ghim thì tính lại từ lúc bỏ ghim).
//      Xóa FILE trước bằng Storage API, thành công rồi mới xóa DÒNG. Nếu xóa file lỗi, dòng được giữ
//      lại để lần chạy sau thử lại, không bao giờ để dòng trỏ tới file đã mất mà không ai biết.
//   2. Xóa file MỒ CÔI trong bucket (không còn dòng nào trỏ tới, cũ hơn ORPHAN_MIN_AGE).
//
// Vì sao không dùng SQL thuần: xóa dòng trong storage.objects bằng SQL KHÔNG xóa file thật.
//
// Triển khai:
//   supabase functions deploy purge-expired-ecg --no-verify-jwt
//   supabase secrets set CRON_SECRET=<chuỗi-ngẫu-nhiên-dài>
//   (tùy chọn) supabase secrets set RETENTION_DAYS=30 BATCH_SIZE=200 MAX_ROUNDS=10 ORPHAN_MIN_AGE="1 day"
// Hàm tự xác thực bằng header x-cron-secret (không dùng JWT) nên cần --no-verify-jwt.
// SUPABASE_URL và SUPABASE_SERVICE_ROLE_KEY được Supabase tự cấp cho Edge Function; không đưa vào mã nguồn.
//
// Chạy thử không xóa gì:  POST ...?dry_run=1  (chỉ đếm số ứng viên, tối đa BATCH_SIZE mỗi loại).
// LƯU Ý: nên ghim phiên bản supabase-js cụ thể (thay @2) trước khi triển khai thật.

import { createClient } from "jsr:@supabase/supabase-js@2";

const BUCKET = "ecg-images";

type Admin = ReturnType<typeof createClient>;
type ExpiredRow = { id: string; owner_id: string; image_path: string };
type OrphanRow = { name: string };

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

// So sánh thời gian hằng định để không lộ độ dài/khác biệt của secret.
function safeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

function clampInt(raw: string | undefined | null, def: number, min: number, max: number): number {
  const n = Number.parseInt(raw ?? "", 10);
  if (!Number.isFinite(n)) return def;
  return Math.min(Math.max(n, min), max);
}

async function purgeExpired(
  admin: Admin,
  opts: { days: number; batch: number; maxRounds: number; dryRun: boolean },
) {
  let deleted = 0;
  let failed = 0;

  for (let round = 0; round < opts.maxRounds; round++) {
    const { data, error } = await admin.rpc("ecg_expired_records", {
      _retention_days: opts.days,
      _limit: opts.batch,
    });
    if (error) throw new Error(`ecg_expired_records: ${error.message}`);

    const rows = (data ?? []) as ExpiredRow[];
    if (rows.length === 0) break;
    if (opts.dryRun) return { candidates: rows.length, deleted: 0, failed: 0 };

    const { error: rmErr } = await admin.storage
      .from(BUCKET)
      .remove(rows.map((r) => r.image_path));
    if (rmErr) {
      // Giữ nguyên các dòng để lần sau thử lại.
      failed += rows.length;
      console.error("storage remove failed (expired):", rmErr.message);
      break;
    }

    const { error: delErr } = await admin
      .from("ecg_records")
      .delete()
      .in("id", rows.map((r) => r.id));
    if (delErr) throw new Error(`delete ecg_records: ${delErr.message}`);

    deleted += rows.length;
  }
  return { deleted, failed };
}

async function purgeOrphans(
  admin: Admin,
  opts: { minAge: string; batch: number; maxRounds: number; dryRun: boolean },
) {
  let deleted = 0;
  let failed = 0;

  for (let round = 0; round < opts.maxRounds; round++) {
    const { data, error } = await admin.rpc("ecg_orphan_objects", {
      _older_than: opts.minAge,
      _limit: opts.batch,
    });
    if (error) throw new Error(`ecg_orphan_objects: ${error.message}`);

    const rows = (data ?? []) as OrphanRow[];
    if (rows.length === 0) break;
    if (opts.dryRun) return { candidates: rows.length, deleted: 0, failed: 0 };

    const { error: rmErr } = await admin.storage
      .from(BUCKET)
      .remove(rows.map((r) => r.name));
    if (rmErr) {
      failed += rows.length;
      console.error("storage remove failed (orphans):", rmErr.message);
      break;
    }
    deleted += rows.length;
  }
  return { deleted, failed };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("CRON_SECRET") ?? "";
  const provided = req.headers.get("x-cron-secret") ?? "";
  if (!secret || !safeEqual(provided, secret)) return json({ error: "forbidden" }, 403);

  const dryRun = new URL(req.url).searchParams.get("dry_run") === "1";
  const days = clampInt(Deno.env.get("RETENTION_DAYS"), 30, 1, 3650);
  const batch = clampInt(Deno.env.get("BATCH_SIZE"), 200, 1, 1000);
  const maxRounds = clampInt(Deno.env.get("MAX_ROUNDS"), 10, 1, 100);
  const minAge = Deno.env.get("ORPHAN_MIN_AGE") ?? "1 day";

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return json({ error: "missing_runtime_env" }, 500);

  const admin = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const expired = await purgeExpired(admin, { days, batch, maxRounds, dryRun });
    const orphans = await purgeOrphans(admin, { minAge, batch, maxRounds, dryRun });
    // Chỉ trả số đếm; không ghi đường dẫn/tên bệnh nhân vào log.
    console.log(JSON.stringify({ dryRun, days, expired, orphans }));
    return json({ ok: true, dryRun, retentionDays: days, expired, orphans });
  } catch (e) {
    console.error("purge failed:", e instanceof Error ? e.message : String(e));
    return json({ ok: false, error: "internal_error" }, 500);
  }
});
