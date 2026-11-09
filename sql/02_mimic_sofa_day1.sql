-- mCCI-S | 02 | MIMIC-IV v3.1: first-day SOFA computed from raw tables (no derived dataset needed)
-- Creates YOUR_GCP_PROJECT.mccis.mimic_scores. Follows MIMIC Code Repository first_day_sofa logic:
-- laboratory window -6 h to +24 h, bedside data 0 to +24 h from ICU admission; missing = normal (0 points);
-- urine output criterion applied only with >= 20 h of observation. Requires script 01.

CREATE OR REPLACE TABLE `YOUR_GCP_PROJECT.mccis.mimic_scores` AS
WITH
co AS (
  SELECT stay_id, subject_id, intime, outtime,
    DATETIME_SUB(intime, INTERVAL 6 HOUR) AS w0,
    DATETIME_ADD(intime, INTERVAL 24 HOUR) AS w1
  FROM `YOUR_GCP_PROJECT.mccis.mimic_stays`
  WHERE in_cohort = 1
),
lab AS (
  SELECT co.stay_id,
    MIN(IF(le.itemid = 51265, le.valuenum, NULL)) AS plt_min,
    MAX(IF(le.itemid = 50885, le.valuenum, NULL)) AS bili_max,
    MAX(IF(le.itemid = 50912, le.valuenum, NULL)) AS cr_max
  FROM co
  JOIN `physionet-data.mimiciv_3_1_hosp.labevents` AS le
    ON le.subject_id = co.subject_id AND le.charttime BETWEEN co.w0 AND co.w1
  WHERE le.itemid IN (51265, 50885, 50912) AND le.valuenum > 0
  GROUP BY co.stay_id
),
art AS (
  SELECT DISTINCT specimen_id
  FROM `physionet-data.mimiciv_3_1_hosp.labevents`
  WHERE itemid = 52033 AND value = 'ART.'
),
bg AS (
  SELECT co.stay_id, le.charttime, le.specimen_id, le.valuenum AS pao2
  FROM co
  JOIN `physionet-data.mimiciv_3_1_hosp.labevents` AS le
    ON le.subject_id = co.subject_id AND le.charttime BETWEEN co.w0 AND co.w1
  JOIN art ON art.specimen_id = le.specimen_id
  WHERE le.itemid = 50821 AND le.valuenum > 0 AND le.valuenum < 800
),
bg_fio2 AS (
  SELECT le.specimen_id, MAX(le.valuenum) AS fio2_lab
  FROM `physionet-data.mimiciv_3_1_hosp.labevents` AS le
  JOIN (SELECT DISTINCT specimen_id FROM bg) AS s ON s.specimen_id = le.specimen_id
  WHERE le.itemid = 50816 AND le.valuenum BETWEEN 21 AND 100
  GROUP BY le.specimen_id
),
ch_fio2 AS (
  SELECT stay_id, charttime, fio2 FROM (
    SELECT co.stay_id, ce.charttime,
      IF(ce.valuenum <= 1, ce.valuenum * 100, ce.valuenum) AS fio2
    FROM co
    JOIN `physionet-data.mimiciv_3_1_icu.chartevents` AS ce
      ON ce.stay_id = co.stay_id AND ce.charttime BETWEEN DATETIME_SUB(co.w0, INTERVAL 4 HOUR) AND co.w1
    WHERE ce.itemid = 223835 AND ce.valuenum > 0
  )
  WHERE fio2 BETWEEN 21 AND 100
),
bg2 AS (
  SELECT stay_id, charttime, pao2, fio2 FROM (
    SELECT b.stay_id, b.charttime, b.pao2,
      COALESCE(f.fio2_lab, c.fio2) AS fio2,
      ROW_NUMBER() OVER (PARTITION BY b.stay_id, b.specimen_id ORDER BY c.charttime DESC) AS rn
    FROM bg AS b
    LEFT JOIN bg_fio2 AS f ON f.specimen_id = b.specimen_id
    LEFT JOIN ch_fio2 AS c
      ON c.stay_id = b.stay_id
     AND c.charttime BETWEEN DATETIME_SUB(b.charttime, INTERVAL 4 HOUR) AND b.charttime
  )
  WHERE rn = 1
),
vent AS (
  SELECT co.stay_id, pe.starttime, pe.endtime
  FROM co
  JOIN `physionet-data.mimiciv_3_1_icu.procedureevents` AS pe ON pe.stay_id = co.stay_id
  WHERE pe.itemid = 225792 AND pe.starttime < co.w1 AND pe.endtime > co.intime
),
pf AS (
  SELECT b.stay_id,
    MIN(100 * b.pao2 / b.fio2) AS pf_min,
    MIN(IF(v.stay_id IS NOT NULL, 100 * b.pao2 / b.fio2, NULL)) AS pf_min_vent
  FROM bg2 AS b
  LEFT JOIN vent AS v
    ON v.stay_id = b.stay_id AND b.charttime BETWEEN v.starttime AND v.endtime
  WHERE b.fio2 IS NOT NULL
  GROUP BY b.stay_id
),
vit AS (
  SELECT co.stay_id, MIN(ce.valuenum) AS map_min
  FROM co
  JOIN `physionet-data.mimiciv_3_1_icu.chartevents` AS ce
    ON ce.stay_id = co.stay_id AND ce.charttime BETWEEN co.intime AND co.w1
  WHERE ce.itemid IN (220052, 220181, 225312) AND ce.valuenum BETWEEN 20 AND 200
  GROUP BY co.stay_id
),
gcs_raw AS (
  SELECT co.stay_id, ce.charttime,
    MAX(IF(ce.itemid = 220739, ce.valuenum, NULL)) AS e,
    MAX(IF(ce.itemid = 223900, ce.valuenum, NULL)) AS v,
    MAX(IF(ce.itemid = 223900 AND ce.value = 'No Response-ETT', 1, 0)) AS ett,
    MAX(IF(ce.itemid = 223901, ce.valuenum, NULL)) AS m
  FROM co
  JOIN `physionet-data.mimiciv_3_1_icu.chartevents` AS ce
    ON ce.stay_id = co.stay_id AND ce.charttime BETWEEN co.intime AND co.w1
  WHERE ce.itemid IN (220739, 223900, 223901)
  GROUP BY co.stay_id, ce.charttime
),
gcs AS (
  -- intubated patients (verbal 'No Response-ETT') are assigned GCS 15 (MIMIC Code Repository convention)
  SELECT stay_id,
    MIN(CASE WHEN ett = 1 THEN 15
             WHEN e IS NOT NULL AND v IS NOT NULL AND m IS NOT NULL THEN e + v + m END) AS gcs_min
  FROM gcs_raw
  GROUP BY stay_id
),
uo AS (
  SELECT co.stay_id,
    SUM(IF(oe.itemid = 227488, -1 * oe.value, oe.value)) AS uo_24h
  FROM co
  JOIN `physionet-data.mimiciv_3_1_icu.outputevents` AS oe
    ON oe.stay_id = co.stay_id AND oe.charttime BETWEEN co.intime AND co.w1
  WHERE oe.itemid IN (226559, 226560, 226561, 226584, 226563, 226564, 226565, 226567,
                      226557, 226558, 227488, 227489)
  GROUP BY co.stay_id
),
vaso AS (
  SELECT co.stay_id,
    MAX(IF(ie.itemid = 221906, ie.r, NULL)) AS norepi,
    MAX(IF(ie.itemid = 221289, ie.r, NULL)) AS epi,
    MAX(IF(ie.itemid = 221662, ie.r, NULL)) AS dopa,
    MAX(IF(ie.itemid = 221653, ie.r, NULL)) AS dobu
  FROM co
  JOIN (
    SELECT stay_id, itemid, starttime, endtime,
      CASE WHEN rateuom = 'mcg/kg/min' THEN rate
           WHEN rateuom = 'mcg/min' AND patientweight > 0 THEN rate / patientweight
      END AS r
    FROM `physionet-data.mimiciv_3_1_icu.inputevents`
    WHERE itemid IN (221906, 221289, 221662, 221653) AND rate > 0
  ) AS ie
    ON ie.stay_id = co.stay_id AND ie.starttime < co.w1 AND ie.endtime > co.intime
  GROUP BY co.stay_id
),
raw AS (
  SELECT co.stay_id,
    l.plt_min, l.bili_max, l.cr_max, p.pf_min, p.pf_min_vent, vt.map_min, g.gcs_min, u.uo_24h,
    vs.norepi, vs.epi, vs.dopa, vs.dobu,
    IF(vd.stay_id IS NOT NULL, 1, 0) AS vent_d1,
    DATETIME_DIFF(LEAST(co.outtime, co.w1), co.intime, MINUTE) / 60 AS obs_hrs
  FROM co
  LEFT JOIN lab AS l ON l.stay_id = co.stay_id
  LEFT JOIN pf AS p ON p.stay_id = co.stay_id
  LEFT JOIN vit AS vt ON vt.stay_id = co.stay_id
  LEFT JOIN gcs AS g ON g.stay_id = co.stay_id
  LEFT JOIN uo AS u ON u.stay_id = co.stay_id
  LEFT JOIN vaso AS vs ON vs.stay_id = co.stay_id
  LEFT JOIN (SELECT DISTINCT stay_id FROM vent) AS vd ON vd.stay_id = co.stay_id
),
comp AS (
  SELECT raw.*,
    CASE WHEN pf_min_vent < 100 THEN 4 WHEN pf_min_vent < 200 THEN 3
         WHEN pf_min < 300 THEN 2 WHEN pf_min < 400 THEN 1 ELSE 0 END AS sofa_resp,
    CASE WHEN plt_min < 20 THEN 4 WHEN plt_min < 50 THEN 3
         WHEN plt_min < 100 THEN 2 WHEN plt_min < 150 THEN 1 ELSE 0 END AS sofa_coag,
    CASE WHEN bili_max >= 12 THEN 4 WHEN bili_max >= 6 THEN 3
         WHEN bili_max >= 2 THEN 2 WHEN bili_max >= 1.2 THEN 1 ELSE 0 END AS sofa_liver,
    CASE WHEN dopa > 15 OR epi > 0.1 OR norepi > 0.1 THEN 4
         WHEN dopa > 5 OR epi > 0 OR norepi > 0 THEN 3
         WHEN dopa > 0 OR dobu > 0 THEN 2
         WHEN map_min < 70 THEN 1 ELSE 0 END AS sofa_cv,
    CASE WHEN gcs_min < 6 THEN 4 WHEN gcs_min < 10 THEN 3
         WHEN gcs_min < 13 THEN 2 WHEN gcs_min < 15 THEN 1 ELSE 0 END AS sofa_cns,
    GREATEST(
      CASE WHEN cr_max >= 5 THEN 4 WHEN cr_max >= 3.5 THEN 3
           WHEN cr_max >= 2 THEN 2 WHEN cr_max >= 1.2 THEN 1 ELSE 0 END,
      CASE WHEN obs_hrs >= 20 AND uo_24h < 200 THEN 4
           WHEN obs_hrs >= 20 AND uo_24h < 500 THEN 3 ELSE 0 END) AS sofa_renal
  FROM raw
)
SELECT comp.*,
  sofa_resp + sofa_coag + sofa_liver + sofa_cv + sofa_cns + sofa_renal AS sofa_d1
FROM comp;
