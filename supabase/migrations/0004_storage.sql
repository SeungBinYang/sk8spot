-- Phase 5 — 사진 업로드 스토리지
--
-- 버킷을 public으로 연다. 스팟 사진은 애초에 공개 콘텐츠다(공원·거리 사진).
-- `spot_photos.is_hidden`이 목록·상세 노출을 막지만(0001_schema.sql),
-- 파일 자체의 접근을 막지는 않는다 — 신고 처리는 "노출을 끈다"이지
-- "URL을 알아도 못 본다"가 아니다. 완전 삭제가 필요하면 운영자가
-- 대시보드에서 오브젝트를 직접 지운다 (TRUST_AND_MODERATION.md).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'spot-photos', 'spot-photos', true,
  8388608, -- 8MB. 클라이언트에서 이미 리사이즈해서 올리므로 여유
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- 공개 읽기 (버킷이 public이라 사실상 자동이지만 명시해 둔다)
drop policy if exists spot_photos_storage_read on storage.objects;
create policy spot_photos_storage_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'spot-photos');

-- 로그인 사용자만 업로드. 경로는 <spot_id>/<uuid>.jpg를 기대하지만
-- 강제하지는 않는다 — 실제 연결 보장은 spot_photos.spot_id 외래키가 한다.
drop policy if exists spot_photos_storage_insert on storage.objects;
create policy spot_photos_storage_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'spot-photos');

-- update/delete 정책은 일부러 두지 않는다. 클라이언트가 파일을 덮어쓰거나
-- 지울 수 없다 — 삭제·교체는 운영자(대시보드/서비스 롤)만.
