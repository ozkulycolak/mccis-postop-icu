# mCCI-S: a comorbidity- and urgency-based mortality score for postoperative ICU patients

Code for the study *"Development and multinational external validation of a modified Charlson Comorbidity Index
for patients admitted to the intensive care unit after surgery"* (İşevi M, Çolak ÖY, Sezer Akman T, et al.).

The **modified Charlson Comorbidity Index for Surgical ICU patients (mCCI-S)** was developed in MIMIC-IV v3.1
(10,214 adults admitted to the ICU after non-cardiac surgery) and externally validated in the eICU Collaborative
Research Database v2.0 (16,925 patients, 185 US hospitals) and in the OMU-ICU cohort (1,190 patients, Mikail Yuksel
ICU, Ondokuz Mayis University, Türkiye).

## The score

| Item | Points |
|---|---|
| Age 50–69 years | 1 |
| Age 70–79 years | 3 |
| Age ≥80 years | 4 |
| Emergency surgery | 6 |
| Liver disease (mild or moderate-to-severe) | 4 |
| Myocardial infarction | 1 |
| Congestive heart failure | 1 |
| Peripheral vascular disease | 1 |
| Dementia | 1 |
| Renal disease (moderate-to-severe) | 1 |

Range 0–19. Predicted ICU mortality = 1 / (1 + exp(−(−4.858 + 0.2517 × points))).
Absolute risk should be recalibrated locally (intercept update) before use; see the paper.

## Repository structure

```
sql/
  01_mimic_postop_cohort.sql   MIMIC-IV postoperative cohort + Quan Charlson conditions -> mccis.mimic_stays
  02_mimic_sofa_day1.sql       first-day SOFA from raw MIMIC-IV tables                -> mccis.mimic_scores
  03_eicu_postop_cohort.sql    eICU-CRD postoperative cohort + Charlson conditions     -> mccis.eicu_cohort
  04_cohort_flow.sql           aggregate flow counts
notebooks/
  mccis_development_validation.ipynb   development, bootstrap validation, external validation, heterogeneity
scripts/
  local_external_validation.py         applies the score to a local cohort (CSV); prints aggregate results
docs/
  score_card.md
```

## How to reproduce

1. Obtain credentialed access to MIMIC-IV and eICU-CRD on PhysioNet and link your Google account to BigQuery
   (https://physionet.org/settings/cloud/).
2. In your own Google Cloud / BigQuery project, run the SQL scripts in order (01, 02, 03), replacing
   `YOUR_GCP_PROJECT` with your project ID. They create the dataset `mccis` with three analytic tables.
3. Open `notebooks/mccis_development_validation.ipynb` in Google Colab, set `PROJECT`, and run all cells.
   The notebook downloads `mccis_results.zip` containing aggregate results only.
4. For a local cohort, prepare a CSV as described in `scripts/local_external_validation.py` and run
   `python scripts/local_external_validation.py your_file.csv`.

Python packages: numpy, pandas, scipy, statsmodels, matplotlib, google-cloud-bigquery (all available in Colab).
Random seed 2026; 200 bootstrap resamples.

## Data availability

No patient-level data are included in this repository. MIMIC-IV and eICU-CRD are available to credentialed users
through PhysioNet. OMU-ICU data are available from the corresponding author on reasonable request, subject to
institutional approval.

## Citation

Please cite the article (details to be added on publication) and this repository (see `CITATION.cff`). When using
MIMIC-IV and eICU-CRD, also cite the datasets and PhysioNet as required by their licences.

## Licence

Code: MIT licence (see `LICENSE`).
