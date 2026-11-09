# mCCI-S score card

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

Predicted ICU mortality (development cohort calibration):
p = 1 / (1 + exp(−(−4.858 + 0.2517 × points)))

| Points | 0–2 | 3–5 | 6–8 | 9–11 | ≥12 |
|---|---|---|---|---|---|
| Observed ICU mortality, MIMIC-IV | 0.6% | 1.6% | 4.8% | 8.7% | 16.1% |
| Observed ICU mortality, eICU-CRD | 1.5% | 2.8% | 5.5% | 7.0% | 15.0% |
| Observed ICU mortality, OMU-ICU | 4.6% | 5.1% | 11.9% | 22.2% | 31.6% |

Baseline mortality differs between settings; update the intercept with local data before using absolute risks.
