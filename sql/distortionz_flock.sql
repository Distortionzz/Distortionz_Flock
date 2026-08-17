-- =====================================================================
--  Distortionz Flock — schema. Run once.
-- =====================================================================

-- Every plate sighting. High insert volume, so writes are batched by the
-- resource and old rows are pruned on Config.Database.retentionDays.
CREATE TABLE IF NOT EXISTS `distortionz_flock_reads` (
    `id`           INT(11) NOT NULL AUTO_INCREMENT,
    `camera_id`    VARCHAR(64) NOT NULL,
    `camera_label` VARCHAR(120) DEFAULT NULL,
    `plate`        VARCHAR(12) NOT NULL,
    `citizenid`    VARCHAR(50) DEFAULT NULL,
    `created_at`   TIMESTAMP NOT NULL DEFAULT current_timestamp(),
    PRIMARY KEY (`id`),
    -- Plate search is always "this plate, newest first", so the composite
    -- index serves both the filter and the sort from one read.
    KEY `plate_time` (`plate`, `created_at`),
    KEY `created_at` (`created_at`),
    KEY `citizenid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Flagged plates. `plate` is UNIQUE so re-flagging updates in place.
CREATE TABLE IF NOT EXISTS `distortionz_flock_hotlist` (
    `id`         INT(11) NOT NULL AUTO_INCREMENT,
    `plate`      VARCHAR(12) NOT NULL,
    `reason`     VARCHAR(200) DEFAULT NULL,
    `added_by`   VARCHAR(120) DEFAULT NULL,
    `active`     TINYINT(1) NOT NULL DEFAULT 1,
    `created_at` TIMESTAMP NOT NULL DEFAULT current_timestamp(),
    PRIMARY KEY (`id`),
    UNIQUE KEY `plate` (`plate`),
    KEY `active` (`active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Who looked up what. Real ALPR systems are audited precisely because the
-- abuse risk is an officer tracking someone privately — same here.
CREATE TABLE IF NOT EXISTS `distortionz_flock_audit` (
    `id`           INT(11) NOT NULL AUTO_INCREMENT,
    `officer_cid`  VARCHAR(50) DEFAULT NULL,
    `officer_name` VARCHAR(120) DEFAULT NULL,
    `action`       VARCHAR(32) NOT NULL,
    `detail`       VARCHAR(255) DEFAULT NULL,
    `created_at`   TIMESTAMP NOT NULL DEFAULT current_timestamp(),
    PRIMARY KEY (`id`),
    KEY `officer_cid` (`officer_cid`),
    KEY `created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
