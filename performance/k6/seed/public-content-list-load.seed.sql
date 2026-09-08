SET @perf_region_id = 990001;
SET @perf_user_id = 990001;
SET @perf_image_id_base = 991000;
SET @perf_content_id_base = 992000;
SET @perf_session_id_base = 993000;
SET @perf_now = UTC_TIMESTAMP(6);
SET @perf_password_hash = '{bcrypt}$2a$12$/SenwR03QWMkim.0.mDq7uE3vB75E5egW2.A5FQPVmlBU9VEUlmm2';

-- 이 파일은 성능 전용 DB에서 반복 실행할 수 있도록 예약 ID 범위만 초기화한다.
DELETE FROM content_session
WHERE session_id BETWEEN @perf_session_id_base AND @perf_session_id_base + 599;

DELETE FROM content
WHERE content_id BETWEEN @perf_content_id_base AND @perf_content_id_base + 199;

DELETE FROM image_object
WHERE image_object_id BETWEEN @perf_image_id_base AND @perf_image_id_base + 199;

DELETE FROM user_role_assignment
WHERE user_id = @perf_user_id;

DELETE FROM app_user
WHERE user_id = @perf_user_id;

DELETE FROM region
WHERE region_id = @perf_region_id;

INSERT INTO region (
    region_id,
    region_code,
    name,
    is_public,
    created_at,
    updated_at
) VALUES (
    @perf_region_id,
    'PUBLIC-CONTENT-LOAD',
    'Public Content Load Region',
    TRUE,
    @perf_now,
    @perf_now
);

INSERT INTO app_user (
    user_id,
    login_identifier,
    password_hash,
    name,
    phone,
    status,
    account_kind,
    created_at,
    updated_at
) VALUES (
    @perf_user_id,
    'public-content-load@example.com',
    @perf_password_hash,
    'Public Content Load Operator',
    '01099000001',
    'ACTIVE',
    'ORDINARY',
    @perf_now,
    @perf_now
);

INSERT INTO user_role_assignment (
    user_id,
    role,
    region_id,
    status,
    granted_at
) VALUES (
    @perf_user_id,
    'OPERATOR',
    @perf_region_id,
    'ACTIVE',
    @perf_now
);

DROP TEMPORARY TABLE IF EXISTS public_content_load_sequence;
CREATE TEMPORARY TABLE public_content_load_sequence (
    sequence_no INT NOT NULL,
    CONSTRAINT pk_public_content_load_sequence PRIMARY KEY (sequence_no)
);

INSERT INTO public_content_load_sequence (sequence_no)
WITH RECURSIVE sequence_values (sequence_no) AS (
    SELECT 0
    UNION ALL
    SELECT sequence_no + 1
    FROM sequence_values
    WHERE sequence_no < 199
)
SELECT sequence_no
FROM sequence_values;

INSERT INTO image_object (
    image_object_id,
    object_key,
    media_type,
    byte_size,
    checksum,
    lifecycle_status,
    delete_attempt_count,
    last_delete_attempted_at,
    created_at,
    created_by_user_id,
    region_id,
    upload_expires_at,
    linked_at
)
SELECT
    @perf_image_id_base + sequence_no,
    CONCAT('performance/public-content-list/', LPAD(sequence_no, 3, '0'), '.jpg'),
    'image/jpeg',
    65536 + sequence_no,
    CONCAT('public-content-list-load-', LPAD(sequence_no, 3, '0')),
    'ACTIVE',
    0,
    NULL,
    @perf_now,
    @perf_user_id,
    @perf_region_id,
    @perf_now + INTERVAL 1 DAY,
    @perf_now
FROM public_content_load_sequence;

INSERT INTO content (
    content_id,
    region_id,
    operator_id,
    content_type,
    status,
    version_no,
    title,
    description,
    location_text,
    operating_hours_text,
    contact_text,
    precautions,
    age_requirement,
    materials,
    cancellation_policy_text,
    publish_at,
    deleted_at,
    created_at,
    updated_at,
    representative_image_object_id,
    representative_image_assigned_at,
    reservation_price
)
SELECT
    @perf_content_id_base + sequence_no,
    @perf_region_id,
    @perf_user_id,
    'EVENT_EXPERIENCE',
    'PUBLISHED',
    1,
    CONCAT('Public Content Load ', LPAD(sequence_no, 3, '0')),
    CONCAT('Independent public content list load fixture ', LPAD(sequence_no, 3, '0')),
    CONCAT('Load Test Venue ', LPAD(sequence_no, 3, '0')),
    '09:00-18:00',
    '010-9900-0001',
    'Follow staff instructions.',
    'All ages',
    'No materials required.',
    'Free cancellation before session start.',
    @perf_now - INTERVAL sequence_no SECOND,
    NULL,
    @perf_now,
    @perf_now,
    @perf_image_id_base + sequence_no,
    @perf_now,
    10000
FROM public_content_load_sequence;

-- 각 콘텐츠는 완료·예약 예정·취소 회차를 하나씩 갖는다.
INSERT INTO content_session (
    session_id,
    content_id,
    region_id,
    status,
    starts_at,
    ends_at,
    checkin_open_at,
    checkin_close_at,
    capacity,
    remaining_capacity,
    cancelled_at,
    cancelled_by_user_id,
    cancellation_reason,
    completed_at,
    version_no,
    created_at,
    updated_at,
    reviewed_at,
    reviewed_by_user_id,
    reject_reason
)
SELECT
    @perf_session_id_base + sequence_no * 3,
    @perf_content_id_base + sequence_no,
    @perf_region_id,
    'COMPLETED',
    @perf_now - INTERVAL 30 DAY + INTERVAL sequence_no MINUTE,
    @perf_now - INTERVAL 30 DAY + INTERVAL sequence_no MINUTE + INTERVAL 2 HOUR,
    @perf_now - INTERVAL 30 DAY + INTERVAL sequence_no MINUTE - INTERVAL 30 MINUTE,
    @perf_now - INTERVAL 30 DAY + INTERVAL sequence_no MINUTE + INTERVAL 90 MINUTE,
    10,
    0,
    NULL,
    NULL,
    NULL,
    @perf_now - INTERVAL 29 DAY,
    1,
    @perf_now,
    @perf_now,
    @perf_now - INTERVAL 31 DAY,
    @perf_user_id,
    NULL
FROM public_content_load_sequence;

INSERT INTO content_session (
    session_id,
    content_id,
    region_id,
    status,
    starts_at,
    ends_at,
    checkin_open_at,
    checkin_close_at,
    capacity,
    remaining_capacity,
    cancelled_at,
    cancelled_by_user_id,
    cancellation_reason,
    completed_at,
    version_no,
    created_at,
    updated_at,
    reviewed_at,
    reviewed_by_user_id,
    reject_reason
)
SELECT
    @perf_session_id_base + sequence_no * 3 + 1,
    @perf_content_id_base + sequence_no,
    @perf_region_id,
    'SCHEDULED',
    @perf_now + INTERVAL 7 DAY + INTERVAL sequence_no MINUTE,
    @perf_now + INTERVAL 7 DAY + INTERVAL sequence_no MINUTE + INTERVAL 2 HOUR,
    @perf_now + INTERVAL 7 DAY + INTERVAL sequence_no MINUTE - INTERVAL 30 MINUTE,
    @perf_now + INTERVAL 7 DAY + INTERVAL sequence_no MINUTE + INTERVAL 90 MINUTE,
    10,
    CASE WHEN sequence_no < 100 THEN 5 ELSE 0 END,
    NULL,
    NULL,
    NULL,
    NULL,
    1,
    @perf_now,
    @perf_now,
    @perf_now,
    @perf_user_id,
    NULL
FROM public_content_load_sequence;

INSERT INTO content_session (
    session_id,
    content_id,
    region_id,
    status,
    starts_at,
    ends_at,
    checkin_open_at,
    checkin_close_at,
    capacity,
    remaining_capacity,
    cancelled_at,
    cancelled_by_user_id,
    cancellation_reason,
    completed_at,
    version_no,
    created_at,
    updated_at,
    reviewed_at,
    reviewed_by_user_id,
    reject_reason
)
SELECT
    @perf_session_id_base + sequence_no * 3 + 2,
    @perf_content_id_base + sequence_no,
    @perf_region_id,
    'CANCELLED',
    @perf_now + INTERVAL 14 DAY + INTERVAL sequence_no MINUTE,
    @perf_now + INTERVAL 14 DAY + INTERVAL sequence_no MINUTE + INTERVAL 2 HOUR,
    @perf_now + INTERVAL 14 DAY + INTERVAL sequence_no MINUTE - INTERVAL 30 MINUTE,
    @perf_now + INTERVAL 14 DAY + INTERVAL sequence_no MINUTE + INTERVAL 90 MINUTE,
    10,
    10,
    @perf_now,
    @perf_user_id,
    'Performance fixture cancellation.',
    NULL,
    1,
    @perf_now,
    @perf_now,
    @perf_now,
    @perf_user_id,
    NULL
FROM public_content_load_sequence;

DROP TEMPORARY TABLE public_content_load_sequence;

SELECT 'public_regions' AS fixture, COUNT(*) AS actual_count, 1 AS expected_count
FROM region
WHERE region_id = @perf_region_id AND is_public = TRUE
UNION ALL
SELECT 'contents', COUNT(*), 200
FROM content
WHERE content_id BETWEEN @perf_content_id_base AND @perf_content_id_base + 199
UNION ALL
SELECT 'images', COUNT(*), 200
FROM image_object
WHERE image_object_id BETWEEN @perf_image_id_base AND @perf_image_id_base + 199
UNION ALL
SELECT 'sessions', COUNT(*), 600
FROM content_session
WHERE session_id BETWEEN @perf_session_id_base AND @perf_session_id_base + 599
UNION ALL
SELECT 'reservation_available_true', COUNT(DISTINCT content.content_id), 100
FROM content
JOIN content_session ON content_session.content_id = content.content_id
WHERE content.content_id BETWEEN @perf_content_id_base AND @perf_content_id_base + 199
    AND content_session.status = 'SCHEDULED'
    AND content_session.starts_at > UTC_TIMESTAMP(6)
    AND content_session.remaining_capacity > 0
UNION ALL
SELECT 'reservation_available_false', COUNT(*), 100
FROM content
WHERE content.content_id BETWEEN @perf_content_id_base AND @perf_content_id_base + 199
    AND NOT EXISTS (
        SELECT 1
        FROM content_session
        WHERE content_session.content_id = content.content_id
            AND content_session.status = 'SCHEDULED'
            AND content_session.starts_at > UTC_TIMESTAMP(6)
            AND content_session.remaining_capacity > 0
    );
