-- mCCI-S | 03 | eICU-CRD v2.0: adult postoperative ICU admissions with Charlson conditions
-- Creates YOUR_GCP_PROJECT.mccis.eicu_cohort (in_cohort = 1: first non-cardiac operative admission per patient).
-- Postoperative: APACHE operative admission diagnosis (from operating room or surgery within 4 h).
-- Cardiac surgery excluded by unit type and APACHE admission diagnosis.
-- Charlson conditions: structured past history OR diagnosis ICD-9/10 codes (Quan) OR APACHE chronic health items.

CREATE OR REPLACE TABLE `YOUR_GCP_PROJECT.mccis.eicu_cohort` AS
WITH
pt AS (
  SELECT p.*,
    CASE WHEN p.age = '> 89' THEN 90 ELSE SAFE_CAST(p.age AS INT64) END AS age_n
  FROM `physionet-data.eicu_crd.patient` AS p
),
adx AS (
  SELECT patientunitstayid,
    MAX(IF(admitdxpath LIKE '%|Operative|%', 1, 0)) AS operative_dx,
    MAX(IF(LOWER(admitdxpath) LIKE '%|elective|yes%', 1, 0)) AS elective_yes,
    MAX(IF(LOWER(admitdxpath) LIKE '%|elective|no%', 1, 0)) AS elective_no,
    MAX(IF(admitdxpath LIKE '%Operative Organ Systems|Organ System|%',
           SPLIT(admitdxpath, '|')[SAFE_OFFSET(3)], NULL)) AS op_system
  FROM `physionet-data.eicu_crd.admissiondx`
  GROUP BY patientunitstayid
),
apv AS (
  SELECT patientunitstayid,
    MAX(electivesurgery) AS electivesurgery,
    MAX(IFNULL(aids, 0)) AS a_aids,
    MAX(GREATEST(IFNULL(lymphoma,0), IFNULL(leukemia,0))) AS a_heme,
    MAX(IFNULL(metastaticcancer, 0)) AS a_mets,
    MAX(IFNULL(cirrhosis, 0)) AS a_mild_liver,
    MAX(IFNULL(hepaticfailure, 0)) AS a_severe_liver,
    MAX(IFNULL(diabetes, 0)) AS a_dm_nocc
  FROM `physionet-data.eicu_crd.apachepredvar`
  GROUP BY patientunitstayid
),
apr AS (
  SELECT patientunitstayid,
    MAX(IF(apachescore >= 0, apachescore, NULL)) AS apache_iva,
    MAX(IF(acutephysiologyscore >= 0, acutephysiologyscore, NULL)) AS aps_iva,
    MAX(IF(predictedhospitalmortality > 0, predictedhospitalmortality, NULL)) AS apache_pred_hosp,
    MAX(IF(predictediculos >= 0, predictediculos, NULL)) AS apache_pred_iculos
  FROM `physionet-data.eicu_crd.apachepatientresult`
  WHERE apacheversion = 'IVa'
  GROUP BY patientunitstayid
),
elig AS (
  SELECT pt.patientunitstayid, pt.uniquepid, pt.patienthealthsystemstayid, pt.hospitalid,
    pt.unittype, pt.unitadmitsource, pt.apacheadmissiondx, pt.gender, pt.age_n AS age,
    pt.hospitaldischargeyear, pt.unitdischargeoffset,
    IF(pt.unitdischargestatus = 'Expired', 1, 0) AS icu_death,
    IF(pt.hospitaldischargestatus = 'Expired', 1, 0) AS hosp_death,
    pt.unitdischargeoffset / 1440 AS icu_los,
    a.op_system,
    CASE WHEN a.elective_no = 1 THEN 1 WHEN a.elective_yes = 1 THEN 0
         WHEN v.electivesurgery = 0 THEN 1 WHEN v.electivesurgery = 1 THEN 0 END AS emergency,
    IF(pt.unittype IN ('CTICU', 'CSICU', 'CCU-CTICU', 'Cardiac ICU')
       OR REGEXP_CONTAINS(IFNULL(pt.apacheadmissiondx, ''), r'(?i)CABG|valve|ablation or mapping|pericardi|cardiac|heart transplant|ventricular|septal|pacemaker|defibrillator|assist device|Cardiovascular surgery, other'), 1, 0) AS cardiac,
    IF(REGEXP_CONTAINS(IFNULL(pt.apacheadmissiondx, ''), r'(?i)hemorrhage|hematoma|subarachnoid|stroke|head only trauma|head/|intracranial|CVA'), 1, 0) AS acute_brain_dx,
    r.apache_iva, r.aps_iva, r.apache_pred_hosp
  FROM pt
  JOIN adx AS a ON a.patientunitstayid = pt.patientunitstayid
  LEFT JOIN apv AS v ON v.patientunitstayid = pt.patientunitstayid
  LEFT JOIN apr AS r ON r.patientunitstayid = pt.patientunitstayid
  WHERE pt.age_n >= 18 AND pt.unitvisitnumber = 1 AND a.operative_dx = 1
),
ranked AS (
  SELECT e.*,
    IF(e.cardiac = 0 AND ROW_NUMBER() OVER (PARTITION BY e.uniquepid, e.cardiac
          ORDER BY e.hospitaldischargeyear, e.patienthealthsystemstayid, e.patientunitstayid) = 1, 1, 0) AS in_cohort
  FROM elig AS e
),
ph AS (
  SELECT patientunitstayid,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Cardiovascular (R)/Myocardial Infarction/%', 1, 0)) AS mi,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Cardiovascular (R)/Congestive Heart Failure/%', 1, 0)) AS chf,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Cardiovascular (R)/Peripheral Vascular Disease/%', 1, 0)) AS pvd,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Neurologic/Strokes/%' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Neurologic/TIA(s)/%', 1, 0)) AS cvd,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Neurologic/Dementia/%', 1, 0)) AS dementia,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Pulmonary/COPD/%' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Pulmonary/Asthma/%' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Pulmonary/Home Oxygen/%' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Pulmonary/Restrictive Disease/%', 1, 0)) AS cpd,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Rheumatic/%', 1, 0)) AS rheum,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Gastrointestinal (R)/Peptic Ulcer Disease/%', 1, 0)) AS pud,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Gastrointestinal (R)/Cirrhosis/clinical diagnosis' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Gastrointestinal (R)/Cirrhosis/biopsy proven' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Gastrointestinal (R)/s/p Liver Transplant/%', 1, 0)) AS mild_liver,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Gastrointestinal (R)/Cirrhosis/varices' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Gastrointestinal (R)/Cirrhosis/UGI bleeding' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Gastrointestinal (R)/Cirrhosis/ascites' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Gastrointestinal (R)/Cirrhosis/encephalopathy' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Gastrointestinal (R)/Cirrhosis/jaundice' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Gastrointestinal (R)/Cirrhosis/coma', 1, 0)) AS severe_liver,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Endocrine (R)/Non-Insulin Dependent Diabetes/%' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Endocrine (R)/Insulin Dependent Diabetes/%', 1, 0)) AS dm_nocc,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/Renal Failure/%' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/s/p Renal Transplant/%' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/Renal Insufficiency/renal insufficiency - creatinine 2-3' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/Renal Insufficiency/renal insufficiency - creatinine 3-4' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/Renal Insufficiency/renal insufficiency - creatinine 4-5' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/Renal Insufficiency/renal insufficiency - creatinine > 5', 1, 0)) AS renal,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/Renal Failure/renal failure - hemodialysis' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/Renal Failure/renal failure - peritoneal dialysis' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/s/p Renal Transplant/%' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/Renal Insufficiency/renal insufficiency - creatinine 3-4' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/Renal Insufficiency/renal insufficiency - creatinine 4-5' OR pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Renal  (R)/Renal Insufficiency/renal insufficiency - creatinine > 5', 1, 0)) AS renal_sev,
    MAX(IF((pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Hematology/Oncology (R)/Cancer/Cancer-Primary Site/%' AND pasthistorypath NOT LIKE '%/none'), 1, 0)) AS solid,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Hematology/Oncology (R)/Cancer/Hematologic Malignancy/%', 1, 0)) AS heme,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Hematology/Oncology (R)/Cancer/Metastases/%', 1, 0)) AS mets,
    MAX(IF(pasthistorypath LIKE 'notes/Progress Notes/Past History/Organ Systems/Infectious Disease (R)/AIDS/%', 1, 0)) AS aids
  FROM `physionet-data.eicu_crd.pasthistory`
  GROUP BY patientunitstayid
),
icd_raw AS (
  SELECT d.patientunitstayid, REPLACE(TRIM(code), '.', '') AS c,
    CASE WHEN REGEXP_CONTAINS(TRIM(code), r'^[0-9]') THEN 9
         WHEN REGEXP_CONTAINS(TRIM(code), r'^V') THEN 9
         WHEN REGEXP_CONTAINS(TRIM(code), r'^E[0-9]{3}') THEN 9
         ELSE 10 END AS v
  FROM `physionet-data.eicu_crd.diagnosis` AS d,
  UNNEST(SPLIT(IFNULL(d.icd9code, ''), ',')) AS code
  WHERE TRIM(code) != ''
),
ic AS (
  SELECT patientunitstayid,
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
  FROM icd_raw
  GROUP BY patientunitstayid
),
apf AS (
  SELECT patientunitstayid, a_aids, a_heme, a_mets, a_mild_liver, a_severe_liver, a_dm_nocc FROM apv
)
SELECT
  r.*,
  IF(ph.patientunitstayid IS NOT NULL, 1, 0) AS has_pasthistory,
  IF(ic.patientunitstayid IS NOT NULL, 1, 0) AS has_icd,
  IFNULL(ic.acute_cvd, 0) AS acute_cvd,
  IFNULL(ic.tbi, 0) AS tbi,
  GREATEST(IFNULL(ph.mi, 0), IFNULL(ic.mi, 0)) AS mi,
  GREATEST(IFNULL(ph.chf, 0), IFNULL(ic.chf, 0)) AS chf,
  GREATEST(IFNULL(ph.pvd, 0), IFNULL(ic.pvd, 0)) AS pvd,
  GREATEST(IFNULL(ph.cvd, 0), IFNULL(ic.cvd, 0)) AS cvd,
  GREATEST(IFNULL(ph.dementia, 0), IFNULL(ic.dementia, 0)) AS dementia,
  GREATEST(IFNULL(ph.cpd, 0), IFNULL(ic.cpd, 0)) AS cpd,
  GREATEST(IFNULL(ph.rheum, 0), IFNULL(ic.rheum, 0)) AS rheum,
  GREATEST(IFNULL(ph.pud, 0), IFNULL(ic.pud, 0)) AS pud,
  GREATEST(IFNULL(ph.mild_liver, 0), IFNULL(ic.mild_liver, 0), IFNULL(ap.a_mild_liver, 0)) AS mild_liver,
  GREATEST(IFNULL(ph.severe_liver, 0), IFNULL(ic.severe_liver, 0), IFNULL(ap.a_severe_liver, 0)) AS severe_liver,
  GREATEST(IFNULL(ph.dm_nocc, 0), IFNULL(ic.dm_nocc, 0), IFNULL(ap.a_dm_nocc, 0)) AS dm_nocc,
  IFNULL(ic.dm_cc, 0) AS dm_cc,
  IFNULL(ic.hemi, 0) AS hemi,
  GREATEST(IFNULL(ph.renal, 0), IFNULL(ic.renal, 0)) AS renal,
  GREATEST(IFNULL(ph.renal_sev, 0), IFNULL(ic.renal_sev, 0)) AS renal_sev,
  GREATEST(IFNULL(ic.malig_any, 0), IFNULL(ph.solid, 0), IFNULL(ph.heme, 0), IFNULL(ap.a_heme, 0)) AS malig_any,
  GREATEST(IFNULL(ph.heme, 0), IFNULL(ic.heme, 0), IFNULL(ap.a_heme, 0)) AS heme,
  GREATEST(IFNULL(ph.solid, 0), IFNULL(ic.solid, 0)) AS solid,
  GREATEST(IFNULL(ph.mets, 0), IFNULL(ic.mets, 0), IFNULL(ap.a_mets, 0)) AS mets,
  GREATEST(IFNULL(ph.aids, 0), IFNULL(ic.aids, 0), IFNULL(ap.a_aids, 0)) AS aids,
  IFNULL(ph.mi, 0) AS ph_mi,
  IFNULL(ph.chf, 0) AS ph_chf,
  IFNULL(ph.pvd, 0) AS ph_pvd,
  IFNULL(ph.cvd, 0) AS ph_cvd,
  IFNULL(ph.dementia, 0) AS ph_dementia,
  IFNULL(ph.cpd, 0) AS ph_cpd,
  IFNULL(ph.rheum, 0) AS ph_rheum,
  IFNULL(ph.pud, 0) AS ph_pud,
  IFNULL(ph.mild_liver, 0) AS ph_mild_liver,
  IFNULL(ph.severe_liver, 0) AS ph_severe_liver,
  IFNULL(ph.dm_nocc, 0) AS ph_dm_nocc,
  IFNULL(ph.renal, 0) AS ph_renal,
  IFNULL(ph.renal_sev, 0) AS ph_renal_sev,
  IFNULL(ph.solid, 0) AS ph_solid,
  IFNULL(ph.heme, 0) AS ph_heme,
  IFNULL(ph.mets, 0) AS ph_mets,
  IFNULL(ph.aids, 0) AS ph_aids,
  IFNULL(ic.mi, 0) AS icd_mi,
  IFNULL(ic.chf, 0) AS icd_chf,
  IFNULL(ic.pvd, 0) AS icd_pvd,
  IFNULL(ic.cvd, 0) AS icd_cvd,
  IFNULL(ic.dementia, 0) AS icd_dementia,
  IFNULL(ic.cpd, 0) AS icd_cpd,
  IFNULL(ic.rheum, 0) AS icd_rheum,
  IFNULL(ic.pud, 0) AS icd_pud,
  IFNULL(ic.mild_liver, 0) AS icd_mild_liver,
  IFNULL(ic.severe_liver, 0) AS icd_severe_liver,
  IFNULL(ic.dm_nocc, 0) AS icd_dm_nocc,
  IFNULL(ic.dm_cc, 0) AS icd_dm_cc,
  IFNULL(ic.hemi, 0) AS icd_hemi,
  IFNULL(ic.renal, 0) AS icd_renal,
  IFNULL(ic.renal_sev, 0) AS icd_renal_sev,
  IFNULL(ic.malig_any, 0) AS icd_malig_any,
  IFNULL(ic.heme, 0) AS icd_heme,
  IFNULL(ic.solid, 0) AS icd_solid,
  IFNULL(ic.mets, 0) AS icd_mets,
  IFNULL(ic.aids, 0) AS icd_aids
FROM ranked AS r
LEFT JOIN ph ON ph.patientunitstayid = r.patientunitstayid
LEFT JOIN ic ON ic.patientunitstayid = r.patientunitstayid
LEFT JOIN apf AS ap ON ap.patientunitstayid = r.patientunitstayid;
