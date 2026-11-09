-- mCCI-S | 01 | MIMIC-IV v3.1: adult postoperative ICU stays with Quan Charlson conditions
-- Creates YOUR_GCP_PROJECT.mccis.mimic_stays (one row per adult ICU stay; in_cohort = 1 marks the
-- first postoperative, non-cardiac ICU stay per patient). Replace YOUR_GCP_PROJECT (3 places).
-- Postoperative: preceding PACU stay, OR surgical service at ICU admission plus operative procedure code.
-- Charlson conditions: Quan enhanced ICD-9-CM/ICD-10 algorithms, index admission (no prefix) and previous
-- admissions (prefix p_); acute_cvd / tbi flag acute stroke or traumatic brain injury in the index admission.

CREATE SCHEMA IF NOT EXISTS `YOUR_GCP_PROJECT.mccis` OPTIONS (location = 'US');

CREATE OR REPLACE TABLE `YOUR_GCP_PROJECT.mccis.mimic_stays` AS
WITH
base AS (
  SELECT
    i.subject_id, i.hadm_id, i.stay_id, i.first_careunit, i.intime, i.outtime, i.los AS icu_los,
    a.admittime, a.admission_type, a.admission_location, a.deathtime, a.hospital_expire_flag,
    p.gender, p.dod,
    p.anchor_age + (EXTRACT(YEAR FROM a.admittime) - p.anchor_year) AS age
  FROM `physionet-data.mimiciv_3_1_icu.icustays` AS i
  JOIN `physionet-data.mimiciv_3_1_hosp.admissions` AS a ON a.hadm_id = i.hadm_id
  JOIN `physionet-data.mimiciv_3_1_hosp.patients` AS p ON p.subject_id = i.subject_id
),
prev_unit AS (
  SELECT stay_id, prev_careunit FROM (
    SELECT b.stay_id, t.careunit AS prev_careunit,
           ROW_NUMBER() OVER (PARTITION BY b.stay_id ORDER BY t.intime DESC) AS rn
    FROM base AS b
    JOIN `physionet-data.mimiciv_3_1_hosp.transfers` AS t ON t.hadm_id = b.hadm_id AND t.intime < b.intime
  ) WHERE rn = 1
),
svc AS (
  SELECT stay_id, curr_service FROM (
    SELECT b.stay_id, s.curr_service,
           ROW_NUMBER() OVER (PARTITION BY b.stay_id ORDER BY s.transfertime DESC) AS rn
    FROM base AS b
    JOIN `physionet-data.mimiciv_3_1_hosp.services` AS s
      ON s.hadm_id = b.hadm_id AND s.transfertime <= DATETIME_ADD(b.intime, INTERVAL 12 HOUR)
  ) WHERE rn = 1
),
-- operative evidence: operative procedure coded on the day of, or the day before, ICU admission
-- ICD-10-PCS: Medical and Surgical section (0) with open (0) or percutaneous endoscopic (4) approach
-- ICD-9-CM: procedure chapters 01-86, excluding bedside and diagnostic procedures
op AS (
  SELECT b.stay_id, 1 AS op_window
  FROM base AS b
  JOIN `physionet-data.mimiciv_3_1_hosp.procedures_icd` AS pr
    ON pr.hadm_id = b.hadm_id
   AND pr.chartdate BETWEEN DATE_SUB(DATE(b.intime), INTERVAL 1 DAY) AND DATE(b.intime)
  WHERE (pr.icd_version = 10 AND SUBSTR(pr.icd_code, 1, 1) = '0' AND SUBSTR(pr.icd_code, 5, 1) IN ('0', '4'))
     OR (pr.icd_version = 9
         AND SUBSTR(pr.icd_code, 1, 2) BETWEEN '01' AND '86'
         AND SUBSTR(pr.icd_code, 1, 3) NOT IN ('033','311','332','372','387','389','422','441','451','452','511')
         AND SUBSTR(pr.icd_code, 1, 4) NOT IN ('3404','3491','3995','5491'))
  GROUP BY b.stay_id
),
stays AS (
  SELECT
    b.*,
    pu.prev_careunit,
    sv.curr_service,
    IFNULL(o.op_window, 0) AS op_window,
    IF(pu.prev_careunit = 'PACU', 1, 0) AS from_pacu,
    IF(sv.curr_service IN ('SURG','NSURG','TSURG','VSURG','ORTHO','PSURG','GU','GYN','ENT','TRAUM','DENT','EYE'), 1, 0) AS surg_service,
    IF(b.first_careunit LIKE '%CVICU%' OR IFNULL(sv.curr_service, '') = 'CSURG', 1, 0) AS cardiac
  FROM base AS b
  LEFT JOIN prev_unit AS pu ON pu.stay_id = b.stay_id
  LEFT JOIN svc AS sv ON sv.stay_id = b.stay_id
  LEFT JOIN op AS o ON o.stay_id = b.stay_id
  WHERE b.age >= 18
),
elig AS (
  SELECT st.*,
    IF(st.cardiac = 0 AND (st.from_pacu = 1 OR (st.surg_service = 1 AND st.op_window = 1)), 1, 0) AS postop
  FROM stays AS st
),
ranked AS (
  SELECT e.*,
    IF(e.postop = 1 AND ROW_NUMBER() OVER (PARTITION BY e.subject_id, e.postop ORDER BY e.intime) = 1, 1, 0) AS in_cohort
  FROM elig AS e
),
dx AS (
  SELECT hadm_id, icd_version AS v, TRIM(icd_code) AS c
  FROM `physionet-data.mimiciv_3_1_hosp.diagnoses_icd`
),
hf AS (
  SELECT
    hadm_id,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('410', '412'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('I21', 'I22') OR SUBSTR(c, 1, 4) IN ('I252'))), 1, 0)) AS mi,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('428') OR SUBSTR(c, 1, 5) IN ('39891', '40201', '40211', '40291', '40401', '40403', '40411', '40413', '40491', '40493') OR SUBSTR(c, 1, 4) BETWEEN '4254' AND '4259')) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('I43', 'I50') OR SUBSTR(c, 1, 4) IN ('I099', 'I110', 'I130', 'I132', 'I255', 'I420', 'I425', 'I426', 'I427', 'I428', 'I429', 'P290'))), 1, 0)) AS chf,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('440', '441') OR SUBSTR(c, 1, 4) IN ('0930', '4373', '4431', '4432', '4433', '4434', '4435', '4436', '4437', '4438', '4439', '4471', '5571', '5579', 'V434'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('I70', 'I71') OR SUBSTR(c, 1, 4) IN ('I731', 'I738', 'I739', 'I771', 'I790', 'I792', 'K551', 'K558', 'K559', 'Z958', 'Z959'))), 1, 0)) AS pvd,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) BETWEEN '430' AND '438' OR SUBSTR(c, 1, 5) IN ('36234'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('G45', 'G46') OR SUBSTR(c, 1, 3) BETWEEN 'I60' AND 'I69' OR SUBSTR(c, 1, 4) IN ('H340'))), 1, 0)) AS cvd,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('290') OR SUBSTR(c, 1, 4) IN ('2941', '3312'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('F00', 'F01', 'F02', 'F03', 'G30') OR SUBSTR(c, 1, 4) IN ('F051', 'G311'))), 1, 0)) AS dementia,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) BETWEEN '490' AND '505' OR SUBSTR(c, 1, 4) IN ('4168', '4169', '5064', '5081', '5088'))) OR (v = 10 AND (SUBSTR(c, 1, 3) BETWEEN 'J40' AND 'J47' OR SUBSTR(c, 1, 3) BETWEEN 'J60' AND 'J67' OR SUBSTR(c, 1, 4) IN ('I278', 'I279', 'J684', 'J701', 'J703'))), 1, 0)) AS cpd,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('725') OR SUBSTR(c, 1, 4) IN ('4465', '7100', '7101', '7102', '7103', '7104', '7140', '7141', '7142', '7148'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('M05', 'M06', 'M32', 'M33', 'M34') OR SUBSTR(c, 1, 4) IN ('M315', 'M351', 'M353', 'M360'))), 1, 0)) AS rheum,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('531', '532', '533', '534'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('K25', 'K26', 'K27', 'K28'))), 1, 0)) AS pud,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('570', '571') OR SUBSTR(c, 1, 4) IN ('0706', '0709', '5733', '5734', '5738', '5739', 'V427') OR SUBSTR(c, 1, 5) IN ('07022', '07023', '07032', '07033', '07044', '07054'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('B18', 'K73', 'K74') OR SUBSTR(c, 1, 4) IN ('K700', 'K701', 'K702', 'K703', 'K709', 'K713', 'K714', 'K715', 'K717', 'K760', 'K762', 'K763', 'K764', 'K768', 'K769', 'Z944'))), 1, 0)) AS mild_liver,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 4) IN ('4560', '4561', '4562') OR SUBSTR(c, 1, 4) BETWEEN '5722' AND '5728')) OR (v = 10 AND (SUBSTR(c, 1, 4) IN ('I850', 'I859', 'I864', 'I982', 'K704', 'K711', 'K721', 'K729', 'K765', 'K766', 'K767'))), 1, 0)) AS severe_liver,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 4) IN ('2500', '2501', '2502', '2503', '2508', '2509'))) OR (v = 10 AND (SUBSTR(c, 1, 4) IN ('E100', 'E101', 'E106', 'E108', 'E109', 'E110', 'E111', 'E116', 'E118', 'E119', 'E120', 'E121', 'E126', 'E128', 'E129', 'E130', 'E131', 'E136', 'E138', 'E139', 'E140', 'E141', 'E146', 'E148', 'E149'))), 1, 0)) AS dm_nocc,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 4) IN ('2504', '2505', '2506', '2507'))) OR (v = 10 AND (SUBSTR(c, 1, 4) IN ('E102', 'E103', 'E104', 'E105', 'E107', 'E112', 'E113', 'E114', 'E115', 'E117', 'E122', 'E123', 'E124', 'E125', 'E127', 'E132', 'E133', 'E134', 'E135', 'E137', 'E142', 'E143', 'E144', 'E145', 'E147'))), 1, 0)) AS dm_cc,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('342', '343') OR SUBSTR(c, 1, 4) IN ('3341', '3440', '3441', '3442', '3443', '3444', '3445', '3446', '3449'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('G81', 'G82') OR SUBSTR(c, 1, 4) IN ('G041', 'G114', 'G801', 'G802', 'G830', 'G831', 'G832', 'G833', 'G834', 'G839'))), 1, 0)) AS hemi,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('582', '585', '586', 'V56') OR SUBSTR(c, 1, 4) IN ('5880', 'V420', 'V451') OR SUBSTR(c, 1, 4) BETWEEN '5830' AND '5837' OR SUBSTR(c, 1, 5) IN ('40301', '40311', '40391', '40402', '40403', '40412', '40413', '40492', '40493'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('N18', 'N19') OR SUBSTR(c, 1, 4) IN ('I120', 'I131', 'N032', 'N033', 'N034', 'N035', 'N036', 'N037', 'N052', 'N053', 'N054', 'N055', 'N056', 'N057', 'N250', 'Z490', 'Z491', 'Z492', 'Z940', 'Z992'))), 1, 0)) AS renal,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 4) IN ('5854', '5855', '5856', 'V420', 'V451') OR SUBSTR(c, 1, 3) IN ('V56') OR SUBSTR(c, 1, 5) IN ('40301', '40311', '40391', '40402', '40403', '40412', '40413', '40492', '40493'))) OR (v = 10 AND (SUBSTR(c, 1, 4) IN ('N184', 'N185', 'N186', 'I120', 'I132', 'Z490', 'Z491', 'Z492', 'Z940', 'Z992') OR SUBSTR(c, 1, 5) IN ('I1311'))), 1, 0)) AS renal_sev,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) BETWEEN '140' AND '172' OR SUBSTR(c, 1, 4) BETWEEN '1740' AND '1958' OR SUBSTR(c, 1, 3) BETWEEN '200' AND '208' OR SUBSTR(c, 1, 4) IN ('2386'))) OR (v = 10 AND (SUBSTR(c, 1, 3) BETWEEN 'C00' AND 'C26' OR SUBSTR(c, 1, 3) BETWEEN 'C30' AND 'C34' OR SUBSTR(c, 1, 3) BETWEEN 'C37' AND 'C41' OR SUBSTR(c, 1, 3) IN ('C43') OR SUBSTR(c, 1, 3) BETWEEN 'C45' AND 'C58' OR SUBSTR(c, 1, 3) BETWEEN 'C60' AND 'C76' OR SUBSTR(c, 1, 3) BETWEEN 'C81' AND 'C85' OR SUBSTR(c, 1, 3) IN ('C88') OR SUBSTR(c, 1, 3) BETWEEN 'C90' AND 'C97')), 1, 0)) AS malig_any,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) BETWEEN '200' AND '208')) OR (v = 10 AND (SUBSTR(c, 1, 3) BETWEEN 'C81' AND 'C85' OR SUBSTR(c, 1, 3) IN ('C88') OR SUBSTR(c, 1, 3) BETWEEN 'C90' AND 'C96')), 1, 0)) AS heme,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) BETWEEN '140' AND '172' OR SUBSTR(c, 1, 4) BETWEEN '1740' AND '1958')) OR (v = 10 AND (SUBSTR(c, 1, 3) BETWEEN 'C00' AND 'C26' OR SUBSTR(c, 1, 3) BETWEEN 'C30' AND 'C34' OR SUBSTR(c, 1, 3) BETWEEN 'C37' AND 'C41' OR SUBSTR(c, 1, 3) IN ('C43') OR SUBSTR(c, 1, 3) BETWEEN 'C45' AND 'C58' OR SUBSTR(c, 1, 3) BETWEEN 'C60' AND 'C76')), 1, 0)) AS solid,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('196', '197', '198', '199'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('C77', 'C78', 'C79', 'C80'))), 1, 0)) AS mets,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('042', '043', '044'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('B20', 'B21', 'B22', 'B24'))), 1, 0)) AS aids,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('430', '431', '432', '434', '436') OR (SUBSTR(c, 1, 3) IN ('433') AND SUBSTR(c, 5, 1) = '1'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('I60', 'I61', 'I62', 'I63'))), 1, 0)) AS acute_cvd,
    MAX(IF((v = 9 AND (SUBSTR(c, 1, 3) IN ('800', '801', '803', '804', '850', '851', '852', '853', '854'))) OR (v = 10 AND (SUBSTR(c, 1, 3) IN ('S06'))), 1, 0)) AS tbi
  FROM dx
  GROUP BY hadm_id
),
prior AS (
  SELECT
    r.stay_id,
    COUNT(DISTINCT pa.hadm_id) AS n_prior_adm,
    MAX(IFNULL(f.mi, 0)) AS p_mi,
    MAX(IFNULL(f.chf, 0)) AS p_chf,
    MAX(IFNULL(f.pvd, 0)) AS p_pvd,
    MAX(IFNULL(f.cvd, 0)) AS p_cvd,
    MAX(IFNULL(f.dementia, 0)) AS p_dementia,
    MAX(IFNULL(f.cpd, 0)) AS p_cpd,
    MAX(IFNULL(f.rheum, 0)) AS p_rheum,
    MAX(IFNULL(f.pud, 0)) AS p_pud,
    MAX(IFNULL(f.mild_liver, 0)) AS p_mild_liver,
    MAX(IFNULL(f.severe_liver, 0)) AS p_severe_liver,
    MAX(IFNULL(f.dm_nocc, 0)) AS p_dm_nocc,
    MAX(IFNULL(f.dm_cc, 0)) AS p_dm_cc,
    MAX(IFNULL(f.hemi, 0)) AS p_hemi,
    MAX(IFNULL(f.renal, 0)) AS p_renal,
    MAX(IFNULL(f.renal_sev, 0)) AS p_renal_sev,
    MAX(IFNULL(f.malig_any, 0)) AS p_malig_any,
    MAX(IFNULL(f.heme, 0)) AS p_heme,
    MAX(IFNULL(f.solid, 0)) AS p_solid,
    MAX(IFNULL(f.mets, 0)) AS p_mets,
    MAX(IFNULL(f.aids, 0)) AS p_aids
  FROM ranked AS r
  JOIN `physionet-data.mimiciv_3_1_hosp.admissions` AS pa
    ON pa.subject_id = r.subject_id AND pa.admittime < r.admittime
  LEFT JOIN hf AS f ON f.hadm_id = pa.hadm_id
  GROUP BY r.stay_id
)
SELECT
  r.subject_id, r.hadm_id, r.stay_id, r.first_careunit, r.prev_careunit, r.curr_service,
  r.admission_type, r.admission_location, r.gender, r.age, r.intime, r.outtime, r.icu_los,
  r.from_pacu, r.surg_service, r.op_window, r.cardiac, r.postop, r.in_cohort,
  DATETIME_DIFF(r.intime, r.admittime, HOUR) AS hrs_adm_to_icu,
  IF(r.admission_type IN ('ELECTIVE', 'SURGICAL SAME DAY ADMISSION'), 0, 1) AS emergency,
  IF(r.admission_type IN ('EW EMER.', 'URGENT', 'DIRECT EMER.'), 1, 0) AS emerg_strict,
  CASE
    WHEN r.curr_service = 'TSURG' THEN 'Thoracic'
    WHEN r.curr_service = 'NSURG' THEN 'Neurosurgery'
    WHEN r.curr_service = 'ORTHO' THEN 'Orthopaedic'
    WHEN r.curr_service IN ('ENT', 'DENT', 'EYE', 'PSURG') THEN 'Head-neck/plastic'
    WHEN r.curr_service IN ('SURG', 'GU', 'GYN') THEN 'Abdominal/GU'
    WHEN r.curr_service = 'VSURG' THEN 'Vascular'
    WHEN r.curr_service = 'TRAUM' THEN 'Trauma'
    ELSE 'Other'
  END AS surg_cat,
  IF(r.deathtime IS NOT NULL AND r.deathtime >= r.intime
     AND r.deathtime <= DATETIME_ADD(r.outtime, INTERVAL 6 HOUR), 1, 0) AS icu_death,
  r.hospital_expire_flag AS hosp_death,
  IF(r.dod IS NOT NULL AND r.dod <= DATE_ADD(DATE(r.intime), INTERVAL 30 DAY), 1, 0) AS death_30d,
  IFNULL(h.mi, 0) AS mi,
  IFNULL(h.chf, 0) AS chf,
  IFNULL(h.pvd, 0) AS pvd,
  IFNULL(h.cvd, 0) AS cvd,
  IFNULL(h.dementia, 0) AS dementia,
  IFNULL(h.cpd, 0) AS cpd,
  IFNULL(h.rheum, 0) AS rheum,
  IFNULL(h.pud, 0) AS pud,
  IFNULL(h.mild_liver, 0) AS mild_liver,
  IFNULL(h.severe_liver, 0) AS severe_liver,
  IFNULL(h.dm_nocc, 0) AS dm_nocc,
  IFNULL(h.dm_cc, 0) AS dm_cc,
  IFNULL(h.hemi, 0) AS hemi,
  IFNULL(h.renal, 0) AS renal,
  IFNULL(h.renal_sev, 0) AS renal_sev,
  IFNULL(h.malig_any, 0) AS malig_any,
  IFNULL(h.heme, 0) AS heme,
  IFNULL(h.solid, 0) AS solid,
  IFNULL(h.mets, 0) AS mets,
  IFNULL(h.aids, 0) AS aids,
  IFNULL(h.acute_cvd, 0) AS acute_cvd,
  IFNULL(h.tbi, 0) AS tbi,
  IFNULL(pr.n_prior_adm, 0) AS n_prior_adm,
  IFNULL(pr.p_mi, 0) AS p_mi,
  IFNULL(pr.p_chf, 0) AS p_chf,
  IFNULL(pr.p_pvd, 0) AS p_pvd,
  IFNULL(pr.p_cvd, 0) AS p_cvd,
  IFNULL(pr.p_dementia, 0) AS p_dementia,
  IFNULL(pr.p_cpd, 0) AS p_cpd,
  IFNULL(pr.p_rheum, 0) AS p_rheum,
  IFNULL(pr.p_pud, 0) AS p_pud,
  IFNULL(pr.p_mild_liver, 0) AS p_mild_liver,
  IFNULL(pr.p_severe_liver, 0) AS p_severe_liver,
  IFNULL(pr.p_dm_nocc, 0) AS p_dm_nocc,
  IFNULL(pr.p_dm_cc, 0) AS p_dm_cc,
  IFNULL(pr.p_hemi, 0) AS p_hemi,
  IFNULL(pr.p_renal, 0) AS p_renal,
  IFNULL(pr.p_renal_sev, 0) AS p_renal_sev,
  IFNULL(pr.p_malig_any, 0) AS p_malig_any,
  IFNULL(pr.p_heme, 0) AS p_heme,
  IFNULL(pr.p_solid, 0) AS p_solid,
  IFNULL(pr.p_mets, 0) AS p_mets,
  IFNULL(pr.p_aids, 0) AS p_aids
FROM ranked AS r
LEFT JOIN hf AS h ON h.hadm_id = r.hadm_id
LEFT JOIN prior AS pr ON pr.stay_id = r.stay_id;
