# Clinical Desk v2: bản vá Supabase (schema, test RLS, dọn dẹp tự động)

## Gồm những gì

| Tệp | Vai trò |
|---|---|
| `supabase-schema.sql` | Schema v2 đầy đủ, idempotent. Thay thế bản cũ. |
| `supabase/tests/database/01_rls.test.sql` | Bộ test pgTAP (116 phép kiểm tra) cho RLS, Storage, trigger, hạn mức, audit. |
| `supabase/functions/purge-expired-ecg/index.ts` | Edge Function xóa ca hết hạn và file mồ côi qua Storage API. |

## Áp dụng

1. **Sao lưu** database.
2. Chạy `supabase-schema.sql` trong SQL Editor (project owner), hoặc chép vào `supabase/migrations/<timestamp>_clinical_desk_v2.sql`.
3. **Duyệt tài khoản.** Tài khoản mới đăng ký sẽ không truy cập được gì cho tới khi bạn duyệt:
   ```sql
   select public.approve_user('<AUTH_UID>');
   select public.admin_create_team('Khoa Cấp cứu', '<ADMIN_UID>');
   select public.admin_set_team_member('<TEAM_UUID>', '<UID>', 'member');
   ```
   Lần chạy đầu trên DB đã có dữ liệu, script tự duyệt những người đang là chủ ca, thành viên hoặc người tạo nhóm để hệ thống đang dùng không bị gián đoạn. Hãy kiểm tra danh sách `select * from public.approved_users;`.
4. Triển khai Edge Function (xem đầu `index.ts`), chạy thử bằng `?dry_run=1`, rồi bật lịch ở phần 12 cuối file SQL.

## Chạy test

```bash
supabase start
supabase test db
```

Test chạy trong một transaction và `ROLLBACK`, không để lại dữ liệu. Nó giả lập 5 người dùng (admin nhóm, thành viên, người không nhóm, admin nhóm khác, tài khoản chưa duyệt) và kiểm tra cả chiều từ chối lẫn chiều cho phép.

## Đã vá những gì

| # | Vấn đề ở bản cũ | Cách xử lý |
|---|---|---|
| 1 | Không có job xóa 30 ngày phía server | `ecg_expired_records()` + Edge Function xóa file trước, dòng sau; bỏ ghim thì tính lại 30 ngày |
| 2 | Đăng ký mở, không giới hạn | Bảng `approved_users` (mọi policy yêu cầu đã duyệt), hạn mức 300 ca/người |
| 5 | Chủ ảnh mất quyền đọc ảnh nhóm khi rời nhóm | Chủ ảnh luôn đọc/xóa được ảnh của mình |
| 6 | `team_id ... on delete set null` làm ca mồ côi | `ON DELETE RESTRICT` |
| 7 | Thiếu policy UPDATE trên `storage.objects` | Đã thêm (cần cho upsert) |
| 8 | File mồ côi khi xóa dòng xong xóa file lỗi | `ecg_orphan_objects()` + Edge Function |
| 9 | `profiles.team_id` lệch `team_members` | Trigger đồng bộ |
| 10 | `created_at` mất DEFAULT sau migration | Bỏ default trước khi đổi kiểu, đặt lại `now()` + `NOT NULL` |
| thêm | `revoke from public` không gỡ quyền của `anon` | Revoke rõ ràng; `anon` không còn quyền gì trên bảng |
| thêm | `teams_insert_creator` vô dụng | Bỏ; tạo nhóm bằng `admin_create_team()` |
| thêm | Đường dẫn ảnh kiểm tra lỏng (`like`) | Regex chặt: đúng độ sâu, chỉ `jpg/jpeg/png/webp` |
| thêm | Không có audit | `audit_log` (ai tạo/sửa/xóa ca nào; không lưu tên bệnh nhân/chẩn đoán) |
| thêm | Policy cũ có thể còn sót và cộng dồn bằng OR | `drop policy` mọi tên cũ; test 0.6 khẳng định đúng tập policy |

## Việc phía ứng dụng (JS) cần chỉnh

Tôi chưa xem `app.js` / `supabase-service.js`, nên đây là các điểm cần đối chiếu, không phải khẳng định về mã hiện có:

1. **Trạng thái "chờ duyệt":** sau đăng nhập gọi `supabase.rpc('is_approved')`. Nếu `false`, hiện thông báo chờ duyệt và ẩn chức năng; nếu không, người dùng chỉ thấy dữ liệu rỗng và lỗi RLS khó hiểu.
2. **Lỗi hạn mức:** insert quá hạn mức trả lỗi mã `54000`; hiện thông báo thân thiện.
3. **Không gửi** `updated_at`, `unpinned_at` (server quản lý, giá trị gửi lên bị ghi đè). `created_at` tương lai bị kéo về hiện tại.
4. **Tên tệp ảnh** phải khớp `[A-Za-z0-9_-]{1,80}.(jpg|jpeg|png|webp)` (viết thường), đúng 3 đoạn cho ảnh cá nhân và 4 đoạn cho ảnh nhóm. Nếu app đang đặt tên khác (ví dụ ID cũ từ localStorage chứa ký tự lạ) thì upload sẽ bị từ chối.
5. **Không tạo nhóm từ client** (policy INSERT trên `teams` đã bỏ).
6. **Signed URL:** giảm từ 60 phút xuống 5–15 phút.
7. **Đăng xuất:** xóa cache ECG và nháp giao ban trong localStorage; xóa cả ca không còn được RLS trả về.
8. **Ẩn danh hóa ảnh:** thêm bước che/cắt phần đầu bản in ECG (thường có tên, mã bệnh nhân) và cảnh báo trước khi tải lên. SQL không làm thay được việc này.
9. **Nhập ảnh local cũ:** hiện hộp thoại xác nhận (kèm số ảnh) trước khi gán quyền sở hữu, thay vì tự gán cho tài khoản đăng nhập đầu tiên.

## Giới hạn đã biết

- **Chưa chạy thử trên Postgres/Supabase thật.** Môi trường tôi dùng không có PostgreSQL, nên SQL và test mới được rà soát bằng mắt và kiểm tra tĩnh (cân bằng dấu, tên hàm trợ giúp). Hãy chạy trên project/DB thử trước, nhất là `supabase test db`.
- Test tạo dòng trực tiếp trong `auth.users` và `storage.objects`; nếu phiên bản Supabase của bạn có cột bắt buộc khác, chỉnh phần "Dữ liệu mẫu". Test có bật cờ `storage.allow_delete_query` vì một số phiên bản Storage chặn `DELETE` trực tiếp trên `storage.objects`.
- Hạn mức đếm theo số ca, không theo dung lượng. Ảnh upload mà không tạo ca sẽ bị dọn như file mồ côi sau 1 ngày.
- Chưa có xóa mềm/thùng rác; xóa là xóa hẳn. Nếu cần hoàn tác, thêm cột `deleted_at` và để job xóa thật sau vài ngày.
- Không ghi log lượt xem ảnh (trigger không bắt được SELECT/signed URL). Dùng log Storage/API của Supabase nếu cần.
- Giữ ca của người đã rời nhóm: chủ ca chỉ còn xóa được ca nhóm cũ (không sửa/ghim), vì việc chuyển ca sang cá nhân đòi hỏi di chuyển file ảnh.
- Tuân thủ pháp lý (Nghị định 13/2023, vùng đặt dữ liệu, đồng ý của người bệnh) cần được pháp chế/CNTT bệnh viện xác nhận.
