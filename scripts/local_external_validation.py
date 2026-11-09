#!/usr/bin/env python3
"""External validation of the mCCI-S in a local cohort (used for the OMU-ICU cohort).

Usage:  python scripts/local_external_validation.py local_cohort.csv

The CSV must contain one row per patient and these columns (0/1 unless stated):
  age (years), emergency, icu_death, mi, chf, pvd, dementia, liver (mild or moderate-to-severe liver disease),
  renal (moderate-to-severe renal disease); optional: cci (original Charlson Comorbidity Index, for comparison).
Patient-level data are never written; the script prints aggregate results only.
"""
import sys, json
import numpy as np, pandas as pd, scipy.stats as st, statsmodels.api as sm

expit = lambda x: 1 / (1 + np.exp(-x))
logit = lambda p: np.log(p / (1 - p))
POINT_UNIT = 0.25

# mCCI-S (developed in MIMIC-IV v3.1)
INTERCEPT, SLOPE = -4.858, 0.2517


def mccis_points(d):
    age_pts = np.select([d.age >= 80, d.age >= 70, d.age >= 50], [4, 3, 1], 0)
    return (age_pts + 6 * d.emergency + d.mi + d.chf + d.pvd + d.dementia + 4 * d.liver + d.renal).astype(int)


def _midrank(x):
    j = np.argsort(x); z = x[j]; n = len(x); t = np.zeros(n); i = 0
    while i < n:
        k = i
        while k < n and z[k] == z[i]:
            k += 1
        t[i:k] = 0.5 * (i + k - 1) + 1
        i = k
    out = np.empty(n); out[j] = t
    return out


def delong(y, preds):
    y = np.asarray(y).astype(int); pos, neg = y == 1, y == 0
    m, n = pos.sum(), neg.sum()
    aucs, v01s, v10s = [], [], []
    for p in preds:
        p = np.asarray(p, float)
        tx, ty = _midrank(p[pos]), _midrank(p[neg])
        tz = _midrank(np.concatenate([p[pos], p[neg]]))
        aucs.append((tz[:m].sum() - m * (m + 1) / 2) / (m * n))
        v01s.append((tz[:m] - tx) / n); v10s.append(1 - (tz[m:] - ty) / m)
    sx = np.atleast_2d(np.cov(np.vstack(v01s))); sy = np.atleast_2d(np.cov(np.vstack(v10s)))
    return np.array(aucs), sx / m + sy / n


def auc_ci(y, p):
    a, s = delong(y, [p]); se = np.sqrt(s[0, 0])
    return a[0], a[0] - 1.96 * se, a[0] + 1.96 * se


def auc_compare(y, p1, p2):
    a, s = delong(y, [p1, p2]); d = a[0] - a[1]
    se = np.sqrt(s[0, 0] + s[1, 1] - 2 * s[0, 1])
    return d, d - 1.96 * se, d + 1.96 * se, 2 * st.norm.sf(abs(d / se))


def calibration(y, p):
    y = np.asarray(y, float); p = np.clip(np.asarray(p, float), 1e-6, 1 - 1e-6); lp = logit(p)
    citl = sm.GLM(y, np.ones((len(y), 1)), family=sm.families.Binomial(), offset=lp).fit()
    slope = sm.GLM(y, sm.add_constant(lp, has_constant="add"), family=sm.families.Binomial()).fit()
    lo = sm.nonparametric.lowess(y, p, frac=2 / 3, it=0, return_sorted=False)
    ci_i, ci_s = citl.conf_int()[0], slope.conf_int()[1]
    return {"O": int(y.sum()), "E": float(p.sum()), "O_E": y.sum() / p.sum(),
            "citl": citl.params[0], "citl_lo": ci_i[0], "citl_hi": ci_i[1],
            "slope": slope.params[1], "slope_lo": ci_s[0], "slope_hi": ci_s[1],
            "brier": np.mean((p - y) ** 2), "ICI": np.mean(np.abs(lo - p)), "E90": np.quantile(np.abs(lo - p), .9)}


def calib_deciles(y, p, label):
    q = pd.qcut(pd.Series(p).rank(method="first"), 10, labels=False)
    g = pd.DataFrame({"y": np.asarray(y), "p": np.asarray(p), "q": q}).groupby("q")
    r = g.agg(n=("y", "size"), events=("y", "sum"), predicted=("p", "mean"), observed=("y", "mean")).reset_index()
    r.insert(0, "label", label)
    return r


def dca(y, p, label, thr=np.arange(0.01, 0.31, 0.01)):
    y = np.asarray(y); n = len(y); prev = y.mean(); rows = []
    for t in thr:
        pos = p >= t
        nb = ((pos & (y == 1)).sum() - (pos & (y == 0)).sum() * t / (1 - t)) / n
        rows.append({"label": label, "threshold": round(t, 2), "net_benefit": nb,
                     "treat_all": prev - (1 - prev) * t / (1 - t)})
    return pd.DataFrame(rows)


def calib_slope(y, p):
    lp = logit(np.clip(np.asarray(p, float), 1e-6, 1 - 1e-6))
    return sm.GLM(np.asarray(y, float), sm.add_constant(lp, has_constant="add"), family=sm.families.Binomial()).fit().params[1]


def fit_logit(df, cols, y="icu_death"):
    X = sm.add_constant(df[cols].astype(float), has_constant="add")
    return sm.GLM(df[y].astype(float), X, family=sm.families.Binomial()).fit()


def lp_from(beta, df, cols):
    return beta["const"] + df[cols].astype(float).values @ np.array([beta[c] for c in cols])


def build_points_model(df, cols, y="icu_death", nonneg=False):
    """Logistic model -> van Houwelingen uniform shrinkage -> integer points -> points-to-risk mapping."""
    m = fit_logit(df, cols, y)
    chi2 = m.null_deviance - m.deviance; k = len(cols)
    shrink = max(0.0, min(1.0, (chi2 - k) / chi2))
    b = m.params.copy(); b[cols] = b[cols] * shrink
    off = df[cols].astype(float).values @ b[cols].values
    b["const"] = sm.GLM(df[y].astype(float).values, np.ones((len(df), 1)), family=sm.families.Binomial(),
                        offset=off).fit().params[0]
    pts = {c: int(np.round(b[c] / POINT_UNIT)) for c in cols}
    if nonneg:   # clinical constraint: no predictor may lower risk -> negative points set to 0
        pts = {c: max(0, v) for c, v in pts.items()}
    score = df[cols].astype(int).values @ np.array([pts[c] for c in cols])
    mp = sm.GLM(df[y].astype(float).values, sm.add_constant(score.astype(float), has_constant="add"), family=sm.families.Binomial()).fit()
    return {"fit": m, "shrink": shrink, "beta_shrunk": b.to_dict(), "points": pts,
            "map": {"const": mp.params[0], "slope": mp.params[1]}, "cols": cols}


def score_of(model, df):
    return df[model["cols"]].astype(int).values @ np.array([model["points"][c] for c in model["cols"]])


def prob_of(model, df):
    return expit(model["map"]["const"] + model["map"]["slope"] * score_of(model, df))




def main(path):
    d = pd.read_csv(path)
    y = d.icu_death.values.astype(int)
    pts = mccis_points(d); p = expit(INTERCEPT + SLOPE * pts)
    out = {"n": len(d), "deaths": int(y.sum())}
    a, lo, hi = auc_ci(y, pts); out["AUC_mCCIS"] = (round(a, 3), round(lo, 3), round(hi, 3))
    if "cci" in d:
        a, lo, hi = auc_ci(y, d.cci.values); out["AUC_CCI"] = (round(a, 3), round(lo, 3), round(hi, 3))
        out["dAUC_mCCIS_minus_CCI"] = tuple(round(v, 3) for v in auc_compare(y, pts, d.cci.values))
    cal = calibration(y, p); out["calibration"] = {k: round(float(v), 3) for k, v in cal.items()}
    a0 = sm.GLM(y.astype(float), np.ones((len(y), 1)), family=sm.families.Binomial(), offset=logit(p)).fit().params[0]
    out["intercept_update"] = round(float(a0), 3)
    out["calibration_after_intercept_update"] = {k: round(float(v), 3) for k, v in calibration(y, expit(logit(p) + a0)).items()}
    g = pd.cut(pts, [-1, 2, 5, 8, 11, 99], labels=["0-2", "3-5", "6-8", "9-11", ">=12"])
    out["risk_groups"] = pd.DataFrame({"g": g, "y": y}).groupby("g", observed=False).y.agg(["size", "sum", "mean"]).round(3).to_dict()
    print(json.dumps(out, indent=2, default=str))


if __name__ == "__main__":
    main(sys.argv[1])
