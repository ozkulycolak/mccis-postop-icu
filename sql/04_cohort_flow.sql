-- mCCI-S | 04 | Cohort flow counts (aggregate only). Run after scripts 01-03. Replace YOUR_GCP_PROJECT.
SELECT * FROM (
  SELECT 'MIMIC-IV' AS dataset, '1 adult ICU stays' AS step, COUNT(*) AS n, SUM(icu_death) AS icu_deaths
  FROM `YOUR_GCP_PROJECT.mccis.mimic_stays`
  UNION ALL
  SELECT 'MIMIC-IV', '2 non-cardiac', COUNT(*), SUM(icu_death) FROM `YOUR_GCP_PROJECT.mccis.mimic_stays` WHERE cardiac = 0
  UNION ALL
  SELECT 'MIMIC-IV', '3 postoperative', COUNT(*), SUM(icu_death) FROM `YOUR_GCP_PROJECT.mccis.mimic_stays` WHERE postop = 1
  UNION ALL
  SELECT 'MIMIC-IV', '4 first postoperative stay per patient', COUNT(*), SUM(icu_death)
  FROM `YOUR_GCP_PROJECT.mccis.mimic_stays` WHERE in_cohort = 1
  UNION ALL
  SELECT 'MIMIC-IV', '5 analytic cohort (neuro step-down excluded)', COUNT(*), SUM(icu_death)
  FROM `YOUR_GCP_PROJECT.mccis.mimic_stays`
  WHERE in_cohort = 1 AND first_careunit NOT IN ('Neuro Intermediate', 'Neuro Stepdown')
  UNION ALL
  SELECT 'eICU-CRD', '1 adult first-visit operative admissions', COUNT(*), SUM(icu_death) FROM `YOUR_GCP_PROJECT.mccis.eicu_cohort`
  UNION ALL
  SELECT 'eICU-CRD', '2 non-cardiac', COUNT(*), SUM(icu_death) FROM `YOUR_GCP_PROJECT.mccis.eicu_cohort` WHERE cardiac = 0
  UNION ALL
  SELECT 'eICU-CRD', '3 analytic cohort (first admission per patient, urgency recorded)', COUNT(*), SUM(icu_death)
  FROM `YOUR_GCP_PROJECT.mccis.eicu_cohort` WHERE in_cohort = 1 AND emergency IS NOT NULL
  UNION ALL
  SELECT 'eICU-CRD', '4 hospitals', COUNT(DISTINCT hospitalid), NULL
  FROM `YOUR_GCP_PROJECT.mccis.eicu_cohort` WHERE in_cohort = 1 AND emergency IS NOT NULL
)
ORDER BY dataset, step
